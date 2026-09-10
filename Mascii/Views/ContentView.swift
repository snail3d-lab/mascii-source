import SwiftUI
import AVKit

/// Snail 3D design tokens (see ~/snail-design, DESIGN.md).
enum Snail {
    static let shell = Color(red: 0.043, green: 0.055, blue: 0.047)   // #0B0E0C green-black
    static let raised = Color(red: 0.110, green: 0.137, blue: 0.102)  // #1C231A
    static let lime = Color(red: 0.639, green: 0.902, blue: 0.208)    // #A3E635
    static let neutrino = Color(red: 0.949, green: 0.961, blue: 0.933) // #F2F5EE
}

struct ContentView: View {
    @EnvironmentObject private var store: PurchaseStore
    @StateObject private var encoder = OfflineEncoder()

    @State private var videoURL: URL?
    @State private var showPaywall = false
    @State private var brightness: Double = 1.15
    @State private var useColor = false

    private let logo =
"""
   .-========-.
   |   MASSCI  |
   '--------=='
    ( .-==-.- )
      ( O  O )
       \\__/
      ____
     /    \\
    /  _  \\
   / /   \\ \\
  / / ___ \\ \\
 /_/ ===== \\_
"""

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Snail.raised, Snail.shell, .black],
                center: .top, startRadius: 40, endRadius: 640)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text(logo)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Snail.lime.opacity(0.55))
                    .lineSpacing(0)
                    .padding(.top, 8)

                if let url = videoURL {
                    PlayerView(url: url, brightness: brightness,
                               colorMode: useColor && store.colorUnlocked)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                    VStack(spacing: 14) {
                        Text("Turn any video into ASCII art")
                            .font(.headline)
                            .foregroundStyle(Snail.neutrino)
                        Text("Pick a video, then tap Convert.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.bottom, 40)
                    Spacer()
                }

                controls
            }
            .padding(.horizontal, 16)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
        .onChange(of: encoder.outputURL) { _, url in
            // Auto-open the share sheet when a render finishes.
            if let url { share(url) }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let url = videoURL {
                HStack(spacing: 12) {
                    Button("Change video") { videoURL = nil; encoder.outputURL = nil }
                        .buttonStyle(.bordered)

                    // B&W / Color tier toggle
                    HStack(spacing: 0) {
                        tierButton("B&W", active: !useColor) { useColor = false }
                        tierButton("Color", active: useColor) {
                            if store.colorUnlocked {
                                useColor = true
                            } else {
                                showPaywall = true
                            }
                        }
                    }
                    .background(Snail.raised, in: Capsule())
                    .overlay(Capsule().stroke(Snail.lime.opacity(store.colorUnlocked ? 0.5 : 0.15), lineWidth: 1))
                }

                HStack(spacing: 10) {
                    Image(systemName: "sun.min")
                    Slider(value: $brightness, in: 0.6...1.6)
                    Image(systemName: "sun.max")
                }
                .foregroundStyle(.white.opacity(0.5))

                if encoder.isRunning {
                    // --- conversion in progress ---
                    VStack(spacing: 8) {
                        HStack {
                            Label("Converting… \(Int(encoder.progress * 100))%",
                                  systemImage: "gearshape.2")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Snail.lime)
                            Spacer()
                            Button("Cancel") { encoder.cancel() }
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        ProgressView(value: encoder.progress)
                            .tint(Snail.lime)
                        Text("Keep the screen on — long clips take a while.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(12)
                    .background(Snail.raised, in: RoundedRectangle(cornerRadius: 12))
                } else if let out = encoder.outputURL {
                    // --- finished: share the result ---
                    Button {
                        share(out)
                    } label: {
                        Label("Share or Save Result", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Snail.lime)
                    .foregroundStyle(.black)
                } else {
                    // --- ready: the main CTA ---
                    if let err = encoder.error {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    Button {
                        encoder.start(video: url,
                                      brightness: Float(brightness),
                                      colorMode: useColor && store.colorUnlocked)
                    } label: {
                        Label("Convert to ASCII", systemImage: "wand.and.stars")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Snail.lime)
                    .foregroundStyle(.black)
                }
            } else {
                Button {
                    pickVideo()
                } label: {
                    Label("Choose Video", systemImage: "film")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.bottom, 12)
    }

    private func tierButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(active ? Snail.lime : .clear, in: Capsule())
                .foregroundStyle(active ? .black : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    private func pickVideo() {
        let vc = UIImagePickerController()
        vc.sourceType = .photoLibrary
        vc.mediaTypes = ["public.movie", "public.video"]
        vc.videoQuality = .typeHigh
        vc.delegate = VideoPickerBridge.shared
        VideoPickerBridge.shared.onPick = { url in
            videoURL = url
            encoder.outputURL = nil
            encoder.error = nil
        }
        if let root = AppRootController.find() {
            root.present(vc, animated: true)
        }
    }

    private func share(_ url: URL) {
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let root = AppRootController.find() {
            root.present(ac, animated: true)
        }
    }
}

// Small bridge to present the picker from SwiftUI
final class VideoPickerBridge: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    static let shared = VideoPickerBridge()
    var onPick: ((URL) -> Void)?

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        if let url = info[.mediaURL] as? URL {
            onPick?(url)
        }
        picker.dismiss(animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

enum AppRootController {
    static func find() -> UIViewController? {
        var vc = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}
