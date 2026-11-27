import SwiftUI
import TamaCore

/// The Connect sheet: find another phone nearby (or invite a friend far
/// away through Game Center), pair with it, then get out of the way -- the
/// connection itself is played out on the Tama's own screen, so once two
/// phones are paired this sheet only explains what to do next and offers a
/// way to disconnect.
struct NearbyLinkView: View {
    let session: NearbyLinkSession
    let online: OnlineLinkSession
    /// The Tama whose page the sheet was opened from.
    let device: TamaDevice
    let onLinkChange: (TamaDevice, LinkPort?, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// While connected the sheet always describes the Tama that actually
    /// holds the connection, even if it was reopened from another page.
    private var linkedDevice: TamaDevice { online.device ?? session.device ?? device }

    var body: some View {
        NavigationStack {
            Group {
                switch online.phase {
                case .connected(let name):
                    connected(to: name, peerDeviceID: online.peerDeviceID) { online.end() }
                case .signingIn, .choosing, .connecting:
                    waitingOnline
                case .idle:
                    switch session.phase {
                    case .connected(let name):
                        connected(to: name, peerDeviceID: session.peerDeviceID) { session.end() }
                    case .inviting(let name):
                        waiting(for: name)
                    case .searching:
                        searching
                    case .idle:
                        stopped
                    }
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { startIfNeeded() }
        .onDisappear {
            session.sheetDidClose()
            online.sheetDidClose()
        }
        .onChange(of: online.hasPendingInvite) { _, pending in
            if pending { answerOnlineInvite() }
        }
    }

    private func startIfNeeded() {
        if online.hasPendingInvite {
            answerOnlineInvite()
            return
        }
        guard session.phase == .idle, !online.isActive else { return }
        search()
    }

    /// One connection at a time: going online stops looking nearby.
    private func inviteOnline() {
        if !session.isConnected { session.end() }
        let device = device
        let onLinkChange = onLinkChange
        online.inviteFriend(for: device) { port, name in
            onLinkChange(device, port, name)
        }
    }

    private func answerOnlineInvite() {
        // An invite replaces whatever was going on here.
        session.end()
        let device = device
        let onLinkChange = onLinkChange
        online.acceptPendingInvite(for: device) { port, name in
            onLinkChange(device, port, name)
        }
    }

    private var onlineSection: some View {
        Section {
            Button {
                inviteOnline()
            } label: {
                Label("Invite a Game Center Friend…", systemImage: "globe")
            }
        } header: {
            Text("Far away")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("For a friend who isn't close by. They get your invite through Game Center, and you play over the internet.")
                if let notice = online.notice {
                    Text(notice).foregroundStyle(.orange)
                }
            }
        }
    }

    private var waitingOnline: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
                .padding(.bottom, 8)
        } description: {
            Text(online.phase == .connecting ? "Connecting over the internet…" : "Waiting for Game Center…")
        } actions: {
            Button("Cancel", role: .cancel) { online.end() }
        }
    }

    private func search() {
        let device = device
        let onLinkChange = onLinkChange
        session.startSearching(for: device) { port, name in
            onLinkChange(device, port, name)
        }
    }

    // MARK: - Looking for someone

    private var searching: some View {
        List {
            Section {
                if let inviter = session.incomingInviteName {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("\(inviter) wants to connect", systemImage: "person.wave.2.fill")
                            .font(.headline)
                        HStack {
                            Button("Decline", role: .cancel) { session.answerInvite(accept: false) }
                                .buttonStyle(.bordered)
                            Button("Accept") { session.answerInvite(accept: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                if session.peers.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for Tamas nearby…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(session.peers) { peer in
                        Button {
                            session.invite(peer)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name)
                                        .foregroundStyle(.primary)
                                    Text(peer.isCompatible
                                         ? peer.deviceTitle
                                         : "\(peer.deviceTitle) · can't connect with this Tama")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if peer.isCompatible {
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .disabled(!peer.isCompatible)
                    }
                }
            } header: {
                Text("Nearby")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask your friend to open Connect on their Tama too, then tap their name here.")
                    if let notice = session.notice {
                        Text(notice).foregroundStyle(.orange)
                    }
                }
            }

            onlineSection
        }
    }

    private func waiting(for name: String) -> some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
                .padding(.bottom, 8)
        } description: {
            Text("Connecting to \(name)…")
        }
    }

    private var stopped: some View {
        List {
            Section {
                Button("Look Nearby Again") { search() }
            } footer: {
                Text(session.notice ?? "Look for another Tomomix player nearby.")
            }
            onlineSection
        }
    }

    // MARK: - Paired

    private func connected(to name: String, peerDeviceID: String?, disconnect: @escaping () -> Void) -> some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected to \(name)")
                            .font(.headline)
                        Text(linkedDevice.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } footer: {
                Text("Your Tamas can now see each other, as if you were holding them head to head. Keep both on screen while they connect.")
            }

            Section("What to do now") {
                let steps = Self.steps(for: linkedDevice.id, with: peerDeviceID)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                    step(index + 1, text)
                }
            }

            Section {
                Button("Disconnect", role: .destructive) {
                    disconnect()
                    dismiss()
                }
            }
        }
    }

    /// What to press on this Tama, given what is on the other end. Each
    /// model's connection menu is laid out differently, and the newer
    /// ones ask who the partner is; these follow the menus as they
    /// actually appear on each firmware.
    static func steps(for deviceID: String, with peerDeviceID: String?) -> [String] {
        let open = "Close this sheet. On both Tamas, press A until the heart icon lights up, then press B."
        let start = "When both screens show two hearts, one of you presses B."
        switch deviceID {
        case "tamago":
            return [
                "Close this sheet. On both Tama-Gos, press A until the connection icon (heart with waves) is lit, then press B.",
                "Choose TAMA-GO with B, then GAME or VISIT (press A to move to VISIT) with B. Both of you pick the same one.",
                "When both screens show STAND BY, one of you presses B. For a visit, that Tama is the one who goes.",
            ]
        case "id", "id-melody":
            return [open, "Choose たまごっちiD, the first option, with B.", start]
        case "idl":
            if peerDeviceID == "id" || peerDeviceID == "id-melody" {
                return [open, "Press A once to move to たまごっちiD, then press B.", start]
            }
            return [
                open,
                "Choose たまごっちiDL, the first option, with B.",
                "Choose あそぶ (Play), the first option, with B.",
                start,
            ]
        case "ps":
            if peerDeviceID == "idl" {
                return [
                    open,
                    "Press A once to move to たまごっちiDL, then press B.",
                    "Choose あそぶ (Play), the first option, with B.",
                    start,
                ]
            }
            return [
                open,
                "Choose たまごっちP's, then あそぶ (Play): the first option both times.",
                "One of you chooses あそびにいく (Go visit). The other chooses ともだちをよぶ (Invite), then ふたりであそぶ (Two players), then a game.",
                "Whoever invited presses B when their screen asks for it.",
            ]
        default:
            return [open, "Both choose the first option in the list with B.", start]
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint))
            Text(text)
        }
    }
}
