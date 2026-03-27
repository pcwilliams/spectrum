import SwiftUI
import MediaPlayer

/// Root view coordinating the audio engine, music player, Metal renderer,
/// and all UI controls. Handles source switching, mode selection, music
/// transport, and overlays (dB labels, frequency labels, FPS counter).
///
/// The view owns both `AudioEngine` and `MusicPlayer` as `@StateObject`s
/// and wires their callbacks together (e.g. track finished → stop player).
/// A shared `SpectrumMetalView.Coordinator` allows the FPS timer to read
/// the renderer's frame rate without triggering SwiftUI re-renders.
struct ContentView: View {
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var musicPlayer = MusicPlayer()
    @State private var mode: VisualizationMode = Self.initialMode()
    @State private var audioSource: AudioSource = Self.initialSource()
    @State private var showMusicBrowser = false
    @State private var fps: Int = 0
    /// Shared coordinator — the Metal renderer writes FPS here, the timer reads it.
    private let metalCoordinator = SpectrumMetalView.Coordinator()
    /// Polls the renderer's FPS every 0.5s. Using a timer avoids @Published on
    /// a 60fps property, which would cause ~60 SwiftUI re-renders per second.
    private let fpsTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // MARK: - Launch Argument Parsing (for automated simulator testing)

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

    private static func initialSource() -> AudioSource {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-source"), idx + 1 < args.count {
            let value = args[idx + 1].lowercased()
            if value == "music" { return .music }
        }
        return .mic
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: source toggle + mode picker
            HStack(spacing: 12) {
                // Source toggle (Mic / Music)
                HStack(spacing: 0) {
                    sourceButton(.mic, icon: "mic.fill")
                    sourceButton(.music, icon: "music.note")
                }
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)

                // Mode picker
                Picker("Mode", selection: $mode) {
                    ForEach(VisualizationMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if audioEngine.permissionDenied && audioSource == .mic {
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

            // Bottom area: always show something in music mode
            if audioSource == .music {
                if musicPlayer.currentTrack != nil {
                    TransportBarView(musicPlayer: musicPlayer, onBrowse: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showMusicBrowser.toggle()
                        }
                    }, onStop: {
                        stopMusicPlayback()
                    })
                } else if !showMusicBrowser {
                    // No track and browser closed — show a browse bar so there's always
                    // something to grab at the bottom in music mode
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showMusicBrowser = true
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 36, height: 4)
                                .padding(.top, 6)
                            HStack {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 14))
                                Text("Browse Music Library")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.bottom, 10)
                        }
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundColor(.white.opacity(0.1)),
                            alignment: .top
                        )
                    }
                }

                if showMusicBrowser {
                    MusicBrowserView(musicPlayer: musicPlayer, onTrackSelected: { track in
                        playTrack(track)
                    }, onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showMusicBrowser = false
                        }
                    })
                    .frame(maxHeight: 300)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.08))
        .preferredColorScheme(.dark)
        .alert("Audio Hardware Issue", isPresented: $audioEngine.audioHardwareBroken) {
            Button("OK") { }
        } message: {
            Text("The audio hardware is reporting an invalid state (0 Hz sample rate or 0 input channels). Please restart your iPhone to reset the audio subsystem.")
        }
        .onAppear {
            audioEngine.onTrackFinished = { [weak musicPlayer] in
                musicPlayer?.stop()
            }
            audioEngine.onPlaybackError = { [weak musicPlayer] _ in
                musicPlayer?.stop()
            }
            audioEngine.start()

            // Handle launch arguments for automated testing
            let args = ProcessInfo.processInfo.arguments
            if let idx = args.firstIndex(of: "-gain"), idx + 1 < args.count,
               let db = Float(args[idx + 1]) {
                audioEngine.staticGainDB = db
                print("🎵 TEST: Static gain boost = \(db) dB")
            }
            if let idx = args.firstIndex(of: "-testfile"), idx + 1 < args.count {
                let filename = args[idx + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    audioEngine.switchSource(to: .music)
                    audioSource = .music
                    if let url = Bundle.main.url(forResource: filename, withExtension: nil)
                        ?? Bundle.main.url(forResource: (filename as NSString).deletingPathExtension,
                                         withExtension: (filename as NSString).pathExtension) {
                        print("🎵 TEST: Playing \(url.lastPathComponent)")
                        audioEngine.playFile(url: url)
                    } else {
                        print("🎵 TEST: File not found: \(filename)")
                    }
                }
            } else if audioSource == .music {
                DispatchQueue.main.async {
                    audioEngine.switchSource(to: .music)
                    musicPlayer.requestAccessAndLoad()
                    showMusicBrowser = true
                }
            }
        }
        .onDisappear {
            audioEngine.stop()
        }
        .onReceive(fpsTimer) { _ in
            fps = metalCoordinator.renderer?.currentFPS ?? 0
        }
        .onChange(of: audioSource) { _, newSource in
            handleSourceChange(to: newSource)
        }
        .onChange(of: musicPlayer.isPlaying) { oldValue, isPlaying in
            guard musicPlayer.currentTrack != nil else { return }
            // Only handle pause/resume — not initial play (playTrack calls playFile directly)
            if !isPlaying && oldValue {
                audioEngine.pausePlayback()
            } else if isPlaying && !oldValue && audioEngine.currentAudioFile != nil {
                audioEngine.resumePlayback()
            }
        }
    }

    // MARK: - Source Toggle Button

    private func sourceButton(_ source: AudioSource, icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                audioSource = source
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(audioSource == source ? .white : .white.opacity(0.35))
                .frame(width: 38, height: 30)
                .background(audioSource == source ? Color.white.opacity(0.18) : Color.clear)
                .cornerRadius(6)
        }
    }

    // MARK: - Source Switching

    /// Handles the full source switch: stops music if switching to mic,
    /// requests library access if switching to music.
    private func handleSourceChange(to source: AudioSource) {
        print("🎵 USER ACTION: source toggle → \(source)")
        switch source {
        case .mic:
            stopMusicPlayback()
            showMusicBrowser = false
            audioEngine.switchSource(to: .mic)
        case .music:
            audioEngine.switchSource(to: .music)
            musicPlayer.requestAccessAndLoad()
            showMusicBrowser = true
        }
    }

    // MARK: - Music Playback

    /// Plays a track: tells MusicPlayer to update state, then tells AudioEngine
    /// to open the file. The two are deliberately separate objects with no direct
    /// coupling — ContentView coordinates them.
    private func playTrack(_ track: MPMediaItem) {
        print("🎵 USER ACTION: play track — \(track.artist ?? "?") — \(track.title ?? "?")")
        guard let url = track.assetURL else {
            print("🎵 playTrack: no assetURL!")
            return
        }
        musicPlayer.selectTrack(track)
        audioEngine.playFile(url: url)
    }

    private func stopMusicPlayback() {
        print("🎵 USER ACTION: stop music playback")
        audioEngine.stopPlayback()
        musicPlayer.stop()
    }

    // MARK: - Label Overlays
    //
    // SwiftUI overlays on top of the Metal view. These are positioned using
    // the same NDC coordinate system as the renderer, converted to screen
    // coordinates via SpectrumLayout helpers. The dB labels update dynamically
    // as the auto-leveling range changes.

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
