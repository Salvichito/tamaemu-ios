import Foundation
import GameKit
import Observation
import TamaCore
import UIKit

/// Connects one Tama to a friend's anywhere over the internet, through
/// Game Center -- the far-away twin of NearbyLinkSession. Apple carries the
/// data, so there is no server of ours, no account beyond the Game Center
/// one, and nobody can be matched with a stranger: it's invite-only.
///
/// Everything past "who is on the other end" is shared with Connect
/// Nearby: the Tama only ever sees a LinkPort, and LinkPort's frame
/// lockstep is what makes distance harmless -- a slow connection makes the
/// few seconds of an exchange run slower, it doesn't garble it.
///
/// Flow: open Connect on a Tama, tap "Invite a Game Center Friend", pick a
/// friend in Game Center's own screen. The friend gets a notification,
/// taps it, and Tomomix opens Connect on whichever Tama they're looking at.
/// Once both are in, each tells the other which model it is; a pair that
/// can't link is told so and disconnected.
@MainActor
@Observable
final class OnlineLinkSession: NSObject {
    enum Phase: Equatable {
        case idle
        case signingIn
        /// Game Center's invite screen is up.
        case choosing
        case connecting
        case connected(name: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var notice: String?
    /// The Tama this session is for, fixed from start until end().
    private(set) var device: TamaDevice?
    /// The other side's model, once its hello has arrived.
    private(set) var peerDeviceID: String?
    /// A friend's invite was accepted while no Connect sheet was open: the
    /// gallery opens one, and the sheet calls acceptPendingInvite.
    private(set) var hasPendingInvite = false

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    var isActive: Bool { phase != .idle }

    /// Set after the first successful sign-in, so later launches sign in
    /// quietly at start (needed to hear invites) -- but players who never
    /// use online play never see a Game Center banner.
    private static let usedKey = "online.gameCenterUsed"

    private nonisolated static let infraredMessage: UInt8 = 0x01
    private nonisolated static let helloMessage: UInt8 = 0x02

    private var match: GKMatch?
    private var pendingInvite: GKInvite?
    private var onLinkChange: ((LinkPort?, String?) -> Void)?
    private var sentHello = false
    private var peerName: String?
    @ObservationIgnored private nonisolated let portBox = OnlinePortBox()
    private var listenerRegistered = false
    private var authenticateHandlerSet = false
    /// What to do once signed in (show the invite screen, or answer an
    /// invite).
    private var afterSignIn: (() -> Void)?

    // MARK: - App start

    /// Call once at launch: signs in quietly if this player has used
    /// online play before, so a friend's invite can reach them.
    func signInIfUsedBefore() {
        guard UserDefaults.standard.bool(forKey: Self.usedKey) else { return }
        authenticate()
    }

    // MARK: - Driving it

    /// "Invite a Game Center Friend" in the Connect sheet.
    func inviteFriend(for device: TamaDevice, onLinkChange: @escaping (LinkPort?, String?) -> Void) {
        guard !isConnected else { return }
        teardown()
        self.device = device
        self.onLinkChange = onLinkChange
        notice = nil
        phase = .signingIn
        afterSignIn = { [weak self] in self?.showInviteScreen() }
        authenticate()
    }

    /// The Connect sheet opened because of an accepted invite.
    func acceptPendingInvite(for device: TamaDevice, onLinkChange: @escaping (LinkPort?, String?) -> Void) {
        guard let invite = pendingInvite else { return }
        pendingInvite = nil
        hasPendingInvite = false
        teardown()
        self.device = device
        self.onLinkChange = onLinkChange
        notice = nil
        guard let vc = GKMatchmakerViewController(invite: invite) else {
            notice = "That invite has expired. Ask your friend to send a new one."
            return
        }
        vc.matchmakerDelegate = self
        phase = .choosing
        Self.present(vc)
    }

    /// Disconnect and stop everything.
    func end() {
        teardown()
    }

    /// The sheet closed while Game Center's own screens weren't involved:
    /// a half-made connection isn't worth keeping.
    func sheetDidClose() {
        if phase == .connecting || phase == .signingIn { teardown() }
    }

    // MARK: - Steps

    private func authenticate() {
        let player = GKLocalPlayer.local
        if player.isAuthenticated {
            didSignIn()
            return
        }
        // GameKit calls this handler again on its own later (sign-in
        // changes, app returning); setting it once is the documented way.
        guard !authenticateHandlerSet else { return }
        authenticateHandlerSet = true
        player.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    Self.present(viewController)
                } else if GKLocalPlayer.local.isAuthenticated {
                    self.didSignIn()
                } else if self.phase == .signingIn {
                    self.teardown()
                    self.notice = "Sign in to Game Center (Settings › Game Center) to play online."
                    _ = error
                }
            }
        }
    }

    private func didSignIn() {
        UserDefaults.standard.set(true, forKey: Self.usedKey)
        if !listenerRegistered {
            GKLocalPlayer.local.register(self)
            listenerRegistered = true
        }
        let next = afterSignIn
        afterSignIn = nil
        next?()
    }

    private func showInviteScreen() {
        guard phase == .signingIn else { return }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.inviteMessage = device.map { "Let's connect our \($0.title)s in Tomomix!" }
        guard let vc = GKMatchmakerViewController(matchRequest: request) else {
            teardown()
            notice = "Game Center couldn't open its invite screen."
            return
        }
        vc.matchmakingMode = .inviteOnly
        vc.matchmakerDelegate = self
        phase = .choosing
        Self.present(vc)
    }

    private func didFind(_ match: GKMatch) {
        self.match = match
        match.delegate = self
        phase = .connecting
        sendHelloIfReady()
    }

    private func sendHelloIfReady() {
        guard let match, !sentHello, match.expectedPlayerCount == 0, let device else { return }
        sentHello = true
        let hello = ["dev": device.id, "title": device.title]
        guard let body = try? JSONSerialization.data(withJSONObject: hello) else { return }
        var message = Data([Self.helloMessage])
        message.append(body)
        try? match.sendData(toAllPlayers: message, with: .reliable)
    }

    private func didReceiveHello(_ body: Data, from player: GKPlayer) {
        guard phase == .connecting, let match, let device else { return }
        let info = (try? JSONSerialization.jsonObject(with: body)) as? [String: String] ?? [:]
        let theirDevice = info["dev"] ?? ""
        let name = player.displayName
        guard NearbyLinkSession.canLink(device.id, theirDevice) else {
            let title = info["title"] ?? "a different Tama"
            teardown()
            notice = "\(name) is on \(title), which can't connect with your \(device.title)."
            return
        }
        peerDeviceID = theirDevice
        peerName = name

        let port = LinkPort()
        let tag = Self.infraredMessage
        port.setSendHandler { [match] data in
            var message = Data([tag])
            message.append(data)
            // Reliable = in order and complete, as the Tamas need. Called
            // from the emulator thread; GKMatch sends from any thread.
            try? match.sendData(toAllPlayers: message, with: .reliable)
        }
        portBox.swap(port)
        phase = .connected(name: name)
        onLinkChange?(port, name)
    }

    private func didDisconnect() {
        guard phase != .idle else { return }
        let name = peerName
        teardown()
        notice = name.map { "The connection to \($0) ended." } ?? "Your friend left before connecting."
    }

    private func teardown() {
        let wasConnected = isConnected
        afterSignIn = nil
        match?.delegate = nil
        match?.disconnect()
        match = nil
        portBox.swap(nil)?.setSendHandler(nil)
        sentHello = false
        peerDeviceID = nil
        peerName = nil
        phase = .idle
        if wasConnected { onLinkChange?(nil, nil) }
        onLinkChange = nil
        device = nil
    }

    /// Game Center's screens go on top of whatever is showing (the Connect
    /// sheet, usually).
    private static func present(_ vc: UIViewController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        top.present(vc, animated: true)
    }
}

// MARK: - Game Center callbacks

extension OnlineLinkSession: GKMatchmakerViewControllerDelegate {
    nonisolated func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            if self.phase == .choosing { self.teardown() }
        }
    }

    nonisolated func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            self.teardown()
            self.notice = "Game Center couldn't connect: \(error.localizedDescription)"
        }
    }

    nonisolated func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            self.didFind(match)
        }
    }
}

extension OnlineLinkSession: GKMatchDelegate {
    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        guard let first = data.first else { return }
        if first == Self.infraredMessage {
            // Straight into the port, off the main thread, like Nearby.
            portBox.get()?.receive(Data(data.dropFirst()))
        } else if first == Self.helloMessage {
            let body = Data(data.dropFirst())
            Task { @MainActor in
                guard match === self.match else { return }
                self.sendHelloIfReady()
                self.didReceiveHello(body, from: player)
            }
        }
    }

    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        Task { @MainActor in
            guard match === self.match else { return }
            switch state {
            case .connected: self.sendHelloIfReady()
            case .disconnected: self.didDisconnect()
            default: break
            }
        }
    }

    nonisolated func match(_ match: GKMatch, didFailWithError error: Error?) {
        Task { @MainActor in
            guard match === self.match else { return }
            self.didDisconnect()
        }
    }
}

extension OnlineLinkSession: GKLocalPlayerListener {
    /// A friend's invite was tapped (notification or Game Center).
    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        Task { @MainActor in
            guard !self.isConnected else { return }
            self.pendingInvite = invite
            self.hasPendingInvite = true
        }
    }
}

/// A LinkPort behind a lock, readable from any thread.
private final class OnlinePortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: LinkPort?

    func get() -> LinkPort? {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    @discardableResult
    func swap(_ new: LinkPort?) -> LinkPort? {
        lock.lock(); defer { lock.unlock() }
        let old = port
        port = new
        return old
    }
}
