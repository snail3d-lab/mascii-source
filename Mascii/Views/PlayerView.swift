import SwiftUI
import MetalKit
import AVFoundation
import QuartzCore

/// Live ASCII player. MTKView drives the display link; each tick we advance
/// one source frame (~24fps cadence) and run a single compute pass into the
/// drawable. When colorMode is on (unlocked), the source frame's own color
/// is blended into the glyphs.
struct PlayerView: UIViewRepresentable {
    let url: URL
    var brightness: Double
    var colorMode: Bool

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.renderer.device
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 30
        context.coordinator.begin()
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer.brightness = Float(brightness)
        context.coordinator.renderer.colorMode = colorMode
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: AsciiRenderer
        let pipeline: VideoPipeline?
        private var lastTime: TimeInterval = 0
        private var time: TimeInterval = 0

        init(url: URL) {
            renderer = AsciiRenderer(outW: 1080, outH: 1920, cellCols: 66)
            pipeline = VideoPipeline(url: url,
                                     cellW: renderer.cellCols,
                                     cellH: renderer.cellRows)
            super.init()
        }

        func begin() {
            // Prime the textures so the first draw is defined.
            renderer.uploadCellImage(Self.blackCell(cols: renderer.cellCols,
                                                    rows: renderer.cellRows))
            lastTime = CACurrentMediaTime()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }

            // Advance source ~24fps (skip frames if we're ahead)
            let now = CACurrentMediaTime()
            if now - lastTime >= 1.0 / 24.0 {
                lastTime = now
                time = now
                if let pipeline {
                    if let pair = pipeline.nextCellPair() {
                        renderer.uploadCellImage(pair.gray)
                        if renderer.colorMode {
                            renderer.uploadCellColor(pair.color)
                        }
                    }
                    // EOF: hold last frame
                }
            }

            // Projector flicker (slow sine + tiny noise)
            let flickerA = 0.02 * sin(now * 23.7)
            let flickerB = 0.008 * sin(now * 57.3)
            renderer.flicker = Float(1.0 + flickerA + flickerB)

            renderer.render(drawable: drawable, time: time)
        }

        static func blackCell(cols: Int, rows: Int) -> CGImage {
            var data = [UInt8](repeating: 0, count: cols * rows)
            let cs = CGColorSpaceCreateDeviceGray()
            let provider = CGDataProvider(data: Data(data) as CFData)!
            return CGImage(width: cols, height: rows, bitsPerComponent: 8,
                           bitsPerPixel: 8, bytesPerRow: cols, space: cs,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        }
    }
}
