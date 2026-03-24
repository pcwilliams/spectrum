import Metal
import MetalKit
import simd

struct SpectrumVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

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

    // 60fps display smoothing (decoupled from audio rate)
    private var displaySpectrum: [Float]
    private var displayPeaks: [Float]
    private let smoothingLerp: Float = 0.35      // rise speed (per frame at 60fps)
    private let decayLerp: Float = 0.12           // fall speed — slower for smooth decay
    private let peakDecayRate: Float = 0.006      // peak dots fall gently

    // Spectrogram history (circular buffer)
    private var spectrogramBuffer: [[Float]]
    private var spectrogramWriteIndex = 0
    private let spectrogramDepth = 128
    private var spectrogramFrameCounter = 0

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

        guard let ps = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipelineState = ps

        guard let vb = device.makeBuffer(length: maxVertexCount * MemoryLayout<SpectrumVertex>.stride,
                                          options: .storageModeShared) else { return nil }
        vertexBuffer = vb

        spectrogramBuffer = Array(repeating: [Float](repeating: 0, count: SpectrumLayout.bandCount),
                                   count: spectrogramDepth)

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
        }
        vertices.reserveCapacity(estimatedCount)

        // Grid lines (bars and curve modes)
        if mode == .bars || mode == .curve {
            buildGridVertices(into: &vertices)
        }

        // Spectrum visualization (using 60fps-smoothed display data)
        switch mode {
        case .bars:
            buildBarVertices(into: &vertices, spectrum: displaySpectrum, peaks: displayPeaks)
        case .curve:
            buildCurveVertices(into: &vertices, spectrum: displaySpectrum, peaks: displayPeaks)
        case .circular:
            buildCircularVertices(into: &vertices, spectrum: displaySpectrum, peaks: displayPeaks)
        case .spectrogram:
            buildSpectrogramVertices(into: &vertices)
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

    private func buildBarVertices(into vertices: inout [SpectrumVertex], spectrum: [Float], peaks: [Float]) {
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
            let color = Self.gradientColor(at: t)
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

    private func buildCurveVertices(into vertices: inout [SpectrumVertex], spectrum: [Float], peaks: [Float]) {
        let specHeight = specTop - specBottom

        // Filled area under curve
        for i in 0..<(bandCount - 1) {
            let t0 = Float(i) / Float(bandCount - 1)
            let t1 = Float(i + 1) / Float(bandCount - 1)
            let x0 = specLeft + t0 * (specRight - specLeft)
            let x1 = specLeft + t1 * (specRight - specLeft)
            let y0Top = specBottom + spectrum[i] * specHeight
            let y1Top = specBottom + spectrum[i + 1] * specHeight

            let color0 = Self.gradientColor(at: t0)
            let color1 = Self.gradientColor(at: t1)
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

    // MARK: - Helpers

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
}
