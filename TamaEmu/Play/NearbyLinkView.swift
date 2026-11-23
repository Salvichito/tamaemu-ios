import SwiftUI
import TamaCore

/// The "Connect Nearby" sheet: find another phone, pair with it, then get
/// out of the way -- the connection itself is played out on the Tama's own
/// screen, so once two phones are paired this sheet only explains what to
/// do next and offers a way to disconnect.
struct NearbyLinkView: View {
    let session: NearbyLinkSession
    /// The Tama whose page the sheet was opened from.
    let device: TamaDevice
    let onLinkChange: (TamaDevice, LinkPort?, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// While connected the sheet always describes the Tama that actually
    /// holds the connection, even if it was reopened from another page.
    private var linkedDevice: TamaDevice { session.device ?? device }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .connected(let name):
                    connected(to: name)
                case .inviting(let name):
                    waiting(for: name)
                case .searching:
                    searching
                case .idle:
                    stopped
                }
            }
            .navigationTitle("Connect Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { startIfNeeded() }
        .onDisappear { session.sheetDidClose() }
    }

    private func startIfNeeded() {
        guard session.phase == .idle else { return }
        search()
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
                    Text("Ask your friend to open Connect Nearby on their Tama too, then tap their name here.")
                    if let notice = session.notice {
                        Text(notice).foregroundStyle(.orange)
                    }
                }
            }
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
        ContentUnavailableView {
            Label("Not connected", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(session.notice ?? "Look for another Tomomix player nearby.")
        } actions: {
            Button("Look Again") { search() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Paired

    private func connected(to name: String) -> some View {
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
                let steps = Self.steps(for: linkedDevice.id, with: session.peerDeviceID)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                    step(index + 1, text)
                }
            }

            Section {
                Button("Disconnect", role: .destructive) {
                    session.end()
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
        case "id":
            return [open, "Choose たまごっちiD, the first option, with B.", start]
        case "idl":
            if peerDeviceID == "id" {
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
