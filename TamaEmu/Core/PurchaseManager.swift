import Observation
import StoreKit

/// Tracks the single one-time "Unlock Premium" purchase that gates every
/// paid feature (multi-tama, ambient background, live translation,
/// fast-forward, media capture, points hacks) — there's no tiering, so one
/// non-consumable product and one `isPremium` flag is all this needs.
///
/// Injected app-wide via `.environment(_:)` from TamaEmuApp, same as any
/// other @Observable read from `@Environment` rather than passed down by
/// hand.
@MainActor
@Observable
final class PurchaseManager {
    static let premiumProductID = "com.fluorescente.TamaEmu.premium"

    private(set) var isPremium = false
    private(set) var product: Product?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await refresh() }
    }

    /// Loads the product (for its localized price) and re-checks
    /// entitlement — called from init and from the paywall's own `.task`,
    /// since a cold launch with no network yet shouldn't permanently fail
    /// to ever show a price.
    func refresh() async {
        isWorking = true
        defer { isWorking = false }
        do {
            product = try await Product.products(for: [Self.premiumProductID]).first
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await updateEntitlement()
    }

    func purchase() async {
        guard let product else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Restore Purchase" — re-syncs with the App Store and re-checks
    /// entitlements, for a reinstall or a new device rather than a second
    /// charge (it's a non-consumable, so there's nothing to actually buy
    /// again).
    func restore() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppStore.sync()
        } catch {
            errorMessage = error.localizedDescription
        }
        await updateEntitlement()
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result, transaction.productID == Self.premiumProductID else { return }
        isPremium = true
        await transaction.finish()
    }

    private func updateEntitlement() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.premiumProductID {
                isPremium = true
                return
            }
        }
        isPremium = false
    }
}
