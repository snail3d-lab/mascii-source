import SwiftUI
import StoreKit

@main
struct MasciiApp: App {
    @StateObject private var store = PurchaseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Snail.lime)
        }
    }
}

/// Paywall model: B&W ASCII is free, always. One-time $10 purchase unlocks
/// the Snail 3D color tier (lime palette + source color bleed).
///
/// NOTE: iOS requires in-app purchases via StoreKit (App Store Review 3.1.1),
/// so Stripe cannot be used for an in-app unlock. The product ID below must
/// be created in App Store Connect as a "non-consumable" one-time purchase.
/// Stripe creds stay for the web companion site if we build one later.
@MainActor
final class PurchaseStore: ObservableObject {
    @Published var colorUnlocked = false
    @Published var checking = true

    static let productID = "com.snail3d.mascii.color"

    private var product: Product?
    @Published var formattedPrice: String?

    init() {
        Task { await load() }
    }

    private func load() async {
        await restore()
        do {
            let items = try await Product.products(for: [Self.productID])
            product = items.first
            formattedPrice = items.first?.displayPrice
        } catch {
            // offline / not configured yet — free B&W tier still works
        }
        checking = false
    }

    func purchase() async {
        guard let product else { return }
        do {
            let result = try await product.purchase()
            if case .success(let verification) = result {
                if case .verified(let tx) = verification {
                    try await tx.finish()
                    colorUnlocked = true
                }
            }
        } catch {}
    }

    private func restore() async {
        // Walk all transactions looking for our non-consumable
        do {
            for try await verification in Transaction.all {
                guard case .verified(let tx) = verification else { continue }
                if tx.productID == Self.productID {
                    colorUnlocked = true
                    break
                }
            }
        } catch {}
    }
}
