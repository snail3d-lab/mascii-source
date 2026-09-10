import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo

/// Reads a video file, downscales each frame to the ASCII cell grid
/// (one texel of luminance per character cell, plus a color texel for the
/// color tier), and pushes it to the renderer.
///
/// Two consumers:
///  - live player:  `nextCellPair()` each display tick
///  - offline render: walks the whole asset into an mp4
final class VideoPipeline {

    let asset: AVAsset
    let cellW: Int
    let cellH: Int
    let fps: Int
    let duration: TimeInterval

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    init?(url: URL, cellW: Int, cellH: Int) {
        let a = AVAsset(url: url)
        guard let track = a.tracks(withMediaType: .video).first else { return nil }
        self.asset = a
        self.cellW = cellW
        self.cellH = cellH
        self.fps = Int(track.nominalFrameRate.rounded())
        self.duration = a.duration.seconds

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: cellW,
            kCVPixelBufferHeightKey as String: cellH,
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        do {
            let reader = try AVAssetReader(asset: a)
            reader.add(out)
            guard reader.startReading() else { return nil }
            self.reader = reader
        } catch {
            return nil
        }
        self.output = out
    }

    /// Raw BGRA bytes for the next frame, or nil at EOF.
    private func nextFrame() -> [UInt8]? {
        guard let reader, let out = output else { return nil }
        guard reader.status == .reading,
              let sb = out.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var out_ = [UInt8](repeating: 0, count: cellW * cellH * 4)
        out_.withUnsafeMutableBytes { dst in
            guard let base_ = dst.baseAddress else { return }
            for y in 0..<cellH {
                memcpy(base_ .advanced(by: y * cellW * 4),
                       ptr.advanced(by: y * bpr),
                       cellW * 4)
            }
        }
        return out_
    }

    /// Grayscale + color cell images for the next frame (nil at EOF).
    /// Both images are derived from the SAME downsampled frame so they
    /// stay in lockstep — call this once per tick.
    func nextCellPair() -> (gray: CGImage, color: CGImage)? {
        guard let raw = nextFrame() else { return nil }
        var gray = [UInt8](repeating: 0, count: cellW * cellH)
        for i in 0..<cellW * cellH {
            let p = i * 4
            let b = Int(raw[p]), g = Int(raw[p + 1]), r = Int(raw[p + 2])
            gray[i] = UInt8((b * 299 + g * 587 + r * 114) / 1000)
        }
        guard let g = Self.makeGrayImage(gray: gray, w: cellW, h: cellH),
              let c = makeColorImage(raw) else { return nil }
        return (g, c)
    }

    private func makeColorImage(_ raw: [UInt8]) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(raw) as CFData),
              let img = CGImage(width: cellW, height: cellH,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: cellW * 4, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else {
            return nil
        }
        return img
    }

    var isAtEnd: Bool {
        reader?.status != .reading
    }

    private static func makeGrayImage(gray: [UInt8], w: Int, h: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let img = CGImage(width: w, height: h,
                                bitsPerComponent: 8, bitsPerPixel: 8,
                                bytesPerRow: w, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else {
            return nil
        }
        return img
    }
}
