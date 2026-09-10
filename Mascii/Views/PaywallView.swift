import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var store: PurchaseStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            RadialGradient(colors: [Snail.raised, Snail.shell, .black],
                           center: .top, startRadius: 0, endRadius: 500)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer().frame(height: 48)
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Snail.lime)

                Text("Mascii COLOR")
                    .font(.system(size: 32, weight: .black, design: .monospaced))
                    .foregroundStyle(Snail.neutrino)

                Text("Unlock the Snail 3D color tier")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))

                VStack(spacing: 12) {
                    row("B&W ASCII stays free, forever")
                    row("Color video, tinted glyphs in Snail lime")
                    row("One purchase. No ads. No subscription.")
                }

                if let price = store.formattedPrice {
                    Button {
                        Task {
                            await store.purchase()
                            if store.colorUnlocked { dismiss() }
                        }
                    } label: {
                        Text("Unlock Color · \(price)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Snail.lime)
                    .foregroundStyle(.black)
                    .disabled(store.checking)
                } else {
                    ProgressView("Loading…").foregroundStyle(.white.opacity(0.4))
                }

                if store.colorUnlocked {
                    Label("Color unlocked", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Snail.lime)
                }

                Spacer()
                Button("Keep B&W") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer().frame(height: 12)
            }
            .padding(.horizontal, 28)
        }
    }

    private func row(_ s: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Snail.lime.opacity(0.7))
            Text(s).font(.subheadline).foregroundStyle(.white.opacity(0.85))
        }
    }
}
