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
    @AppStorage("visualizationMode") private var mode: VisualizationMode = .bars
    @AppStorage("audioSource") private var audioSource: AudioSource = .mic
    @AppStorage("tuningEnabled") private var tuningEnabled: Bool = false
    @AppStorage("bpmEnabled") private var bpmEnabled: Bool = false
    @State private var showMusicBrowser = false
    @State private var fps: Int = 0
    @State private var tooltipText: String? = nil
    // Tuning/BPM display state — sampled by the FPS timer so SwiftUI
    // sees @State changes and reliably re-renders the overlays.
    @State private var displayedNote: String = ""
    @State private var displayedCents: Float = 0
    @State private var displayedBPM: Int? = nil
    @State private var displayedBeatFlash: Bool = false
    /// Shared coordinator — the Metal renderer writes FPS here, the timer reads it.
    private let metalCoordinator = SpectrumMetalView.Coordinator()
    /// Polls the renderer's FPS every 0.5s. Using a timer avoids @Published on
    /// a 60fps property, which would cause ~60 SwiftUI re-renders per second.
    private let fpsTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // MARK: - Launch Argument Parsing (for automated simulator testing)

    private static func launchArgMode() -> VisualizationMode? {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-mode"), idx + 1 < args.count {
            let value = args[idx + 1].lowercased()
            switch value {
            case "bars": return .bars
            case "curve": return .curve
            case "surface": return .surface
            case "surface+", "surfacelines": return .surfaceLines
            case "circular": return .circular
            case "spectrogram": return .spectrogram
            default: break
            }
        }
        return nil
    }

    private static func launchArgSource() -> AudioSource? {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-source"), idx + 1 < args.count {
            let value = args[idx + 1].lowercased()
            if value == "music" { return .music }
            if value == "mic" { return .mic }
        }
        return nil
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Source toggle (Mic / Music)
                HStack(spacing: 0) {
                    sourceButton(.mic, icon: "mic.fill", label: "Microphone")
                    sourceButton(.music, icon: "music.note", label: "Music")
                }
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)

                // Feature toggles
                featureToggle(isOn: $tuningEnabled, icon: "tuningfork", label: "Tuner")
                featureToggle(isOn: $bpmEnabled, icon: "metronome", label: "BPM")

                // Mode picker
                HStack(spacing: 0) {
                    modeButton(.bars, icon: "chart.bar.fill", label: "Bars")
                    modeButton(.curve, icon: "waveform.path", label: "Curve")
                    modeButton(.surface, icon: "cube.fill", label: "Surface")
                    modeButton(.surfaceLines, icon: "cube.transparent", label: "Surface+")
                    modeButton(.circular, icon: "circle.circle", label: "Circular")
                    modeButton(.spectrogram, icon: "square.grid.3x3.fill", label: "Spectrogram")
                }
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Tooltip
            if let text = tooltipText {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    private func showTooltip(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { tooltipText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.2)) { tooltipText = nil }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

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

            // Bottom area: unified music bar + collapsible browser
            if audioSource == .music {
                // Single header line — tap to toggle browser, shows title or now-playing
                musicHeaderBar

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
            // Launch argument overrides (for simulator testing)
            if let overrideMode = Self.launchArgMode() { mode = overrideMode }
            if let overrideSource = Self.launchArgSource() { audioSource = overrideSource }

            // Launch argument overrides for feature toggles
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-tuning") { tuningEnabled = true }
            if args.contains("-bpm") { bpmEnabled = true }

            // Wire feature toggles to audio engine
            audioEngine.tuningEnabled = tuningEnabled
            audioEngine.bpmEnabled = bpmEnabled

            audioEngine.onTrackFinished = { [weak musicPlayer] in
                musicPlayer?.stop()
            }
            audioEngine.onPlaybackError = { [weak musicPlayer] _ in
                musicPlayer?.stop()
            }
            audioEngine.start()

            // Handle launch arguments for automated testing
            if args.contains("-pitchlog") { AudioEngine.pitchLoggingEnabled = true }
            if args.contains("-bpmlog") { AudioEngine.bpmLoggingEnabled = true }
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
            } else if let idx = args.firstIndex(of: "-autoplay"), idx + 1 < args.count {
                // Auto-play a track from the music library by title substring
                let searchTitle = args[idx + 1].lowercased()
                audioSource = .music
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    audioEngine.switchSource(to: .music)
                    musicPlayer.requestAccessAndLoad()
                    // Poll until library is loaded, then find and play
                    func tryAutoplay(attempts: Int = 0) {
                        if musicPlayer.libraryLoaded && !musicPlayer.tracks.isEmpty {
                            let allTracks = musicPlayer.tracks.flatMap { $0.songs }
                            if let track = allTracks.first(where: {
                                ($0.title ?? "").lowercased().contains(searchTitle)
                            }) {
                                print("🎵 AUTOPLAY: Found '\(track.title ?? "?")' by \(track.artist ?? "?")")
                                // Start from 1/3 into the track (skip intro, land in the beat)
                                if let url = track.assetURL {
                                    audioEngine.stopPlayback()
                                    musicPlayer.selectTrack(track)
                                    let startSeconds = track.playbackDuration / 3.0
                                    let startFrame = AVAudioFramePosition(startSeconds * 44100)
                                    audioEngine.playFile(url: url, startFrame: startFrame)
                                } else {
                                    playTrack(track)
                                }
                            } else {
                                print("🎵 AUTOPLAY: No track matching '\(searchTitle)' found in \(allTracks.count) tracks")
                            }
                        } else if attempts < 20 {  // retry up to 10 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                tryAutoplay(attempts: attempts + 1)
                            }
                        } else {
                            print("🎵 AUTOPLAY: Library failed to load after 10s")
                        }
                    }
                    tryAutoplay()
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
            displayedNote = audioEngine.detectedNote
            displayedCents = audioEngine.detectedCents
            displayedBPM = audioEngine.detectedBPM
            displayedBeatFlash = audioEngine.beatFlash
        }
        .onChange(of: audioSource) { _, newSource in
            handleSourceChange(to: newSource)
        }
        .onChange(of: tuningEnabled) { _, newValue in
            audioEngine.tuningEnabled = newValue
        }
        .onChange(of: bpmEnabled) { _, newValue in
            audioEngine.bpmEnabled = newValue
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

    private func sourceButton(_ source: AudioSource, icon: String, label: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(audioSource == source ? .white : .white.opacity(0.35))
            .frame(width: 38, height: 30)
            .background(audioSource == source ? Color.white.opacity(0.18) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { audioSource = source }
            }
            .onLongPressGesture(minimumDuration: 0.4) { showTooltip(label) }
            .accessibilityLabel(label)
    }

    // MARK: - Mode Button

    private func modeButton(_ m: VisualizationMode, icon: String, label: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(mode == m ? .white : .white.opacity(0.35))
            .frame(width: 38, height: 30)
            .background(mode == m ? Color.white.opacity(0.18) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { mode = m }
            }
            .onLongPressGesture(minimumDuration: 0.4) { showTooltip(label) }
            .accessibilityLabel(label)
    }

    // MARK: - Feature Toggle Button

    private func featureToggle(isOn: Binding<Bool>, icon: String, label: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isOn.wrappedValue ? .cyan : .white.opacity(0.35))
            .frame(width: 30, height: 30)
            .background(isOn.wrappedValue ? Color.cyan.opacity(0.18) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { isOn.wrappedValue.toggle() }
            }
            .onLongPressGesture(minimumDuration: 0.4) { showTooltip(label) }
            .accessibilityLabel(label)
    }

    // MARK: - Unified Music Header Bar

    private var musicHeaderBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.white.opacity(0.1))

            HStack(spacing: 12) {
                // Title / now-playing
                HStack(spacing: 6) {
                    Image(systemName: showMusicBrowser ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                    if musicPlayer.currentTrack != nil {
                        Text(musicPlayer.trackDisplayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    } else {
                        Text("Music Library")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

                Spacer()

                // Transport controls (only when a track is loaded)
                if musicPlayer.currentTrack != nil {
                    Button {
                        musicPlayer.isPlaying.toggle()
                    } label: {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                    }
                    Button {
                        stopMusicPlayback()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 32, height: 32)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
                showMusicBrowser.toggle()
            }
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
        // stopPlayback increments playbackGeneration, which invalidates
        // the old track's completion handler so it won't clear currentTrack
        audioEngine.stopPlayback()
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

        // dB labels (bars and curve modes only) — dynamic from auto-leveling
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

        // Frequency labels (2D modes only, not circular)
        if mode != .circular && mode != .surface && mode != .surfaceLines {
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

        // Waveform label (2D modes only)
        if mode != .surface && mode != .surfaceLines {
            let waveformLabelY = SpectrumLayout.ndcToScreenY(SpectrumLayout.waveformTop + 0.06, height: height)
            Text("WAVEFORM")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
                .position(x: width / 2, y: waveformLabelY)
        }

        // Tuning overlay (right side, bars/curve/surface modes)
        if tuningEnabled && (mode == .bars || mode == .curve || mode == .surface || mode == .surfaceLines) && !displayedNote.isEmpty {
            let tuningX = SpectrumLayout.ndcToScreenX(SpectrumLayout.spectrumRight - 0.14, width: width)
            let tuningY = SpectrumLayout.ndcToScreenY(SpectrumLayout.spectrumTop - 0.18, height: height)
            let tuningColor: Color = abs(displayedCents) < 10 ? .green : (abs(displayedCents) < 25 ? .yellow : .red)

            VStack(spacing: 0) {
                Text(displayedNote)
                    .font(.system(size: 36, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(tuningColor)
                Text(String(format: "%+.0f", displayedCents))
                    .font(.system(size: 20, weight: .thin, design: .monospaced))
                    .foregroundColor(tuningColor.opacity(0.7))
            }
            .position(x: tuningX, y: tuningY)
        }

        // BPM overlay (right side, below tuning, bars/curve/surface modes)
        if bpmEnabled && (mode == .bars || mode == .curve || mode == .surface || mode == .surfaceLines) {
            let bpmYOffset: Float = (tuningEnabled && !displayedNote.isEmpty) ? 0.46 : 0.18
            let bpmX = SpectrumLayout.ndcToScreenX(SpectrumLayout.spectrumRight - 0.14, width: width)
            let bpmY = SpectrumLayout.ndcToScreenY(SpectrumLayout.spectrumTop - bpmYOffset, height: height)

            if let bpm = displayedBPM {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(displayedBeatFlash ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 6, height: 6)
                        Text("\(bpm)")
                            .font(.system(size: 36, weight: .ultraLight, design: .monospaced))
                            .foregroundColor(.white.opacity(displayedBeatFlash ? 1.0 : 0.6))
                    }
                    Text("BPM")
                        .font(.system(size: 12, weight: .thin, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                }
                .position(x: bpmX, y: bpmY)
            }
        }

        // FPS counter (top-right)
        Text("\(fps) fps")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.3))
            .position(x: width - 30, y: 10)
    }
}
