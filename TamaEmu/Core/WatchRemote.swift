import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import WatchConnectivity
import os

/// A page the Apple Watch can mirror: its screen as a picture and its
/// three buttons. Every kind of Tama page conforms (see the extensions at
/// the bottom), so the watch never needs to know which core is behind it.
@MainActor
protocol WatchMirrorable: AnyObject {
    var watchTitle: String { get }
    /// The screen right now, or nil if there's nothing to show yet.
    func watchFrame() -> CGImage?
    /// Still catching up on time spent away (the watch says "Waking…").
    var watchIsLoading: Bool { get }
    func watchPress(_ button: InputController.Button)
    func watchRelease(_ button: InputController.Button)
}

/// The phone half of the watch remote. The Tama keeps running here, on the
/// phone; the watch app only shows its screen and sends A/B/C presses back.
///
/// The phone can stay locked in a pocket. When the watch app opens it says
/// hello, which wakes this app in the background (WatchConnectivity allows
/// that). The on-screen Tama then starts silently, catching up first like it
/// does on any resume, and its screen is streamed to the watch. The watch
/// pings every few seconds while it's open; each ping asks iOS for a little
/// more background time. When the watch says bye, goes quiet, or iOS ends
/// the background time, the Tama saves and stops, like leaving the app.
///
/// Battery: nothing runs unless the watch app is open on a raised wrist
/// (see feedback: no all-day background keepalive). How long iOS lets
/// this go on is up to iOS; it has not been measured on a real phone.
///
/// Messages (plain property-list dictionaries, both ways):
///   watch → phone  ["t": "hello" | "ping"]          reply: status
///                  ["t": "bye"]
///                  ["t": "down" | "up", "b": 0-2]
///   phone → watch  ["live": Bool, "loading": Bool, "name": String, "img": PNG Data?]
@MainActor
final class WatchRemote: NSObject {
    static let shared = WatchRemote()
    nonisolated static let log = Logger(subsystem: "com.fluorescente.TamaEmu", category: "WatchRemote")

    /// Frames per second sent to the watch at most. The screens are pixel
    /// art that changes a few times a second; only changed frames are sent.
    private static let frameInterval: TimeInterval = 1.0 / 6.0
    /// No word from the watch for this long while the phone is in the
    /// background: assume it's gone. The watch pings every 3 s, but in the
    /// Simulator the pings reached a backgrounded phone in bursts with
    /// ~20 s gaps; a shorter limit stopped and restarted the Tama (with a
    /// catch-up each time) for no reason. A closed watch app says "bye".
    private static let watchTimeout: TimeInterval = 30

    /// Read by the engines' sound output on their audio threads: true
    /// while a Tama is running in the background for the watch, so the
    /// phone in a pocket stays silent.
    nonisolated(unsafe) static var silenced = false

    private var session: WCSession?
    private weak var current: WatchMirrorable?
    private var timer: Timer?
    private var lastSentPNG: Data?
    private var appActive = false
    /// Buttons the watch is holding down, released if the watch goes away
    /// mid-press (so a lost "up" can't leave a button stuck).
    private var held: Set<InputController.Button> = []

    /// Background play for the watch: when we last heard from it, and the
    /// iOS background-time grant that keeps this app awake meanwhile.
    private var lastWatchContact: Date?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var watchdog: Timer?

    /// True while the watch app is open and talking to us.
    var isServingWatch: Bool {
        guard let lastWatchContact else { return false }
        return Date().timeIntervalSince(lastWatchContact) < Self.watchTimeout
    }

    /// Call once at launch (also when iOS launches the app in the
    /// background because the watch said hello).
    func start() {
        guard session == nil, WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
        appActive = UIApplication.shared.applicationState == .active
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WatchRemote.shared.setAppActive(true) }
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WatchRemote.shared.setAppActive(false) }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WatchRemote.shared.updateSilence() }
        }
    }

    /// A page came on screen (GalleryViewModel.pageDidAppear).
    func show(_ page: WatchMirrorable) {
        current = page
        lastSentPNG = nil
        refresh()
    }

    /// A page left the screen. Leaves the watch its last picture.
    func hide(_ page: WatchMirrorable) {
        guard current === page else { return }
        releaseHeld()
        saveContext(from: page)
        current = nil
        sendStatus()
        refresh()
    }

    private func setAppActive(_ active: Bool) {
        appActive = active
        if active {
            // Opened on the phone: the gallery's own lifecycle owns the
            // Tama again. Keep streaming if the watch is still open.
            endBackgroundTask()
        } else if isServingWatch {
            // Locked or left while the watch is open: carry on in the
            // background (TamaGalleryView skips its usual stop for this).
            beginBackgroundTask()
        } else {
            releaseHeld()
            if let current { saveContext(from: current) }
        }
        updateSilence()
        lastSentPNG = nil
        refresh()
    }

    private func updateSilence() {
        Self.silenced = UIApplication.shared.applicationState == .background && current != nil
    }

    private var isLive: Bool { current != nil && (appActive || isServingWatch) }

    /// Starts or stops the frame timer to match whether anyone is watching.
    private func refresh() {
        let shouldRun = isLive && session?.activationState == .activated && session?.isReachable == true
        if shouldRun, timer == nil {
            let t = Timer(timeInterval: Self.frameInterval, repeats: true) { _ in
                MainActor.assumeIsolated { WatchRemote.shared.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()
        } else if !shouldRun, let t = timer {
            t.invalidate()
            timer = nil
            releaseHeld()
        }
    }

    /// Whether the page is still catching up on time spent away.
    private var isLoading: Bool { current?.watchIsLoading ?? false }
    private var lastSentLoading = false

    /// When the picture now on its way to the watch was sent; nil once the
    /// watch confirmed it. Only one at a time: sending every changed frame
    /// let them queue up faster than the link delivers (seconds of lag that
    /// kept growing), so frames that changed meanwhile are skipped and the
    /// next one sent is always the newest.
    private var frameInFlightSince: Date?

    private func tick() {
        guard let session, session.isReachable, isLive, let current else { return }
        if let since = frameInFlightSince, Date().timeIntervalSince(since) < 3 { return }
        let loading = isLoading
        let png = Self.png(current.watchFrame())
        guard png != lastSentPNG || loading != lastSentLoading else { return }
        lastSentPNG = png
        lastSentLoading = loading
        var msg: [String: Any] = ["live": true, "loading": loading, "name": current.watchTitle]
        if let png { msg["img"] = png }
        frameInFlightSince = Date()
        session.sendMessage(msg, replyHandler: { _ in
            Task { @MainActor in WatchRemote.shared.frameInFlightSince = nil }
        }, errorHandler: { error in
            WatchRemote.log.error("frame failed: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in WatchRemote.shared.frameInFlightSince = nil }
        })
    }

    private func status(withImage: Bool = true) -> [String: Any] {
        var msg: [String: Any] = ["live": isLive, "loading": isLoading, "name": current?.watchTitle ?? ""]
        if withImage, isLive, let png = Self.png(current?.watchFrame()) { msg["img"] = png }
        return msg
    }

    private func sendStatus() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(status(), replyHandler: nil, errorHandler: nil)
    }

    /// The last picture, kept by the system for the watch to show the next
    /// time it opens while nothing is running.
    private func saveContext(from page: WatchMirrorable) {
        guard let session, session.activationState == .activated, session.isWatchAppInstalled,
              let png = Self.png(page.watchFrame()) else { return }
        try? session.updateApplicationContext(["live": false, "name": page.watchTitle, "img": png])
    }

    private func handle(_ message: [String: Any]) -> [String: Any]? {
        let kind = message["t"] as? String
        if kind == "bye" {
            watchLeft()
            return nil
        }
        watchSpoke()
        switch kind {
        case "hello":
            lastSentPNG = nil
            refresh()
            return status()
        case "ping":
            refresh()
            return status(withImage: false)
        case "down":
            guard isLive, let raw = message["b"] as? Int, let b = InputController.Button(rawValue: raw),
                  [.a, .b, .c].contains(b) else { return nil }
            held.insert(b)
            current?.watchPress(b)
        case "up":
            guard let raw = message["b"] as? Int, let b = InputController.Button(rawValue: raw),
                  held.remove(b) != nil else { return nil }
            current?.watchRelease(b)
        default:
            break
        }
        return nil
    }

    // MARK: - Background play for the watch

    /// Any message from the watch. In the background, this is what keeps
    /// the Tama running: wake it if needed and ask iOS for more time.
    private func watchSpoke() {
        lastWatchContact = Date()
        if current == nil {
            // Woken from sleep (maybe a fresh background launch): bring
            // up whichever Tama the phone would show. Not gated on
            // appActive: in a background launch for the watch (Simulator,
            // 2026-11-26) the app reported itself active, so the gallery
            // never started a page and the watch was told "nothing to show".
            GalleryViewModel.shared.wakeForWatch()
        }
        guard UIApplication.shared.applicationState != .active else { return }
        beginBackgroundTask()
        updateSilence()
        if watchdog == nil {
            let t = Timer(timeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let remote = WatchRemote.shared
                    if !remote.appActive && !remote.isServingWatch { remote.watchLeft() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            watchdog = t
        }
    }

    /// The watch closed (or went quiet): if the phone app isn't open,
    /// save and stop the Tama, exactly like leaving the app.
    private func watchLeft() {
        lastWatchContact = nil
        watchdog?.invalidate()
        watchdog = nil
        releaseHeld()
        if !appActive {
            GalleryViewModel.shared.sleepAfterWatch()
            BackgroundRefresh.scheduleNext()
            endBackgroundTask()
        }
        updateSilence()
        refresh()
    }

    /// Asks iOS for (more) background time. Starting a new grant before
    /// ending the old one is how each ping extends it.
    private func beginBackgroundTask() {
        let old = backgroundTask
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch remote") {
            // iOS is about to suspend the app: save now, while we still can.
            MainActor.assumeIsolated { WatchRemote.shared.watchLeft() }
        }
        if old != .invalid { UIApplication.shared.endBackgroundTask(old) }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func releaseHeld() {
        for b in held { current?.watchRelease(b) }
        held.removeAll()
    }

    private static func png(_ image: CGImage?) -> Data? {
        guard let image else { return nil }
        let scaled = image
        // PNG keeps the black-and-white screens crisp and tiny; the
        // color screens can come out bigger than a watch message may be
        // (65 KB, measured 87 KB for a Plus Color frame), so those go as
        // JPEG instead. The watch reads either.
        if let png = encode(scaled, as: .png), png.count <= maxImageBytes { return png }
        return encode(scaled, as: .jpeg, quality: 0.8)
    }

    /// Well under WatchConnectivity's message limit, leaving room for
    /// the rest of the message.
    private static let maxImageBytes = 20_000

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

extension WatchRemote: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in WatchRemote.shared.refresh() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another paired watch: start talking to the new one.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchRemote.shared.lastSentPNG = nil
            WatchRemote.shared.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let copy = message as NSDictionary
        Task { @MainActor in _ = WatchRemote.shared.handle(copy as! [String: Any]) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let copy = message as NSDictionary
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            reply(WatchRemote.shared.handle(copy as! [String: Any]) ?? [:])
        }
    }
}

// MARK: - Pages

// Each screen goes over at (about) its real size and the watch enlarges it
// with hard pixel edges. The first version sent the styled 240 px video
// frame (~32 KB each): measured in the Simulator 2026-11-26, the watch then
// got about one picture a second, and rendering it cost the phone a 720 px
// SwiftUI render six times a second.

extension PlayViewModel: WatchMirrorable {
    var watchTitle: String { selectedDevice.title }
    /// The raw 128x128 LCD, exactly as the core drew it.
    func watchFrame() -> CGImage? { lcdImage }
    var watchIsLoading: Bool { isLoading }
    func watchPress(_ button: InputController.Button) { pressButton(button) }
    func watchRelease(_ button: InputController.Button) { releaseButton(button) }
}

extension V1PlayViewModel: WatchMirrorable {
    var watchTitle: String { selectedDevice.title }
    /// 140 px: the dot matrix plus its icon rows, still legible.
    func watchFrame() -> CGImage? { renderP1Snapshot(state: screenState, deviceID: selectedDevice.id, scale: 0.5) }
    var watchIsLoading: Bool { isLoading }
    func watchPress(_ button: InputController.Button) { pressButton(button) }
    func watchRelease(_ button: InputController.Button) { releaseButton(button) }
}

extension T7PlayViewModel: WatchMirrorable {
    var watchTitle: String { selectedDevice.title }
    func watchFrame() -> CGImage? { renderT7Snapshot(state: screenState, isFriends: isFriends, scale: 0.5) }
    var watchIsLoading: Bool { isLoading }
    func watchPress(_ button: InputController.Button) { pressButton(button) }
    func watchRelease(_ button: InputController.Button) { releaseButton(button) }
}

extension T18PlayViewModel: WatchMirrorable {
    var watchTitle: String { selectedDevice.title }
    func watchFrame() -> CGImage? { screenImage }
    var watchIsLoading: Bool { isLoading }
    func watchPress(_ button: InputController.Button) { pressButton(button) }
    func watchRelease(_ button: InputController.Button) { releaseButton(button) }
}

extension TomomixViewModel: WatchMirrorable {
    var watchTitle: String { displayName }
    func watchFrame() -> CGImage? { recordingFrame(side: 160) }
    var watchIsLoading: Bool { false }
    func watchPress(_ button: InputController.Button) { press(button) }
    func watchRelease(_ button: InputController.Button) { release(button) }
}
