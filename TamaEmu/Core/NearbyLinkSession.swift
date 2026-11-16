import Foundation
@preconcurrency import MultipeerConnectivity
import Observation
import TamaCore
import UIKit

/// Finds another phone running TamaEmu close by and carries one Tama's
/// infrared signal to it and back -- the stand-in for holding two real
/// Tamagotchis head to head.
///
/// Uses Apple's MultipeerConnectivity: the phones find each other over
/// Wi-Fi or Bluetooth on their own, with no server, no account and no
/// shared network needed. Everything about *how* the bytes travel lives
/// in this one class; the emulator only ever sees a LinkPort, so a
/// different carrier (an internet relay, say) can be added later without
/// touching it.
///
/// Flow: both players open "Connect Nearby" on the Tama they want to
/// connect. Each phone announces itself and looks for the other. One
/// taps the other in the list, the other accepts, and from then on the
/// two Tamas can "see" each other exactly as if they were face to face --
/// the connection itself is still started from the Tama's own menu.
@MainActor
@Observable
final class NearbyLinkSession: NSObject {
    struct Peer: Identifiable, Equatable {
        let id: MCPeerID
        let name: String
        let deviceTitle: String
        /// False when the other Tama is a model this one can't talk to.
        let isCompatible: Bool
    }

    enum Phase: Equatable {
        case idle
        case searching
        case inviting(name: String)
        case connected(name: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var peers: [Peer] = []
    /// Someone nearby asked to connect and is waiting for an answer.
    private(set) var incomingInviteName: String?
    /// One-line explanation of the last thing that went wrong, for the
    /// sheet to show. Cleared when a new search starts.
    private(set) var notice: String?
    /// The Tama this session is for -- fixed from startSearching() until
    /// end().
    private(set) var device: TamaDevice?
    /// The model on the other end of the live connection, when known (it
    /// isn't if the other phone invited us before we had spotted it).
    private(set) var peerDeviceID: String?
    private var knownPeerDevices: [MCPeerID: String] = [:]

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// Models that have been shown to connect. Everything else keeps the
    /// feature hidden rather than offering something untested.
    static func supports(_ device: TamaDevice) -> Bool {
        linkablePairs.contains { $0.contains(family(of: device.id)) }
    }

    /// Whether these two models can talk to each other.
    static func canLink(_ deviceID: String, _ otherDeviceID: String) -> Bool {
        linkablePairs.contains([family(of: deviceID), family(of: otherDeviceID)])
    }

    /// The regular and the Hexagontchi Plus Color are the same toy in
    /// different shells.
    private static func family(of deviceID: String) -> String {
        deviceID == "plus-color-hexa" ? "plus-color" : deviceID
    }

    /// Every pairing that has actually been seen to complete an exchange
    /// between two emulated Tamas. A set of one means "with its own kind".
    ///
    /// Deliberately missing:
    /// - Plus Color with iD or iD L. The real toys could, but the newer
    ///   one falls back to the Plus Color's older kind of signal for it,
    ///   and the core does not emulate that on the iD side: the iD neither
    ///   hears the Plus Color nor sends anything.
    /// - iD Lovely Melody: not tried.
    /// - 4U and 4U+: they connect by NFC touch, not infrared.
    private static let linkablePairs: [Set<String>] = [
        ["plus-color"],
        ["id"],
        ["idl"],
        ["ps"],
        ["id", "idl"],
        ["idl", "ps"],
    ]

    /// Bonjour service name; also listed in Info.plist (NSBonjourServices),
    /// which iOS requires before it lets the app look for it.
    private static let serviceType = "tamaemu-link"
    /// First byte of every message, so other kinds can be added later
    /// without confusing an older build.
    private nonisolated static let infraredMessage: UInt8 = 0x01

    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var pendingInvitation: ((Bool, MCSession?) -> Void)?
    /// The live connection's port. In a locked box rather than a plain
    /// property so incoming signal can be dropped into it straight from
    /// the network's own thread, without queueing behind UI work.
    @ObservationIgnored private nonisolated let portBox = PortBox()
    /// Told whenever the connection comes up (a port and the other
    /// player's name) or goes away (nil, nil).
    private var onLinkChange: ((LinkPort?, String?) -> Void)?

    // MARK: - Driving it

    /// Start announcing this Tama and looking for others. Call when the
    /// Connect sheet opens. A no-op while already connected.
    func startSearching(for device: TamaDevice, onLinkChange: @escaping (LinkPort?, String?) -> Void) {
        guard !isConnected else { return }
        teardown()
        self.device = device
        self.onLinkChange = onLinkChange
        notice = nil

        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: ["dev": device.id, "title": device.title],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        phase = .searching
    }

    /// The Connect sheet closed. Stops looking, but leaves an established
    /// connection alone -- the player has to see the Tama to use it.
    func sheetDidClose() {
        guard !isConnected else { return }
        teardown()
    }

    func invite(_ peer: Peer) {
        guard let session, let browser, peer.isCompatible, phase == .searching else { return }
        phase = .inviting(name: peer.name)
        browser.invitePeer(peer.id, to: session, withContext: nil, timeout: 30)
    }

    func answerInvite(accept: Bool) {
        pendingInvitation?(accept, accept ? session : nil)
        pendingInvitation = nil
        if accept, let name = incomingInviteName {
            phase = .inviting(name: name)
        }
        incomingInviteName = nil
    }

    /// Disconnect and stop everything.
    func end() {
        teardown()
    }

    private func teardown() {
        let wasConnected = isConnected
        pendingInvitation?(false, nil)
        pendingInvitation = nil
        incomingInviteName = nil
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        session?.delegate = nil
        session?.disconnect()
        session = nil
        portBox.swap(nil)?.setSendHandler(nil)
        peers = []
        knownPeerDevices = [:]
        peerDeviceID = nil
        phase = .idle
        if wasConnected { onLinkChange?(nil, nil) }
        onLinkChange = nil
        device = nil
    }

    // MARK: - Reacting (always on the main actor)

    private func didConnect(to peerID: MCPeerID) {
        guard let session, !isConnected else { return }
        // Found each other: no need to keep announcing or looking.
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        pendingInvitation?(false, nil)
        pendingInvitation = nil
        incomingInviteName = nil

        let port = LinkPort()
        let tag = Self.infraredMessage
        port.setSendHandler { [session] data in
            var message = Data([tag])
            message.append(data)
            // Reliable = in order and complete, which the 4-byte events
            // need. Called from the emulator thread; MCSession is safe to
            // send on from any thread.
            try? session.send(message, toPeers: [peerID], with: .reliable)
        }
        portBox.swap(port)
        peerDeviceID = knownPeerDevices[peerID]
        phase = .connected(name: peerID.displayName)
        onLinkChange?(port, peerID.displayName)
    }

    private func didDisconnect(from peerID: MCPeerID) {
        switch phase {
        case .connected:
            teardown()
            notice = "The connection to \(peerID.displayName) ended."
        case .inviting(let name) where name == peerID.displayName:
            phase = .searching
            notice = "\(name) didn't connect. You can try again."
        default:
            break
        }
    }

    private func didFind(_ peerID: MCPeerID, info: [String: String]?) {
        guard let device, peerID != myPeerID else { return }
        let theirDevice = info?["dev"] ?? ""
        let compatible = Self.canLink(device.id, theirDevice)
        knownPeerDevices[peerID] = theirDevice
        let peer = Peer(
            id: peerID,
            name: peerID.displayName,
            deviceTitle: info?["title"] ?? "Unknown Tama",
            isCompatible: compatible
        )
        peers.removeAll { $0.id == peerID }
        peers.append(peer)
    }

    private func didLose(_ peerID: MCPeerID) {
        peers.removeAll { $0.id == peerID }
    }

    private func didReceiveInvite(from peerID: MCPeerID, handler: @escaping (Bool, MCSession?) -> Void) {
        // Both players tapped each other at the same moment: that is a
        // yes from both, no need to ask.
        if case .inviting(let name) = phase, name == peerID.displayName {
            handler(true, session)
            return
        }
        // One answer at a time, and none while already talking to someone.
        guard phase == .searching, pendingInvitation == nil else {
            handler(false, nil)
            return
        }
        pendingInvitation = handler
        incomingInviteName = peerID.displayName
    }

    private func didFail(_ message: String) {
        teardown()
        notice = message
    }
}

// MultipeerConnectivity calls these on its own background queues; each one
// just hops to the main actor, except incoming infrared, which goes
// straight into the port (see portBox).

extension NearbyLinkSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard session === self.session else { return }
            switch state {
            case .connected: self.didConnect(to: peerID)
            case .notConnected: self.didDisconnect(from: peerID)
            default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.first == Self.infraredMessage else { return }
        portBox.get()?.receive(Data(data.dropFirst()))
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension NearbyLinkSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard browser === self.browser else { return }
            self.didFind(peerID, info: info)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard browser === self.browser else { return }
            self.didLose(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            guard browser === self.browser else { return }
            self.didFail("Couldn't look for nearby phones. Check that Local Network access is allowed for TamaEmu in Settings.")
        }
    }
}

extension NearbyLinkSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            guard advertiser === self.advertiser else {
                invitationHandler(false, nil)
                return
            }
            self.didReceiveInvite(from: peerID, handler: invitationHandler)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            guard advertiser === self.advertiser else { return }
            self.didFail("Couldn't make this phone visible to others nearby. Check that Local Network access is allowed for TamaEmu in Settings.")
        }
    }
}

/// A LinkPort behind a lock, readable from any thread.
private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: LinkPort?

    func get() -> LinkPort? {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    /// Replaces the port and returns the previous one.
    @discardableResult
    func swap(_ new: LinkPort?) -> LinkPort? {
        lock.lock(); defer { lock.unlock() }
        let old = port
        port = new
        return old
    }
}
