import SwiftUI

struct ContentView: View {
    @StateObject private var audioEngine = AudioEngine()
    @State private var mode: VisualizationMode = Self.initialMode()
    @State private var fps: Int = 0
    private let metalCoordinator = SpectrumMetalView.Coordinator()
    private let fpsTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private static func initialMode() -> VisualizationMode {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-mode"), idx + 1 < args.count {
            let value = args[idx + 1].lowercased()
            switch value {
            case "bars": return .bars
            case "curve": return .curve
            case "circular": return .circular
            case "spectrogram": return .spectrogram
            default: break
            }
        }
        return .bars
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mode picker
            Picker("Mode", selection: $mode) {
                ForEach(VisualizationMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if audioEngine.permissionDenied {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Microphone Access Required")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.7))
                    Text("Enable in Settings > Privacy & Security > Microphone")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                // Metal view with label overlays
                ZStack {
                    SpectrumMetalView(audioEngine: audioEngine, mode: mode, coordinator: metalCoordinator)

                    GeometryReader { geometry in
                        labelsOverlay(in: geometry)
                    }
                }
            }
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.08))
        .preferredColorScheme(.dark)
        .onAppear {
            audioEngine.start()
        }
        .onDisappear {
            audioEngine.stop()
        }
        .onReceive(fpsTimer) { _ in
            fps = metalCoordinator.renderer?.currentFPS ?? 0
        }
    }

    @ViewBuilder
    private func labelsOverlay(in geometry: GeometryProxy) -> some View {
        let width = geometry.size.width
        let height = geometry.size.height

        // dB labels (bars and curve modes) — dynamic from auto-leveling
        if mode == .bars || mode == .curve {
            let floor = audioEngine.dbFloor
            let ceiling = audioEngine.dbCeiling
            let range = ceiling - floor
            let steps: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
            ForEach(0..<steps.count, id: \.self) { i in
                let fraction = steps[i]
                let db = floor + fraction * range
                let label = String(format: "%.0f", db)
                let yNDC = SpectrumLayout.spectrumBottom + fraction * (SpectrumLayout.spectrumTop - SpectrumLayout.spectrumBottom)
                let yPos = SpectrumLayout.ndcToScreenY(yNDC, height: height)

                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .position(x: 16, y: yPos)
            }
        }

        // Frequency labels (not for circular mode)
        if mode != .circular {
            let freqLabels: [(String, Float)] = [
                ("20", 20), ("50", 50), ("100", 100), ("200", 200), ("500", 500),
                ("1k", 1000), ("2k", 2000), ("5k", 5000), ("10k", 10000), ("20k", 20000)
            ]
            let logMin = log10(Float(20))
            let logMax = log10(Float(20000))

            ForEach(0..<freqLabels.count, id: \.self) { i in
                let (label, freq) = freqLabels[i]
                let fraction = (log10(freq) - logMin) / (logMax - logMin)
                let xNDC = SpectrumLayout.spectrumLeft + fraction * (SpectrumLayout.spectrumRight - SpectrumLayout.spectrumLeft)
                let xPos = SpectrumLayout.ndcToScreenX(xNDC, width: width)
                let yPos = SpectrumLayout.ndcToScreenY(SpectrumLayout.spectrumBottom - 0.06, height: height)

                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .position(x: xPos, y: yPos)
            }
        }

        // Waveform label
        let waveformLabelY = SpectrumLayout.ndcToScreenY(SpectrumLayout.waveformTop + 0.06, height: height)
        Text("WAVEFORM")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.25))
            .position(x: width / 2, y: waveformLabelY)

        // FPS counter (top-right)
        Text("\(fps) fps")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.3))
            .position(x: width - 30, y: 10)
    }
}
