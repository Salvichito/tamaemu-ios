import Foundation
import Observation
import os
import UIKit
import WatchConnectivity
import WatchKit

/// The watch half of the remote (the phone half is WatchRemote in the iOS
/// app; see it for the message format). Only talks to the phone while this
/// app is in the foreground: lowering the wrist stops everything.
@MainActor
@Observable
final class WatchLink: NSObject {
    /// The Tama's screen, as last sent by the phone.
    private(set) var image: UIImage?
    private(set) var name = ""
    /// True while the phone is running the Tama and sending its screen.
    private(set) var live = false
    /// The phone is still catching the Tama up on time spent asleep.
    private(set) var loading = false
    /// The last hello/ping didn't get through to the phone.
    private(set) var unreachable = false
    /// The phone answered but has no Tama to run (none added yet).
    private(set) var phoneHasNoTama = false

    nonisolated static let log = Logger(subsystem: "com.fluorescente.TamaEmu.watchkitapp", category: "WatchLink")
    @ObservationIgnored private var heartbeat: Timer?
    /// The screen is up and wants the phone; if the session wasn't ready
    /// yet when it asked, activation finishing says hello for it.
    @ObservationIgnored private var wantsLink = false
    @ObservationIgnored private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// The app came to the foreground: wake the Tama on the phone (it can
    /// stay locked in a pocket) and keep it awake with a ping every 3 s.
    func hello() {
        wantsLink = true
        ask("hello")
        heartbeat?.invalidate()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask("ping") }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    /// The app left the foreground: let the phone save and sleep now
    /// rather than waiting for the pings to stop.
    func bye() {
        wantsLink = false
        heartbeat?.invalidate()
        heartbeat = nil
        if let session, session.activationState == .activated, session.isReachable {
            session.sendMessage(["t": "bye"], replyHandler: nil, errorHandler: nil)
        }
        live = false
        loading = false
    }

    private func ask(_ kind: String) {
        guard let session, session.activationState == .activated else { return }
        guard session.isReachable else { unreachable = true; live = false; return }
        session.sendMessage(["t": kind], replyHandler: { reply in
            let copy = reply as NSDictionary
            Task { @MainActor in
                self.unreachable = false
                self.apply(copy as! [String: Any])
            }
        }, errorHandler: { error in
            // Usually a timeout while the phone app is still starting up in
            // the background (20 s for a Debug build in the Simulator):
            // keep saying "Waking…", the next ping will get through. Only
            // the phone being out of range counts as unreachable.
            WatchLink.log.error("\(kind, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in self.live = false }
        })
    }

    func press(_ button: Int) { send(["t": "down", "b": button]) }
    func release(_ button: Int) { send(["t": "up", "b": button]) }

    private func send(_ message: [String: Any]) {
        guard live, let session, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    #if DEBUG
    /// Test-only: `simctl launch … -autoPress 0` presses that button once,
    /// a few seconds after the phone first answers live (the Simulator
    /// tools can't tap a watch screen).
    @ObservationIgnored private var autoPressDone = false
    private func autoPressIfRequested() {
        guard !autoPressDone, live, !loading,
              let raw = UserDefaults.standard.string(forKey: "autoPress"), let b = Int(raw) else { return }
        autoPressDone = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            WatchLink.log.notice("autoPress \(b)")
            self.press(b)
            try? await Task.sleep(for: .milliseconds(150))
            self.release(b)
        }
    }
    #endif

    fileprivate func apply(_ message: [String: Any]) {
        guard !message.isEmpty else { return }
        if let live = message["live"] as? Bool {
            self.live = live
            phoneHasNoTama = !live && (message["name"] as? String ?? "").isEmpty
        }
        loading = (message["loading"] as? Bool) ?? false
        if let name = message["name"] as? String, !name.isEmpty { self.name = name }
        if let data = message["img"] as? Data, let img = UIImage(data: data) { image = img }
        #if DEBUG
        autoPressIfRequested()
        #endif
    }

    /// The last picture the phone left behind, for when it isn't open.
    fileprivate func applySaved() {
        guard let context = session?.receivedApplicationContext, !context.isEmpty, !live else { return }
        if let name = context["name"] as? String, !name.isEmpty { self.name = name }
        if let data = context["img"] as? Data, let img = UIImage(data: data) { image = img }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.applySaved()
            // Launched from the watch face, the app can still count as
            // "inactive" here even though its screen is up, so this goes by
            // whether the screen asked (wantsLink), not the app state.
            if self.wantsLink || WKApplication.shared().applicationState == .active { self.hello() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            if session.isReachable {
                if self.heartbeat != nil { self.ask("hello") }
            } else {
                self.unreachable = true
                self.live = false
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let copy = message as NSDictionary
        Task { @MainActor in self.apply(copy as! [String: Any]) }
    }

    /// Screen pictures: confirming each one is what lets the phone send
    /// the next (see WatchRemote.frameInFlightSince).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let copy = message as NSDictionary
        replyHandler([:])
        Task { @MainActor in self.apply(copy as! [String: Any]) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.applySaved() }
    }
}
