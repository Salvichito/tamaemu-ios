import StoreKit
import SwiftUI

/// Shown whenever a free user taps a premium-gated control (a second Tama,
/// ambient background, live translation, fast-forward, photo/video
/// capture, or a points hack). One flat unlock, no tiers — so this is just
/// the feature list plus a buy button and a restore button.
struct PaywallView: View {
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Premium", systemImage: "star.fill")
                            .font(.title2.bold())
                            .foregroundStyle(.orange)
                        Text("Premium helps cover the costs of running and maintaining this app, while supporting its continued development. It's completely optional, but every bit of support helps. Thank you!")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Label("More than one Tama", systemImage: "square.grid.2x2.fill")
                    Label("Ambient Background", systemImage: "sparkles")
                    Label("Live Translation", systemImage: "character.bubble.fill")
                    Label("Fast-Forward", systemImage: "forward.fill")
                    Label("Photos & Videos", systemImage: "camera.fill")
                    Label("Points Hacks", systemImage: "plus.circle.fill")
                } header: {
                    Text("Unlocks")
                }

                Section {
                    purchaseButton
                    Button("Restore Purchase") {
                        Task { await purchases.restore() }
                    }
                    .disabled(purchases.isWorking)
                } footer: {
                    if let errorMessage = purchases.errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text("One-time payment. No subscription, no ads.")
                    }
                }
            }
            .navigationTitle("TamaEmu Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                if purchases.product == nil { await purchases.refresh() }
            }
            .onChange(of: purchases.isPremium) { _, isPremium in
                if isPremium { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var purchaseButton: some View {
        if let product = purchases.product {
            Button {
                Task { await purchases.purchase() }
            } label: {
                HStack {
                    Text("Unlock for \(product.displayPrice)")
                    if purchases.isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(purchases.isWorking)
        } else if purchases.isWorking {
            HStack {
                Text("Loading…")
                Spacer()
                ProgressView()
            }
        } else {
            Text("Couldn't load the price. Check your connection and try again.")
                .foregroundStyle(.secondary)
        }
    }
}
