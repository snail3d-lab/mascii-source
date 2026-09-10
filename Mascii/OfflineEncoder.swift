import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Metal

/// Overnight mode: walks a whole video through the ASCII renderer and
/// encodes the result to an MP4 on disk.
///
/// Render loop runs on a background queue; UI progress is dispatched to
/// main. Screen must stay on (iOS suspends background app work) — the UI
/// shows a "keep the light on" note while this runs.
final class OfflineEncoder: ObservableObject, @unchecked Sendable {
    @Published var progress: Double = 0
    @Published var isRunning = false
    @Published var outputURL: URL?
    @Published var error: String?
    @Published var estimate: TimeInterval?

    private let renderer: AsciiRenderer
    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); defer { lock.unlock() }; _cancelled = newValue }
    }
    private let workQueue = DispatchQueue(label: "mascii.offline", qos: .userInitiated)

    init(renderer: AsciiRenderer) {
        self.renderer = renderer
    }

    /// Convenience: build a dedicated renderer (offline path only).
    convenience init() {
        self.init(renderer: AsciiRenderer())
    }

    func cancel() {
        cancelled = true
        DispatchQueue.main.async { self.isRunning = false }
    }

    func start(video: URL, brightness: Float = 1.15, colorMode: Bool = false) {
        guard !isRunning else { return }
        error = nil
        outputURL = nil
        progress = 0
        isRunning = true
        cancelled = false
        renderer.brightness = brightness
        renderer.colorMode = colorMode

        workQueue.async { [weak self] in
            guard let self else { return }
            Task { await self.run(video: video) }
        }
    }

    // MARK: - work

    private func run(video: URL) async {
        do {
            let asset = AVURLAsset(url: video)
            let tracks = try await asset.load(.tracks)
            guard let track = tracks.first(where: { $0.mediaType == .video }) else {
                throw EncodeError.noVideo
            }
            let fps = max(1, Int(try await track.load(.nominalFrameRate).rounded()))
            let duration = try await asset.load(.duration).seconds
            let total = max(1, Int(duration * Double(fps)))

            DispatchQueue.main.async { self.estimate = duration }

            let outURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("mascii_\(Int(Date().timeIntervalSince1970)).mp4")

            let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: renderer.outW,
                AVVideoHeightKey: renderer.outH,
                AVVideoExpectedSourceFrameRateKey: fps,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            guard let pipeline = VideoPipeline(url: video,
                                              cellW: renderer.cellCols,
                                              cellH: renderer.cellRows) else {
                writer.cancelWriting()
                throw EncodeError.noVideo
            }

            // BGRA pixel buffer + matching video format description (iOS 26:
            // CMVideoFormatDescription, derived from the image buffer).
            var firstPB: CVPixelBuffer?
            let pbStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                                               renderer.outW, renderer.outH,
                                               kCVPixelFormatType_32BGRA, nil, &firstPB)
            guard pbStatus == kCVReturnSuccess, let firstPB else {
                writer.cancelWriting()
                throw EncodeError.noVideo
            }
            var formatDesc: CMVideoFormatDescription?
            let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil,
                imageBuffer: firstPB,
                formatDescriptionOut: &formatDesc)
            guard fdStatus == noErr, let formatDesc else {
                writer.cancelWriting()
                throw EncodeError.noVideo
            }

            var i = 0
            let tick = 1.0 / Double(fps)
            while !cancelled {
                guard let pair = pipeline.nextCellPair() else { break }
                renderer.flicker = Float(1.0 + 0.018 * sin(Double(i) * 0.7))
                renderer.uploadCellImage(pair.gray)
                if renderer.colorMode {
                    renderer.uploadCellColor(pair.color)
                }
                guard let tex = renderer.renderOffscreen(time: Double(i) * tick) else { break }
                _ = tex

                while !input.isReadyForMoreMediaData && !cancelled {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                if cancelled { break }

                guard let sample = makeSampleBuffer(pixelBuffer: makePixelBuffer(from: tex),
                                                    formatDesc: formatDesc,
                                                    frameIndex: i,
                                                    fps: fps) else { continue }
                input.append(sample)

                i += 1
                if i % fps == 0 {
                    let p = Double(i) / Double(total)
                    DispatchQueue.main.async { self.progress = p }
                }
            }

            input.markAsFinished()
            try await writer.finishWriting()
            if !cancelled {
                DispatchQueue.main.async {
                    self.outputURL = outURL
                    self.progress = 1.0
                    self.isRunning = false
                }
            } else {
                try? FileManager.default.removeItem(at: outURL)
            }
        } catch {
            DispatchQueue.main.async {
                self.error = "Render failed: \(error.localizedDescription)"
                self.isRunning = false
            }
        }
    }

    // MARK: - sample buffer

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer?,
                                  formatDesc: CMVideoFormatDescription,
                                  frameIndex: Int,
                                  fps: Int) -> CMSampleBuffer? {
        guard let pb = pixelBuffer else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps)),
            decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sb)
        guard status == noErr else { return nil }
        return sb
    }

    // MARK: - private

    private func makePixelBuffer(from tex: MTLTexture) -> CVPixelBuffer? {
        // private -> shared staging (blit) -> CPU bytes -> CVPixelBuffer
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .bgra8Unorm
        desc.width = renderer.outW
        desc.height = renderer.outH
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let staging = renderer.device.makeTexture(descriptor: desc),
              let cmd = renderer.queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, to: staging)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var data = Data(count: staging.width * staging.height * 4)
        data.withUnsafeMutableBytes { buf in
            guard let ptr = buf.bindMemory(to: UInt8.self).baseAddress else { return }
            staging.getBytes(ptr,
                             bytesPerRow: staging.width * 4,
                             from: MTLRegionMake2D(0, 0, staging.width, staging.height),
                             mipmapLevel: 0)
        }

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,
                            renderer.outW, renderer.outH,
                            kCVPixelFormatType_32BGRA,
                            nil, &pb)
        guard let pixelBuffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        data.withUnsafeBytes { src in
            let s = src.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<renderer.outH {
                memcpy(base.advanced(by: y * bpr),
                       s.advanced(by: y * renderer.outW * 4),
                       renderer.outW * 4)
            }
        }
        return pixelBuffer
    }

    enum EncodeError: LocalizedError {
        case noVideo
        var errorDescription: String? { "No video track found in file." }
    }
}
