import Foundation
import Metal
import MetalKit
import simd
import CoreGraphics
import UIKit

/// Core ASCII renderer.
///
/// Per-frame pipeline (one Metal compute pass over the full output canvas):
///   1. CPU: the source frame is downsampled to a grayscale CGImage
///      (cellCols x cellRows) and uploaded as a small r8 texture.
///   2. GPU: each output pixel maps to its cell, quantizes luminance into
///      one of 12 palette levels, gathers the glyph from a pre-rendered
///      atlas (12 monospace chars side-by-side, white on black), tints.
///
/// Color tier (unlocked): a second small texture holds the source frame's
/// color; the shader blends it into the glyph color. B&W tier only samples
/// the luminance texture — a black placeholder is bound for the color slot.
///
/// Same bitmap-atlas trick as the desktop numpy renderer, ~2-5 ms/frame
/// on A-series silicon.
final class AsciiRenderer {

    // Must match the struct layout in ascii.metal exactly (32 bytes).
    struct Uniforms {
        var outputSize: SIMD2<UInt32>
        var cellGrid: SIMD2<UInt32>
        var flicker: Float
        var brightness: Float
        var vignette: Float
        var time: Float
        var colorMode: UInt32
        var pad: SIMD2<Float>
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    let atlasTexture: MTLTexture

    var brightness: Float = 1.15   // approved ~15% lift
    var flicker: Float = 1.0
    var vignette: Float = 0.22
    var colorMode: Bool = false     // true = Snail 3D color tier

    let outW: Int
    let outH: Int
    let cellCols: Int
    let cellRows: Int

    private let glyphString = " .:-=+*#%@"
    private var cellTexture: MTLTexture?
    private var colorCellTexture: MTLTexture?
    private lazy var blackPlaceholder: MTLTexture = {
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = cellCols
        desc.height = cellRows
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        Self.fillTextureBlack(tex, cols: cellCols, rows: cellRows)
        return tex
    }()

    /// Zero-fill a whole rgba8 texture.
    private static func fillTextureBlack(_ tex: MTLTexture, cols: Int, rows: Int) {
        let zeros = [UInt8](repeating: 0, count: cols * rows * 4)
        let region = MTLRegionMake2D(0, 0, cols, rows)
        zeros.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                tex.replace(region: region, mipmapLevel: 0, slice: 0,
                            withBytes: base, bytesPerRow: cols * 4,
                            bytesPerImage: cols * 4 * rows)
            }
        }
    }

    init(outW: Int = 1080, outH: Int = 1920, cellCols: Int = 66) {
        let cellSize = outH / 48
        self.outW = outW
        self.outH = outH
        self.cellCols = cellCols
        self.cellRows = outH / cellSize

        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("No Metal device")
        }
        device = dev
        queue = device.makeCommandQueue()!

        guard let lib = device.makeDefaultLibrary(),
              let fn = lib.makeFunction(name: "ascii_fragment"),
              let p = try? device.makeComputePipelineState(function: fn) else {
            fatalError("Failed to build Metal pipeline")
        }
        pipeline = p

        atlasTexture = Self.makeGlyphAtlas(device: dev, glyph: glyphString, cellSize: cellSize)
    }

    // MARK: - glyph atlas (12 tiles side by side, R8 coverage)

    static func makeGlyphAtlas(device: MTLDevice, glyph: String, cellSize: Int) -> MTLTexture {
        let n = glyph.count
        let w = n * cellSize
        let ctx = CGContext(data: nil, width: w, height: cellSize,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: cellSize))
        ctx.setFillColor(gray: 1, alpha: 1)
        let font = UIFont.monospacedSystemFont(ofSize: CGFloat(cellSize) * 0.8, weight: .regular)
        for (i, ch) in glyph.enumerated() {
            let s = String(ch)
            s.draw(at: CGPoint(x: CGFloat(i) * CGFloat(cellSize), y: CGFloat(cellSize) * 0.1),
                   withAttributes: [.font: font])
        }
        let cg = ctx.makeImage()!
        guard let provider = cg.dataProvider else {
            fatalError("Failed to get atlas data provider")
        }
        guard let cfAtlas = provider.data else {
            fatalError("Failed to copy atlas provider data")
        }
        let atlasData = cfAtlas as Data
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .r8Unorm
        desc.width = w
        desc.height = cellSize
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create glyph atlas texture")
        }
        atlasData.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let bpr = cg.bytesPerRow > 0 ? cg.bytesPerRow : cg.width
            tex.replace(region: MTLRegionMake2D(0, 0, w, cellSize),
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: bytes,
                        bytesPerRow: bpr,
                        bytesPerImage: bpr * cellSize)
        }
        return tex
    }

    // MARK: - cell image uploads

    /// Replaces the cell-luminance image (must be cellCols x cellRows,
    /// 8-bit gray). Re-creates the upload texture each frame — the image
    /// is ~2.6 KB, so this is negligible.
    func uploadCellImage(_ gray: CGImage) {
        guard gray.width == cellCols, gray.height == cellRows,
              let provider = gray.dataProvider else { return }
        guard let cfGray = provider.data else { return }
        let grayData = cfGray as Data
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .r8Unorm
        desc.width = cellCols
        desc.height = cellRows
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        grayData.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let bpr = gray.bytesPerRow > 0 ? gray.bytesPerRow : gray.width
            tex.replace(region: MTLRegionMake2D(0, 0, cellCols, cellRows),
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: bytes,
                        bytesPerRow: bpr,
                        bytesPerImage: bpr * cellRows)
        }
        cellTexture = tex
    }

    /// Replaces the source-color image for the color tier (cellCols x
    /// cellRows, BGRA8). Ignored when colorMode is false.
    func uploadCellColor(_ color: CGImage) {
        guard color.width == cellCols, color.height == cellRows,
              let provider = color.dataProvider else { return }
        guard let cfColor = provider.data else { return }
        let colorData = cfColor as Data
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .bgra8Unorm
        desc.width = cellCols
        desc.height = cellRows
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        colorData.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let bpr = color.bytesPerRow > 0 ? color.bytesPerRow : color.width * 4
            tex.replace(region: MTLRegionMake2D(0, 0, cellCols, cellRows),
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: bytes,
                        bytesPerRow: bpr,
                        bytesPerImage: bpr * cellRows)
        }
        colorCellTexture = tex
    }

    // MARK: - render

    /// Renders the current cell image into the view's drawable and presents
    /// it (live player path). The drawable is a CVPixelBuffer on iOS, which
    /// also conforms to MTLTexture.
    func render(drawable: MTLDrawable, time: TimeInterval) {
        guard let dst = drawable as? MTLTexture,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        dispatch(into: enc, dst: dst, time: time)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Renders into a pre-allocated texture (offline encoder path).
    func render(into dst: MTLTexture, time: TimeInterval) {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        dispatch(into: enc, dst: dst, time: time)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()   // offline path: correctness over throughput
    }

    /// Convenience for offline mode: render into a fresh private texture.
    func renderOffscreen(time: TimeInterval) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .bgra8Unorm
        desc.width = outW
        desc.height = outH
        desc.usage = .shaderWrite
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        render(into: tex, time: time)
        return tex
    }

    private func dispatch(into enc: MTLComputeCommandEncoder,
                          dst: MTLTexture,
                          time: TimeInterval) {
        guard let cellTex = cellTexture else { return }

        var uniform = Uniforms(
            outputSize: [UInt32(outW), UInt32(outH)],
            cellGrid: [UInt32(cellCols), UInt32(cellRows)],
            flicker: flicker, brightness: brightness, vignette: vignette,
            time: Float(fmod(time, 3600)),
            colorMode: colorMode ? 1 : 0,
            pad: .zero)

        enc.setComputePipelineState(pipeline)
        enc.setTexture(cellTex, index: 0)
        enc.setTexture(atlasTexture, index: 1)
        enc.setTexture(colorMode ? (colorCellTexture ?? blackPlaceholder) : blackPlaceholder, index: 2)
        enc.setTexture(dst, index: 3)
        enc.setBytes(&uniform, length: MemoryLayout<Uniforms>.size, index: 0)

        let wgp = pipeline.threadExecutionWidth
        let hgp = max(1, pipeline.maxTotalThreadsPerThreadgroup / wgp)
        let threadsPerGroup = MTLSize(width: wgp, height: hgp, depth: 1)
        let grid = MTLSize(width: outW, height: outH, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: threadsPerGroup)
    }
}
