import Metal
import MetalKit
import simd

/// Vertex data sent to the GPU. Must match the Metal `Vertex` struct layout:
/// non-packed `float2` + `float4` = 32 bytes stride (SIMD4 has 16-byte alignment).
/// Using `packed_float2/4` in Metal would be 24 bytes, causing garbled rendering.
struct SpectrumVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// 3D vertex data for the surface visualisation mode.
/// Must match Metal's SurfaceVertexIn layout: float3 + float3 + float4 = 48 bytes.
struct SurfaceVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

/// Uniform buffer for the 3D surface pipeline.
/// Must match Metal's SurfaceUniforms layout: float4x4 + float4 = 80 bytes.
struct SurfaceUniforms {
    var mvpMatrix: simd_float4x4
    var lightDirectionAndAmbient: SIMD4<Float>  // xyz = normalised light dir, w = ambient
}

/// Drives all GPU rendering at 60fps via Metal.
///
/// Reads raw spectrum data from `AudioEngine` and applies its own 60fps
/// asymmetric smoothing (fast attack, slow decay) and peak tracking,
/// decoupled from the ~21fps audio callback rate. This produces silky-smooth
/// animation regardless of audio update timing.
///
/// Five visualisation modes: Bars, Curve, Circular, and Spectrogram share a
/// single 2D vertex/fragment shader pipeline. Surface mode uses a separate
/// 3D pipeline with normals, MVP matrix, and directional lighting.
/// The CPU builds coloured triangle vertices each frame (up to 200K), uploads
/// them to a pre-allocated Metal buffer, and issues a single draw call.
class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer

    weak var audioEngine: AudioEngine?
    var mode: VisualizationMode = .bars
    private var aspectRatio: Float = 1.0

    private let bandCount = SpectrumLayout.bandCount
    private let maxVertexCount = 200_000

    // Layout constants (NDC)
    private let specLeft = SpectrumLayout.spectrumLeft
    private let specRight = SpectrumLayout.spectrumRight
    private let specBottom = SpectrumLayout.spectrumBottom
    private let specTop = SpectrumLayout.spectrumTop
    private let waveLeft = SpectrumLayout.waveformLeft
    private let waveRight = SpectrumLayout.waveformRight
    private let waveBottom = SpectrumLayout.waveformBottom
    private let waveTop = SpectrumLayout.waveformTop

    // 60fps display smoothing (decoupled from ~21fps audio callback rate)
    //
    // Asymmetric lerp is key to professional-quality audio visualisers:
    // fast attack captures transients like drum hits instantly, while slow
    // decay creates a smooth, natural fade. The 3:1 ratio between attack
    // and decay is a common starting point in pro audio metering.
    private var displaySpectrum: [Float]
    private var displayPeaks: [Float]
    private let smoothingLerp: Float = 0.35      // attack speed (per frame at 60fps)
    private let decayLerp: Float = 0.12           // decay speed — slower for smooth falls
    private let peakDecayRate: Float = 0.006      // peak indicators fall gently (~3.5s full fall)

    // Spectrogram history (circular buffer)
    private var spectrogramBuffer: [[Float]]
    private var spectrogramWriteIndex = 0
    private let spectrogramDepth = 128
    private var spectrogramFrameCounter = 0

    // 3D surface pipeline
    private let surfacePipelineState: MTLRenderPipelineState
    private let surfaceVertexBuffer: MTLBuffer
    private let uniformBuffer: MTLBuffer
    private let depthStencilState: MTLDepthStencilState

    // Surface history buffer (60 rows for ~3s at 20fps, separate from spectrogram)
    private let surfaceDepth = 60
    private var surfaceBuffer: [[Float]]
    private var surfaceWriteIndex = 0
    private var surfaceFrameCounter = 0

    // Two fixed camera positions — one for normal view (mic or transport bar),
    // one for compact view (music browser open). Selected by aspect ratio:
    // normal view is tall (aspect < 0.70), browser open is short (aspect > 0.70).
    private let cameraAzimuthNormal: Float = 40.0
    private let cameraElevationNormal: Float = 34.0
    private let cameraDistanceNormal: Float = 6.5

    private let cameraAzimuthCompact: Float = 40.0
    private let cameraElevationCompact: Float = 32.0
    private let cameraDistanceCompact: Float = 3.5

    // FPS tracking
    private var frameCount = 0
    private var fpsAccumulator: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    var currentFPS: Int = 0

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        self.device = device
        self.commandQueue = commandQueue

        mtkView.device = device
        mtkView.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1.0)
        mtkView.preferredFramesPerSecond = 60

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vertex_main")
        desc.fragmentFunction = library.makeFunction(name: "fragment_main")
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Both pipelines must declare the depth format to match MTKView
        desc.depthAttachmentPixelFormat = .depth32Float

        guard let ps = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipelineState = ps

        guard let vb = device.makeBuffer(length: maxVertexCount * MemoryLayout<SpectrumVertex>.stride,
                                          options: .storageModeShared) else { return nil }
        vertexBuffer = vb

        // 3D surface pipeline
        let surfaceDesc = MTLRenderPipelineDescriptor()
        surfaceDesc.vertexFunction = library.makeFunction(name: "surface_vertex")
        surfaceDesc.fragmentFunction = library.makeFunction(name: "surface_fragment")
        surfaceDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        surfaceDesc.colorAttachments[0].isBlendingEnabled = true
        surfaceDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        surfaceDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        surfaceDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        surfaceDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        surfaceDesc.depthAttachmentPixelFormat = .depth32Float

        guard let sps = try? device.makeRenderPipelineState(descriptor: surfaceDesc) else { return nil }
        surfacePipelineState = sps

        // Depth stencil for 3D surface
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        guard let dss = device.makeDepthStencilState(descriptor: depthDesc) else { return nil }
        depthStencilState = dss

        // Surface vertex + uniform buffers
        let surfaceMaxVertices = 100_000  // ~46K solid mesh + ~46K ridgeline outlines (60 rows)
        guard let svb = device.makeBuffer(length: surfaceMaxVertices * MemoryLayout<SurfaceVertex>.stride,
                                           options: .storageModeShared) else { return nil }
        surfaceVertexBuffer = svb
        guard let ub = device.makeBuffer(length: MemoryLayout<SurfaceUniforms>.stride,
                                          options: .storageModeShared) else { return nil }
        uniformBuffer = ub

        spectrogramBuffer = Array(repeating: [Float](repeating: 0, count: SpectrumLayout.bandCount),
                                   count: spectrogramDepth)
        surfaceBuffer = Array(repeating: [Float](repeating: 0, count: SpectrumLayout.bandCount),
                               count: surfaceDepth)

        displaySpectrum = [Float](repeating: 0, count: SpectrumLayout.bandCount)
        displayPeaks = [Float](repeating: 0, count: SpectrumLayout.bandCount)
        lastFrameTime = CACurrentMediaTime()

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspectRatio = Float(size.width / size.height)
    }

    func draw(in view: MTKView) {
        // FPS tracking
        let now = CACurrentMediaTime()
        let dt = now - lastFrameTime
        lastFrameTime = now
        fpsAccumulator += dt
        frameCount += 1
        if fpsAccumulator >= 0.5 {
            currentFPS = Int(Double(frameCount) / fpsAccumulator)
            frameCount = 0
            fpsAccumulator = 0
        }

        let targetSpectrum = audioEngine?.spectrumData ?? []
        let waveformData = audioEngine?.waveformData ?? []

        guard targetSpectrum.count >= bandCount else { return }

        // 60fps display smoothing — asymmetric: fast attack, slow decay
        for i in 0..<bandCount {
            let target = targetSpectrum[i]
            let current = displaySpectrum[i]
            if target > current {
                displaySpectrum[i] = current + (target - current) * smoothingLerp
            } else {
                displaySpectrum[i] = current + (target - current) * decayLerp
            }
            // Peak tracking at 60fps
            if displaySpectrum[i] > displayPeaks[i] {
                displayPeaks[i] = displaySpectrum[i]
            } else {
                displayPeaks[i] = max(0, displayPeaks[i] - peakDecayRate)
            }
        }

        // Update spectrogram history (~20fps, not every frame)
        spectrogramFrameCounter += 1
        if spectrogramFrameCounter % 3 == 0 {
            spectrogramBuffer[spectrogramWriteIndex] = Array(displaySpectrum.prefix(bandCount))
            spectrogramWriteIndex = (spectrogramWriteIndex + 1) % spectrogramDepth
        }

        // Update surface history (~20fps, separate buffer from spectrogram)
        surfaceFrameCounter += 1
        if surfaceFrameCounter % 3 == 0 {
            surfaceBuffer[surfaceWriteIndex] = Array(displaySpectrum.prefix(bandCount))
            surfaceWriteIndex = (surfaceWriteIndex + 1) % surfaceDepth
        }

        // Beat flash decay (decremented at 60fps)
        var flashBoost: Float = 0
        if let engine = audioEngine {
            if engine.beatFlashCounter > 0 {
                flashBoost = 0.15
                engine.beatFlashCounter -= 1
                if engine.beatFlashCounter == 0 {
                    engine.beatFlash = false
                }
            }
        }

        // Build vertices with pre-allocated capacity
        var vertices: [SpectrumVertex] = []
        let estimatedCount: Int
        switch mode {
        case .spectrogram:
            estimatedCount = spectrogramDepth * bandCount * 6 + 4000
        case .circular:
            estimatedCount = bandCount * 12 + 4000
        case .curve:
            estimatedCount = bandCount * 18 + 4000
        case .bars:
            estimatedCount = bandCount * 12 + 4000
        case .surface, .surfaceLines:
            estimatedCount = 0  // surface modes use separate pipeline
        }
        vertices.reserveCapacity(estimatedCount)

        // Grid lines (bars and curve modes)
        if mode == .bars || mode == .curve {
            buildGridVertices(into: &vertices)
        }

        // Surface modes use a separate 3D pipeline
        if mode == .surface || mode == .surfaceLines {
            drawSurface(in: view, withRidgelines: mode == .surfaceLines)
            return
        }

        // Spectrum visualization (using 60fps-smoothed display data)
        switch mode {
        case .bars:
            buildBarVertices(into: &vertices, spectrum: displaySpectrum, peaks: displayPeaks, flashBoost: flashBoost)
        case .curve:
            buildCurveVertices(into: &vertices, spectrum: displaySpectrum, peaks: displayPeaks, flashBoost: flashBoost)
        case .circular:
            buildCircularVertices(into: &vertices, spectrum: displaySpectrum, peaks: displayPeaks)
        case .spectrogram:
            buildSpectrogramVertices(into: &vertices)
        case .surface, .surfaceLines:
            break // handled above
        }

        // Waveform
        buildWaveformVertices(into: &vertices, waveform: waveformData)

        guard !vertices.isEmpty else { return }

        let dataSize = vertices.count * MemoryLayout<SpectrumVertex>.stride
        guard dataSize <= vertexBuffer.length else { return }

        vertices.withUnsafeBytes { ptr in
            vertexBuffer.contents().copyMemory(from: ptr.baseAddress!, byteCount: ptr.count)
        }

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Grid

    private func buildGridVertices(into vertices: inout [SpectrumVertex]) {
        let gridColor = SIMD4<Float>(1, 1, 1, 0.06)
        let lineThick: Float = 0.002

        // Horizontal dB lines at 0, -20, -40, -60, -80
        let dbFractions: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
        for frac in dbFractions {
            let y = specBottom + frac * (specTop - specBottom)
            addQuad(to: &vertices, x0: specLeft, y0: y - lineThick, x1: specRight, y1: y + lineThick, color: gridColor)
        }

        // Vertical frequency lines
        let freqs: [Float] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        let logMin = log10(Float(20))
        let logMax = log10(Float(20000))
        for freq in freqs {
            let frac = (log10(freq) - logMin) / (logMax - logMin)
            let x = specLeft + frac * (specRight - specLeft)
            addQuad(to: &vertices, x0: x - lineThick, y0: specBottom, x1: x + lineThick, y1: specTop, color: gridColor)
        }
    }

    // MARK: - Bars

    private func buildBarVertices(into vertices: inout [SpectrumVertex], spectrum: [Float], peaks: [Float], flashBoost: Float = 0) {
        let totalWidth = specRight - specLeft
        let barStep = totalWidth / Float(bandCount)
        let barWidth = barStep * 0.82
        let specHeight = specTop - specBottom

        for i in 0..<bandCount {
            let x = specLeft + barStep * (Float(i) + 0.5)
            let halfW = barWidth / 2
            let height = spectrum[i] * specHeight
            let y1 = specBottom + height

            let t = Float(i) / Float(bandCount - 1)
            let baseColor = Self.gradientColor(at: t)
            let color = baseColor + SIMD4(flashBoost, flashBoost, flashBoost, 0)
            let dimColor = color * SIMD4(0.35, 0.35, 0.35, 1.0)

            // Bar body (gradient from dim at bottom to bright at top)
            addGradientQuad(to: &vertices,
                            x0: x - halfW, y0: specBottom, x1: x + halfW, y1: y1,
                            bottomColor: dimColor, topColor: color)

            // Peak indicator
            if i < peaks.count {
                let peakY = specBottom + peaks[i] * specHeight
                let peakH: Float = 0.006
                let peakColor = SIMD4<Float>(1, 1, 1, 0.85)
                addQuad(to: &vertices, x0: x - halfW, y0: peakY, x1: x + halfW, y1: peakY + peakH, color: peakColor)
            }
        }
    }

    // MARK: - Curve

    private func buildCurveVertices(into vertices: inout [SpectrumVertex], spectrum: [Float], peaks: [Float], flashBoost: Float = 0) {
        let specHeight = specTop - specBottom
        let flash = SIMD4<Float>(flashBoost, flashBoost, flashBoost, 0)

        // Filled area under curve
        for i in 0..<(bandCount - 1) {
            let t0 = Float(i) / Float(bandCount - 1)
            let t1 = Float(i + 1) / Float(bandCount - 1)
            let x0 = specLeft + t0 * (specRight - specLeft)
            let x1 = specLeft + t1 * (specRight - specLeft)
            let y0Top = specBottom + spectrum[i] * specHeight
            let y1Top = specBottom + spectrum[i + 1] * specHeight

            let color0 = Self.gradientColor(at: t0) + flash
            let color1 = Self.gradientColor(at: t1) + flash
            let dim0 = color0 * SIMD4(0.15, 0.15, 0.15, 0.4)
            let dim1 = color1 * SIMD4(0.15, 0.15, 0.15, 0.4)

            // Two triangles for the filled area
            vertices.append(SpectrumVertex(position: SIMD2(x0, specBottom), color: dim0))
            vertices.append(SpectrumVertex(position: SIMD2(x1, specBottom), color: dim1))
            vertices.append(SpectrumVertex(position: SIMD2(x0, y0Top), color: color0))

            vertices.append(SpectrumVertex(position: SIMD2(x0, y0Top), color: color0))
            vertices.append(SpectrumVertex(position: SIMD2(x1, specBottom), color: dim1))
            vertices.append(SpectrumVertex(position: SIMD2(x1, y1Top), color: color1))
        }

        // Curve outline (thin quads along the top edge)
        let lineWidth: Float = 0.005
        for i in 0..<(bandCount - 1) {
            let t0 = Float(i) / Float(bandCount - 1)
            let t1 = Float(i + 1) / Float(bandCount - 1)
            let x0 = specLeft + t0 * (specRight - specLeft)
            let x1 = specLeft + t1 * (specRight - specLeft)
            let y0 = specBottom + spectrum[i] * specHeight
            let y1 = specBottom + spectrum[i + 1] * specHeight

            let color0 = Self.gradientColor(at: t0) * SIMD4(1.2, 1.2, 1.2, 1.0)
            let color1 = Self.gradientColor(at: t1) * SIMD4(1.2, 1.2, 1.2, 1.0)

            let dx = x1 - x0
            let dy = y1 - y0
            let len = sqrt(dx * dx + dy * dy)
            guard len > 0 else { continue }
            let nx = -dy / len * lineWidth / 2
            let ny = dx / len * lineWidth / 2

            vertices.append(SpectrumVertex(position: SIMD2(x0 + nx, y0 + ny), color: color0))
            vertices.append(SpectrumVertex(position: SIMD2(x0 - nx, y0 - ny), color: color0))
            vertices.append(SpectrumVertex(position: SIMD2(x1 + nx, y1 + ny), color: color1))

            vertices.append(SpectrumVertex(position: SIMD2(x1 + nx, y1 + ny), color: color1))
            vertices.append(SpectrumVertex(position: SIMD2(x0 - nx, y0 - ny), color: color0))
            vertices.append(SpectrumVertex(position: SIMD2(x1 - nx, y1 - ny), color: color1))
        }

        // Peak indicators
        for i in 0..<min(bandCount, peaks.count) {
            let t = Float(i) / Float(bandCount - 1)
            let x = specLeft + t * (specRight - specLeft)
            let peakY = specBottom + peaks[i] * specHeight
            let dotSize: Float = 0.008
            let peakColor = SIMD4<Float>(1, 1, 1, 0.7)
            addQuad(to: &vertices,
                    x0: x - dotSize, y0: peakY - dotSize,
                    x1: x + dotSize, y1: peakY + dotSize,
                    color: peakColor)
        }
    }

    // MARK: - Circular

    private func buildCircularVertices(into vertices: inout [SpectrumVertex], spectrum: [Float], peaks: [Float]) {
        let centerX: Float = 0.0
        let centerY: Float = 0.35
        let innerRadius: Float = 0.10
        let maxOuterRadius: Float = 0.40
        let xScale = 1.0 / aspectRatio // aspect ratio correction for portrait
        let angleStep = 2.0 * Float.pi / Float(bandCount)
        let barAngleWidth = angleStep * 0.78

        for i in 0..<bandCount {
            let angle = Float(i) * angleStep - Float.pi / 2 // start from top
            let magnitude = spectrum[i]
            let outerRadius = innerRadius + magnitude * (maxOuterRadius - innerRadius)

            let t = Float(i) / Float(bandCount - 1)
            let color = Self.gradientColor(at: t)
            let dimColor = color * SIMD4(0.3, 0.3, 0.3, 1.0)

            let halfAngle = barAngleWidth / 2
            let cos0 = cos(angle - halfAngle)
            let sin0 = sin(angle - halfAngle)
            let cos1 = cos(angle + halfAngle)
            let sin1 = sin(angle + halfAngle)

            let innerL = SIMD2(centerX + innerRadius * cos0 * xScale, centerY + innerRadius * sin0)
            let innerR = SIMD2(centerX + innerRadius * cos1 * xScale, centerY + innerRadius * sin1)
            let outerL = SIMD2(centerX + outerRadius * cos0 * xScale, centerY + outerRadius * sin0)
            let outerR = SIMD2(centerX + outerRadius * cos1 * xScale, centerY + outerRadius * sin1)

            vertices.append(SpectrumVertex(position: innerL, color: dimColor))
            vertices.append(SpectrumVertex(position: innerR, color: dimColor))
            vertices.append(SpectrumVertex(position: outerL, color: color))

            vertices.append(SpectrumVertex(position: outerL, color: color))
            vertices.append(SpectrumVertex(position: innerR, color: dimColor))
            vertices.append(SpectrumVertex(position: outerR, color: color))

            // Peak indicator
            if i < peaks.count {
                let peakRadius = innerRadius + peaks[i] * (maxOuterRadius - innerRadius)
                let peakThick: Float = 0.006
                let peakInner = peakRadius - peakThick / 2
                let peakOuter = peakRadius + peakThick / 2
                let peakColor = SIMD4<Float>(1, 1, 1, 0.7)

                let piL = SIMD2(centerX + peakInner * cos0 * xScale, centerY + peakInner * sin0)
                let piR = SIMD2(centerX + peakInner * cos1 * xScale, centerY + peakInner * sin1)
                let poL = SIMD2(centerX + peakOuter * cos0 * xScale, centerY + peakOuter * sin0)
                let poR = SIMD2(centerX + peakOuter * cos1 * xScale, centerY + peakOuter * sin1)

                vertices.append(SpectrumVertex(position: piL, color: peakColor))
                vertices.append(SpectrumVertex(position: piR, color: peakColor))
                vertices.append(SpectrumVertex(position: poL, color: peakColor))

                vertices.append(SpectrumVertex(position: poL, color: peakColor))
                vertices.append(SpectrumVertex(position: piR, color: peakColor))
                vertices.append(SpectrumVertex(position: poR, color: peakColor))
            }
        }
    }

    // MARK: - Spectrogram

    private func buildSpectrogramVertices(into vertices: inout [SpectrumVertex]) {
        let rowHeight = (specTop - specBottom) / Float(spectrogramDepth)

        for row in 0..<spectrogramDepth {
            let bufferIndex = (spectrogramWriteIndex + row) % spectrogramDepth
            let data = spectrogramBuffer[bufferIndex]

            let y0 = specTop - Float(row + 1) * rowHeight
            let y1 = specTop - Float(row) * rowHeight

            for band in 0..<bandCount {
                let x0 = specLeft + (specRight - specLeft) * Float(band) / Float(bandCount)
                let x1 = specLeft + (specRight - specLeft) * Float(band + 1) / Float(bandCount)
                let color = Self.heatmapColor(data[band])

                addQuad(to: &vertices, x0: x0, y0: y0, x1: x1, y1: y1, color: color)
            }
        }
    }

    // MARK: - Waveform

    private func buildWaveformVertices(into vertices: inout [SpectrumVertex], waveform: [Float]) {
        guard waveform.count > 1 else { return }

        let waveMid = (waveBottom + waveTop) / 2
        let waveAmplitude = (waveTop - waveBottom) / 2 * 0.85

        // Center reference line
        let centerColor = SIMD4<Float>(1, 1, 1, 0.08)
        addQuad(to: &vertices, x0: waveLeft, y0: waveMid - 0.001, x1: waveRight, y1: waveMid + 0.001, color: centerColor)

        // Waveform trace
        let waveColor = SIMD4<Float>(0.3, 0.85, 1.0, 0.8)
        let lineThick: Float = 0.004
        let count = waveform.count

        for i in 0..<(count - 1) {
            let t0 = Float(i) / Float(count - 1)
            let t1 = Float(i + 1) / Float(count - 1)

            let x0 = waveLeft + t0 * (waveRight - waveLeft)
            let x1 = waveLeft + t1 * (waveRight - waveLeft)
            let y0 = waveMid + waveform[i] * waveAmplitude
            let y1 = waveMid + waveform[i + 1] * waveAmplitude

            let dx = x1 - x0
            let dy = y1 - y0
            let len = sqrt(dx * dx + dy * dy)
            guard len > 0 else { continue }
            let nx = -dy / len * lineThick / 2
            let ny = dx / len * lineThick / 2

            vertices.append(SpectrumVertex(position: SIMD2(x0 + nx, y0 + ny), color: waveColor))
            vertices.append(SpectrumVertex(position: SIMD2(x0 - nx, y0 - ny), color: waveColor))
            vertices.append(SpectrumVertex(position: SIMD2(x1 + nx, y1 + ny), color: waveColor))

            vertices.append(SpectrumVertex(position: SIMD2(x1 + nx, y1 + ny), color: waveColor))
            vertices.append(SpectrumVertex(position: SIMD2(x0 - nx, y0 - ny), color: waveColor))
            vertices.append(SpectrumVertex(position: SIMD2(x1 - nx, y1 - ny), color: waveColor))
        }
    }

    // MARK: - Colour Helpers (static for testability)

    /// Maps a frequency position (0=low, 1=high) to a colour along a five-stop
    /// gradient: blue → cyan → green → yellow → red. Provides good perceptual
    /// contrast across the spectrum.
    static func gradientColor(at t: Float) -> SIMD4<Float> {
        if t < 0.25 {
            let s = t / 0.25
            return SIMD4(0, s, 1, 1)           // blue -> cyan
        } else if t < 0.5 {
            let s = (t - 0.25) / 0.25
            return SIMD4(0, 1, 1 - s, 1)       // cyan -> green
        } else if t < 0.75 {
            let s = (t - 0.5) / 0.25
            return SIMD4(s, 1, 0, 1)            // green -> yellow
        } else {
            let s = (t - 0.75) / 0.25
            return SIMD4(1, 1 - s, 0, 1)        // yellow -> red
        }
    }

    /// Maps intensity (0=silence, 1=peak) to a heatmap colour for spectrogram mode.
    /// Starts from black (making quiet regions visually distinct from the background),
    /// through dark blue → cyan → yellow → red.
    static func heatmapColor(_ value: Float) -> SIMD4<Float> {
        let v = max(0, min(1, value))
        if v < 0.25 {
            let s = v / 0.25
            return SIMD4(0, 0, s * 0.8, 1)                     // black -> dark blue
        } else if v < 0.5 {
            let s = (v - 0.25) / 0.25
            return SIMD4(0, s, 0.8 + s * 0.2, 1)               // dark blue -> cyan
        } else if v < 0.75 {
            let s = (v - 0.5) / 0.25
            return SIMD4(s, 1, 1 - s, 1)                        // cyan -> yellow
        } else {
            let s = (v - 0.75) / 0.25
            return SIMD4(1, 1 - s * 0.7, 0, 1)                  // yellow -> red
        }
    }

    /// Adds an axis-aligned quad (2 triangles, 6 vertices) with uniform colour.
    private func addQuad(to vertices: inout [SpectrumVertex],
                          x0: Float, y0: Float, x1: Float, y1: Float,
                          color: SIMD4<Float>) {
        vertices.append(SpectrumVertex(position: SIMD2(x0, y0), color: color))
        vertices.append(SpectrumVertex(position: SIMD2(x1, y0), color: color))
        vertices.append(SpectrumVertex(position: SIMD2(x0, y1), color: color))

        vertices.append(SpectrumVertex(position: SIMD2(x0, y1), color: color))
        vertices.append(SpectrumVertex(position: SIMD2(x1, y0), color: color))
        vertices.append(SpectrumVertex(position: SIMD2(x1, y1), color: color))
    }

    /// Adds an axis-aligned quad with a vertical colour gradient (bottom → top).
    private func addGradientQuad(to vertices: inout [SpectrumVertex],
                                  x0: Float, y0: Float, x1: Float, y1: Float,
                                  bottomColor: SIMD4<Float>, topColor: SIMD4<Float>) {
        vertices.append(SpectrumVertex(position: SIMD2(x0, y0), color: bottomColor))
        vertices.append(SpectrumVertex(position: SIMD2(x1, y0), color: bottomColor))
        vertices.append(SpectrumVertex(position: SIMD2(x0, y1), color: topColor))

        vertices.append(SpectrumVertex(position: SIMD2(x0, y1), color: topColor))
        vertices.append(SpectrumVertex(position: SIMD2(x1, y0), color: bottomColor))
        vertices.append(SpectrumVertex(position: SIMD2(x1, y1), color: topColor))
    }

    // MARK: - 3D Surface Rendering

    private func drawSurface(in view: MTKView, withRidgelines: Bool) {
        let surfaceVertices = buildSurfaceVertices(includeRidgelines: withRidgelines)
        guard !surfaceVertices.isEmpty else { return }

        let dataSize = surfaceVertices.count * MemoryLayout<SurfaceVertex>.stride
        guard dataSize <= surfaceVertexBuffer.length else { return }

        surfaceVertices.withUnsafeBytes { ptr in
            surfaceVertexBuffer.contents().copyMemory(from: ptr.baseAddress!, byteCount: ptr.count)
        }

        // Build uniforms
        let lightDir = simd_normalize(SIMD3<Float>(-0.5, 1.0, 0.3))
        var uniforms = SurfaceUniforms(
            mvpMatrix: buildMVPMatrix(),
            lightDirectionAndAmbient: SIMD4<Float>(lightDir.x, lightDir.y, lightDir.z, 0.5)
        )
        uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<SurfaceUniforms>.stride)

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(surfacePipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)  // allow viewing from any angle
        encoder.setVertexBuffer(surfaceVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: surfaceVertices.count)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func buildSurfaceVertices(includeRidgelines: Bool = false) -> [SurfaceVertex] {
        let rows = surfaceDepth
        let bands = bandCount
        var vertices: [SurfaceVertex] = []
        vertices.reserveCapacity(rows * bands * 6)

        // Scale peaks taller in full-view (tall aspect) to fill the vertical space.
        // Compact (aspect ~0.8) = 0.6, full (aspect ~0.45) = 1.2
        let yScale: Float = 0.6 + (1.0 - max(0, min(1, (aspectRatio - 0.45) / (0.80 - 0.45)))) * 0.6

        for row in 0..<(rows - 1) {
            let bufIdx0 = (surfaceWriteIndex + row) % rows
            let bufIdx1 = (surfaceWriteIndex + row + 1) % rows
            let data0 = surfaceBuffer[bufIdx0]
            let data1 = surfaceBuffer[bufIdx1]

            // Z: oldest at -1 (back), newest at +1 (front)
            let rowFrac0 = Float(row) / Float(rows - 1)
            let rowFrac1 = Float(row + 1) / Float(rows - 1)
            let z0: Float = -1.0 + 2.0 * rowFrac0
            let z1: Float = -1.0 + 2.0 * rowFrac1

            for band in 0..<(bands - 1) {
                let t0 = Float(band) / Float(bands - 1)
                let t1 = Float(band + 1) / Float(bands - 1)

                let x0: Float = -1.0 + 2.0 * t0
                let x1: Float = -1.0 + 2.0 * t1

                let y00 = data0[band] * yScale
                let y01 = data0[band + 1] * yScale
                let y10 = data1[band] * yScale
                let y11 = data1[band + 1] * yScale

                let p00 = SIMD3<Float>(x0, y00, z0)
                let p01 = SIMD3<Float>(x1, y01, z0)
                let p10 = SIMD3<Float>(x0, y10, z1)
                let p11 = SIMD3<Float>(x1, y11, z1)

                // Face normal
                let edge1 = p01 - p00
                let edge2 = p10 - p00
                var normal = simd_cross(edge1, edge2)
                let len = simd_length(normal)
                if len > 0 { normal /= len } else { normal = SIMD3<Float>(0, 1, 0) }

                // Colour from frequency gradient (full opacity — lighting provides depth)
                let c0 = Self.gradientColor(at: t0)
                let c1 = Self.gradientColor(at: t1)
                let c00 = c0
                let c01 = c1
                let c10 = c0
                let c11 = c1

                // Triangle 1
                vertices.append(SurfaceVertex(position: p00, normal: normal, color: c00))
                vertices.append(SurfaceVertex(position: p01, normal: normal, color: c01))
                vertices.append(SurfaceVertex(position: p10, normal: normal, color: c10))
                // Triangle 2
                vertices.append(SurfaceVertex(position: p01, normal: normal, color: c01))
                vertices.append(SurfaceVertex(position: p11, normal: normal, color: c11))
                vertices.append(SurfaceVertex(position: p10, normal: normal, color: c10))
            }
        }

        // Ridgeline outlines (surfaceLines mode only)
        guard includeRidgelines else { return vertices }
        // Bright lines tracing the frequency curve at each time slice.
        // Same technique as curve mode's outline: thin quads along the top edge with boosted colour.
        let lineThick: Float = 0.008
        let upNormal = SIMD3<Float>(0, 1, 0)
        for row in 0..<rows {
            let bufIdx = (surfaceWriteIndex + row) % rows
            let data = surfaceBuffer[bufIdx]
            let rowFrac = Float(row) / Float(rows - 1)
            let z: Float = -1.0 + 2.0 * rowFrac

            for band in 0..<(bands - 1) {
                let t0 = Float(band) / Float(bands - 1)
                let t1 = Float(band + 1) / Float(bands - 1)
                let x0: Float = -1.0 + 2.0 * t0
                let x1: Float = -1.0 + 2.0 * t1
                let y0 = data[band] * yScale + 0.002      // slight offset above surface
                let y1 = data[band + 1] * yScale + 0.002

                // Bright colour (1.3x boost)
                let bc0 = Self.gradientColor(at: t0) * SIMD4(1.3, 1.3, 1.3, 1.0)
                let bc1 = Self.gradientColor(at: t1) * SIMD4(1.3, 1.3, 1.3, 1.0)

                // Thin quad perpendicular to the view (vertical thickness)
                let p0bot = SIMD3<Float>(x0, y0 - lineThick, z)
                let p0top = SIMD3<Float>(x0, y0 + lineThick, z)
                let p1bot = SIMD3<Float>(x1, y1 - lineThick, z)
                let p1top = SIMD3<Float>(x1, y1 + lineThick, z)

                vertices.append(SurfaceVertex(position: p0bot, normal: upNormal, color: bc0))
                vertices.append(SurfaceVertex(position: p1bot, normal: upNormal, color: bc1))
                vertices.append(SurfaceVertex(position: p0top, normal: upNormal, color: bc0))

                vertices.append(SurfaceVertex(position: p0top, normal: upNormal, color: bc0))
                vertices.append(SurfaceVertex(position: p1bot, normal: upNormal, color: bc1))
                vertices.append(SurfaceVertex(position: p1top, normal: upNormal, color: bc1))
            }
        }

        return vertices
    }

    // MARK: - Camera / Matrix Helpers

    private func buildMVPMatrix() -> simd_float4x4 {
        // Smoothly interpolate camera between normal and compact based on aspect ratio.
        // Below 0.55 = fully normal, above 0.75 = fully compact, between = blend.
        let t = max(0, min(1, (aspectRatio - 0.55) / (0.75 - 0.55)))
        let azimuth = cameraAzimuthNormal + t * (cameraAzimuthCompact - cameraAzimuthNormal)
        let elevation = cameraElevationNormal + t * (cameraElevationCompact - cameraElevationNormal)
        let distance = cameraDistanceNormal + t * (cameraDistanceCompact - cameraDistanceNormal)

        let azRad = azimuth * .pi / 180.0
        let elRad = elevation * .pi / 180.0

        let camX = distance * cos(elRad) * sin(azRad)
        let camY = distance * sin(elRad)
        let camZ = distance * cos(elRad) * cos(azRad)

        let eye = SIMD3<Float>(camX, camY, camZ)
        let target = SIMD3<Float>(0, 0.15, 0)
        let up = SIMD3<Float>(0, 1, 0)

        let view = lookAtMatrix(eye: eye, target: target, up: up)
        let proj = perspectiveMatrix(fovY: 50.0 * .pi / 180.0,  // slightly wider to avoid clipping
                                      aspect: aspectRatio,
                                      near: 0.1, far: 100.0)
        return proj * view
    }

    private func lookAtMatrix(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)

        var m = matrix_identity_float4x4
        m[0][0] = s.x; m[1][0] = s.y; m[2][0] = s.z
        m[0][1] = u.x; m[1][1] = u.y; m[2][1] = u.z
        m[0][2] = -f.x; m[1][2] = -f.y; m[2][2] = -f.z
        m[3][0] = -simd_dot(s, eye)
        m[3][1] = -simd_dot(u, eye)
        m[3][2] = simd_dot(f, eye)
        return m
    }

    private func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1.0 / tan(fovY / 2.0)
        let x = y / aspect
        let z = far / (near - far)

        var m = simd_float4x4(0)
        m[0][0] = x
        m[1][1] = y
        m[2][2] = z
        m[2][3] = -1.0
        m[3][2] = z * near
        return m
    }
}
