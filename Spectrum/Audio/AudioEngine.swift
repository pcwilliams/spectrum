import AVFoundation
import Accelerate
import QuartzCore

// MARK: - Debug Logging
//
// Persistent logging system that writes to both the console (with emoji prefix)
// and a log file at Documents/spectrum.log. Invaluable for diagnosing audio
// engine issues on-device where Xcode isn't connected.

private let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

private var logFileHandle: FileHandle?

private func alog(_ msg: String) {
    guard AudioEngine.loggingEnabled else { return }
    let line = "[\(logDateFormatter.string(from: Date()))] \(msg)\n"
    print("🎵 \(msg)")

    if logFileHandle == nil {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let path = docs.appendingPathComponent("spectrum.log")
        try? "".write(to: path, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: path.path, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: path.path)
        logFileHandle?.seekToEndOfFile()
        alog("Log started — file: \(path.path)")
    }
    logFileHandle?.write(line.data(using: .utf8)!)
}

/// Captures audio from the microphone or music files, performs FFT analysis,
/// and publishes normalised spectrum data for the Metal renderer to read.
///
/// ## Architecture
/// A single `AVAudioEngine` instance lives for the entire app lifetime.
/// All nodes (playerNode, musicMixer) are attached and connected BEFORE
/// `engine.start()` — connecting after start permanently breaks playerNode.
/// Source switching swaps taps only; nodes stay connected (idle = silence, zero cost).
///
/// ## Data Flow
/// Audio buffer → Hanning window → vDSP FFT → power spectrum → dB conversion
/// → auto-leveling → logarithmic band mapping → normalised 0–1 values
///
/// ## Threading
/// `processBuffer` runs on the audio thread; results are dispatched to main.
/// MetalRenderer reads `spectrumData`/`waveformData`/`dbFloor`/`dbCeiling`
/// directly on the main thread (no @Published, no SwiftUI re-renders).
class AudioEngine: ObservableObject {
    static var loggingEnabled = true
    /// Enable verbose pitch/BPM detection logging (every frame). Off by default
    /// to reduce log noise — enable via `-pitchlog` launch argument for debugging.
    static var pitchLoggingEnabled = false
    /// Enable verbose BPM detection logging. Off by default — enable via `-bpmlog` launch argument.
    static var bpmLoggingEnabled = false

    // MARK: - Public Data (read directly by MetalRenderer, NOT @Published)
    //
    // These are written on the main thread from processBuffer's dispatch,
    // and read on the main thread by MetalRenderer's draw() via CADisplayLink.
    // No locking needed — both are main-thread-only on iOS.

    /// Normalised spectrum data (0–1) across 128 logarithmic frequency bands.
    /// Updated at ~21fps (audio callback rate). MetalRenderer applies its own
    /// 60fps smoothing and peak tracking on top of this raw data.
    var spectrumData: [Float]

    /// Raw waveform samples (time-domain) for the oscilloscope display.
    var waveformData: [Float]

    /// Current auto-leveled dB range bounds. Used by ContentView's label overlay
    /// to display dynamic dB scale markings that follow the adaptive range.
    var dbFloor: Float = -80
    var dbCeiling: Float = 0

    // MARK: - Published State (drives SwiftUI updates)

    @Published var isRunning = false
    @Published var permissionDenied = false

    /// Set when the audio hardware reports 0 Hz sample rate or 0 input channels.
    /// Triggers a UI alert advising the user to restart their phone.
    @Published var audioHardwareBroken = false

    @Published var audioSource: AudioSource = .mic

    // MARK: - Audio Engine (single instance, never recreated)
    //
    // CRITICAL: Creating a fresh AVAudioEngine() mid-lifecycle causes 0 Hz
    // formats and RPC timeout crashes. One engine for the entire app lifetime.

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let musicMixer = AVAudioMixerNode()
    private let fftSize = SpectrumLayout.fftSize
    private let bandCount = SpectrumLayout.bandCount

    // MARK: - FFT State

    private var fftSetup: FFTSetup?
    /// Pre-computed Hanning window coefficients, applied to each buffer
    /// before FFT to reduce spectral leakage at buffer boundaries.
    private var window: [Float] = []
    private var sampleRate: Float = 44100

    // MARK: - Auto-Level State
    //
    // The display adapts to the current signal level rather than mapping
    // a fixed dB range. This ensures responsive visuals whether you're in
    // a quiet room or at a concert.

    /// Tracks the highest dB value seen recently; rises instantly, decays slowly.
    private var adaptiveCeiling: Float = -40
    /// How fast the ceiling drops when signal decreases (dB per audio frame).
    private let autoLevelDecay: Float = 0.5
    /// Width of the visible dB window (bottom = ceiling - displayRange).
    private let displayRange: Float = 40
    /// Lowest allowed ceiling value — prevents display from going blank in silence.
    private let minCeiling: Float = -60
    /// Highest allowed ceiling value — caps at 0 dB (full scale).
    private let maxCeiling: Float = 0

    // MARK: - Pitch Detection (read by ContentView overlay, NOT @Published)

    var detectedNote: String = ""      // e.g. "A4"
    var detectedCents: Float = 0       // -50 to +50
    var tuningEnabled: Bool = false {  // set by ContentView
        didSet {
            if tuningEnabled != oldValue {
                pitchSmoothingBuffer.removeAll()
                pitchMissCount = 0
                detectedNote = ""
                detectedCents = 0
            }
        }
    }

    // MARK: - BPM Detection (read by ContentView overlay and MetalRenderer)

    var detectedBPM: Int? = nil        // nil = not confident
    var beatFlash: Bool = false        // true briefly after each beat
    var beatFlashCounter: Int = 0      // frames remaining, decremented by MetalRenderer
    var bpmEnabled: Bool = false {     // set by ContentView
        didSet {
            if bpmEnabled != oldValue {
                spectralFluxHistory.removeAll()
                fluxWriteIndex = 0
                fluxSampleCount = 0
                recentLowEnergy = 0
                lastBeatTime = 0
                bpmUpdateCounter = 0
                ossFirstTimestamp = 0
                ossLastTimestamp = 0
                bpmSmoothingBuffer.removeAll()
                onsetPrevMags = nil
                lastLockedBPM = 0
                tempoChangeCount = 0
                detectedBPM = nil
                beatFlash = false
                beatFlashCounter = 0
            }
        }
    }

    // MARK: - Static Gain Boost (for simulator testing)
    //
    // Applied as a dB offset to FFT output, boosting quiet simulator audio
    // to exercise the full visualisation. Set via -gain <dB> launch argument.

    var staticGainDB: Float = 0

    // MARK: - DSP Performance Tracking

    private var dspTimingSum: Double = 0
    private var dspTimingCount: Int = 0
    private var dspTimingMax: Double = 0

    // MARK: - Pitch Detection State

    private var pitchSmoothingBuffer: [Float] = []
    private let pitchSmoothingCount = 3   // median of last 3 detections (fast tracking)
    private var pitchMissCount = 0        // consecutive frames with no pitch detected
    private let pitchMissLimit = 5        // clear display after ~250ms of silence
    private var lastLoggedPitch: String = "" // for change-only logging

    // MARK: - BPM Detection State
    //
    // Uses autocorrelation of the onset strength signal (spectral flux) rather
    // than inter-onset intervals. This handles syncopated rhythms (drum & bass,
    // electronic music) because the overall rhythmic pattern repeats at the beat
    // period even when individual kicks are syncopated (Scheirer 1998 / Ellis 2007).

    private var spectralFluxHistory: [Float] = []
    private let fluxHistorySize = 340     // ~8 seconds at ~43fps (hop=1024 at 44.1kHz)
    private var fluxWriteIndex = 0
    private var fluxSampleCount = 0       // total samples written (for fill tracking)
    private var recentLowEnergy: Float = 0       // smoothed low energy for beat flash threshold
    private var lastBeatTime: Double = 0
    private var bpmUpdateCounter = 0             // only recompute autocorrelation every ~20 frames (~0.5s)
    private var ossFirstTimestamp: Double = 0     // timestamp of first OSS sample (for rate calc)
    private var ossLastTimestamp: Double = 0      // timestamp of most recent OSS sample
    private var bpmSmoothingBuffer: [Int] = []   // recent BPM estimates for temporal smoothing
    private let bpmSmoothingSize = 3             // need consensus over 3 estimates (~1.5s)
    private var lastLockedBPM: Int = 0           // last displayed BPM, for tempo-change detection
    private var tempoChangeCount = 0             // consecutive estimates diverging from locked BPM
    // Onset-rate FFT resources (1024-point, separate from display FFT)
    private var onsetFFTSetup: FFTSetup?
    private let onsetFFTSize = 1024
    private var onsetWindow: [Float] = []
    private var onsetPrevMags: [Float]?          // previous frame magnitudes for spectral flux

    // MARK: - Playback State

    /// The currently playing audio file, if any. Used by ContentView to determine
    /// whether a resume (vs fresh play) is appropriate after pause.
    private(set) var currentAudioFile: AVAudioFile?
    /// Counts audio tap callbacks — logged for the first few and periodically,
    /// useful for confirming the tap is alive after source switches.
    private var tapBufferCount = 0
    /// Called when a track finishes playing (scheduleFile completion).
    var onTrackFinished: (() -> Void)?
    /// Called when a track fails to open (e.g. DRM or corrupt file).
    var onPlaybackError: ((String) -> Void)?
    /// Incremented on each stop/play to invalidate stale completion handlers.
    /// Prevents a stopped track's async completion from clearing the new track.
    private var playbackGeneration = 0

    // MARK: - Init / Deinit

    init() {
        let bandCount = SpectrumLayout.bandCount
        spectrumData = [Float](repeating: 0, count: bandCount)
        waveformData = [Float](repeating: 0, count: SpectrumLayout.waveformSampleCount)

        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Onset-rate FFT (1024-point) for higher-resolution BPM detection
        let onsetLog2n = vDSP_Length(log2(Double(onsetFFTSize)))
        onsetFFTSetup = vDSP_create_fftsetup(onsetLog2n, FFTRadix(kFFTRadix2))
        onsetWindow = [Float](repeating: 0, count: onsetFFTSize)
        vDSP_hann_window(&onsetWindow, vDSP_Length(onsetFFTSize), Int32(vDSP_HANN_NORM))

        alog("AudioEngine.init")
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
        if let setup = onsetFFTSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // MARK: - Lifecycle

    /// Set up the entire audio graph and start the engine.
    ///
    /// CRITICAL SEQUENCE: attach → connect → prepare → start.
    /// All nodes MUST be attached and connected BEFORE `engine.start()`.
    /// Connecting after start permanently breaks playerNode with an uncatchable
    /// ObjC exception ("player started when in a disconnected state").
    /// This was confirmed by AudioKit issue #2527.
    func start() {
        alog("start() called — isRunning=\(isRunning)")
        guard !isRunning else { return }

        // 1. Configure audio session (once, never changed after this)
        do {
            let session = AVAudioSession.sharedInstance()
            #if targetEnvironment(simulator)
            // Simulator has no mic hardware — .playAndRecord fails.
            // Use .playback for music-only testing.
            try session.setCategory(.playback, mode: .default)
            alog("Audio session: .playback (simulator)")
            #else
            // Device: .playAndRecord enables both mic and music output.
            // .defaultToSpeaker routes music to the speaker (not earpiece) when no Bluetooth connected.
            // .allowBluetooth/.allowBluetoothA2DP respect connected Bluetooth headphones for output.
            // AGC quality is identical to .record when using .default mode.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            alog("Audio session: .playAndRecord + .defaultToSpeaker + .allowBluetooth + .allowBluetoothA2DP")
            #endif
            try session.setActive(true)
            alog("  sampleRate=\(session.sampleRate), outputChannels=\(session.outputNumberOfChannels), inputChannels=\(session.inputNumberOfChannels)")

            #if !targetEnvironment(simulator)
            if session.inputNumberOfChannels == 0 {
                alog("WARNING: 0 input channels — audio hardware may need reboot")
                audioHardwareBroken = true
            }
            #endif
        } catch {
            alog("Audio session ERROR: \(error)")
        }

        // 2. Attach all nodes (must happen before connect)
        engine.attach(playerNode)
        engine.attach(musicMixer)

        // 3. Connect ALL nodes BEFORE engine.start()
        //    Idle connected nodes pass silence at zero CPU cost (confirmed by
        //    AudioKit source). NEVER disconnect — it permanently breaks the node.
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        alog("mainMixer format: \(mixerFormat.sampleRate)Hz, \(mixerFormat.channelCount)ch")

        if mixerFormat.sampleRate > 0 {
            engine.connect(playerNode, to: musicMixer, format: mixerFormat)
            engine.connect(musicMixer, to: engine.mainMixerNode, format: mixerFormat)
            alog("Music nodes connected: playerNode → musicMixer → mainMixerNode")
        } else {
            alog("WARNING: mainMixer format is 0 Hz — cannot connect music nodes")
        }
        sampleRate = Float(max(mixerFormat.sampleRate, 44100))

        // 4. Install initial mic tap (device only — simulator has no mic)
        #if !targetEnvironment(simulator)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        alog("inputNode format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
        if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 {
            engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: inputFormat) { [weak self] buffer, _ in
                self?.processBuffer(buffer)
            }
            sampleRate = Float(inputFormat.sampleRate)
            alog("Mic tap installed")
        } else {
            alog("WARNING: invalid mic format — skipping mic tap")
            audioHardwareBroken = true
        }
        #else
        // Simulator: install tap on musicMixer for file playback testing
        musicMixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
        audioSource = .music
        alog("Simulator: musicMixer tap installed, starting in music mode")
        #endif

        // 5. Prepare and start engine
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            alog("Engine started OK — isRunning=true, engine.isRunning=\(engine.isRunning)")
        } catch {
            alog("Engine start ERROR: \(error)")
        }

        // 6. Request mic permission (device only — async, doesn't block start)
        #if !targetEnvironment(simulator)
        audioSource = .mic
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                alog("Mic permission: \(granted ? "GRANTED" : "DENIED")")
                if !granted {
                    self?.permissionDenied = true
                }
            }
        }
        #endif
    }

    /// Tears down all taps and stops the engine. Called from ContentView.onDisappear.
    func stop() {
        alog("stop() called")
        engine.inputNode.removeTap(onBus: 0)
        musicMixer.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        isRunning = false
    }

    // MARK: - Source Switching (swap taps only — never disconnect nodes)
    //
    // installTap/removeTap are safe while the engine is running (Apple-documented).
    // Nodes stay connected at all times — idle connections pass silence at zero cost.

    func switchSource(to source: AudioSource) {
        alog("USER ACTION: switchSource to=\(source) (current=\(audioSource))")
        guard source != audioSource else {
            alog("switchSource: same source, skipping")
            return
        }

        #if targetEnvironment(simulator)
        // Simulator only supports music mode (no mic hardware)
        alog("switchSource: simulator only supports music mode")
        audioSource = .music
        return
        #else
        resetDisplayState()
        tapBufferCount = 0

        switch source {
        case .mic:
            alog("Switching to MIC: removing music tap, stopping player, installing mic tap")
            musicMixer.removeTap(onBus: 0)
            playerNode.stop()
            currentAudioFile = nil
            // Music nodes stay connected — idle = silence, zero cost.

            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            alog("  inputNode format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                alog("  Mic format invalid — cannot install tap")
                audioSource = source
                return
            }
            sampleRate = Float(inputFormat.sampleRate)
            engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: inputFormat) { [weak self] buffer, _ in
                self?.processBuffer(buffer)
            }
            alog("  Mic tap installed")

        case .music:
            alog("Switching to MUSIC: removing mic tap, installing music tap")
            engine.inputNode.removeTap(onBus: 0)
            // Music nodes already connected at startup — just install the tap
            musicMixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { [weak self] buffer, _ in
                self?.processBuffer(buffer)
            }
            alog("  Music tap installed")
        }

        audioSource = source
        alog("Source switch complete: audioSource=\(audioSource), engine.isRunning=\(engine.isRunning)")
        #endif
    }

    // MARK: - Playback

    /// Opens an audio file and begins playback through the music pipeline.
    /// Does NOT reconnect playerNode — the startup connection handles format
    /// conversion automatically. Reconnecting on a running engine would crash.
    func playFile(url: URL, startFrame: AVAudioFramePosition = 0) {
        alog("USER ACTION: playFile url=\(url.lastPathComponent) startFrame=\(startFrame)")
        alog("  engine.isRunning=\(engine.isRunning), playerNode.isPlaying=\(playerNode.isPlaying)")

        guard isRunning, engine.isRunning else {
            alog("playFile FAILED: engine not running")
            return
        }

        playerNode.stop()
        playbackGeneration += 1
        tapBufferCount = 0

        do {
            let file = try AVAudioFile(forReading: url)
            currentAudioFile = file
            let generation = playbackGeneration
            alog("playFile: file opened — format=\(file.processingFormat.sampleRate)Hz, \(file.processingFormat.channelCount)ch, length=\(file.length), gen=\(generation)")

            let actualStart = min(startFrame, file.length - 1)
            if actualStart > 0 {
                let frameCount = AVAudioFrameCount(file.length - actualStart)
                playerNode.scheduleSegment(file, startingFrame: actualStart, frameCount: frameCount, at: nil) { [weak self] in
                    alog("playFile: completion fired (gen=\(generation))")
                    DispatchQueue.main.async {
                        guard let self, self.playbackGeneration == generation else { return }
                        self.onTrackFinished?()
                    }
                }
            } else {
                playerNode.scheduleFile(file, at: nil) { [weak self] in
                    alog("playFile: completion fired (gen=\(generation))")
                    DispatchQueue.main.async {
                        guard let self, self.playbackGeneration == generation else { return }
                        self.onTrackFinished?()
                    }
                }
            }
            playerNode.play()
            alog("playFile: playerNode.play() called — isPlaying=\(playerNode.isPlaying)")

            // Diagnostic: confirm tap is receiving data 1 second after play
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                alog("playFile +1s: tapBufferCount=\(self.tapBufferCount), playerNode.isPlaying=\(self.playerNode.isPlaying)")
            }
        } catch {
            alog("playFile ERROR: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.onPlaybackError?("Cannot play this track.")
                self?.onTrackFinished?()
            }
        }
    }

    func pausePlayback() {
        alog("USER ACTION: pausePlayback")
        guard engine.isRunning else { return }
        playerNode.pause()
        // Clear BPM display — no audio flowing means no beat to show
        detectedBPM = nil
        beatFlash = false
        beatFlashCounter = 0
    }

    func resumePlayback() {
        alog("USER ACTION: resumePlayback")
        guard engine.isRunning, currentAudioFile != nil else {
            alog("resumePlayback: guard failed — engine.isRunning=\(engine.isRunning), hasFile=\(currentAudioFile != nil)")
            return
        }
        playerNode.play()
    }

    func stopPlayback() {
        alog("USER ACTION: stopPlayback")
        playbackGeneration += 1  // invalidate any pending completion handler
        playerNode.stop()
        currentAudioFile = nil
        resetDisplayState()
    }

    /// Clears all display data and resets the auto-leveling state.
    /// Called on source switch and stop to prevent stale visuals.
    private func resetDisplayState() {
        adaptiveCeiling = -40
        let bc = bandCount
        spectrumData = [Float](repeating: 0, count: bc)
        waveformData = [Float](repeating: 0, count: SpectrumLayout.waveformSampleCount)
        // Reset pitch detection
        detectedNote = ""
        detectedCents = 0
        pitchSmoothingBuffer.removeAll()
        pitchMissCount = 0
        // Reset BPM detection
        detectedBPM = nil
        beatFlash = false
        beatFlashCounter = 0
        spectralFluxHistory.removeAll()
        fluxWriteIndex = 0
        recentLowEnergy = 0
        lastBeatTime = 0
        bpmUpdateCounter = 0
        fluxSampleCount = 0
        ossFirstTimestamp = 0
        ossLastTimestamp = 0
        bpmSmoothingBuffer.removeAll()
        onsetPrevMags = nil
        lastLockedBPM = 0
        tempoChangeCount = 0
    }

    // MARK: - FFT Processing
    //
    // Pipeline: raw audio → Hanning window → interleave-to-split-complex →
    // forward FFT → squared magnitudes → 4/N² normalisation → dB conversion →
    // auto-level → logarithmic band mapping → normalise to 0–1

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let dspStart = CACurrentMediaTime()
        tapBufferCount += 1
        if tapBufferCount <= 3 || tapBufferCount % 100 == 0 {
            alog("processBuffer #\(tapBufferCount): frameLength=\(buffer.frameLength), source=\(audioSource)")
        }

        guard let channelData = buffer.floatChannelData?[0],
              let fftSetup = fftSetup else { return }

        let frameCount = Int(buffer.frameLength)
        let sampleCount = min(frameCount, fftSize)

        // Extract downsampled waveform for the time-domain display
        let waveformCount = SpectrumLayout.waveformSampleCount
        var waveform = [Float](repeating: 0, count: waveformCount)
        let waveStride = max(1, sampleCount / waveformCount)
        for i in 0..<waveformCount {
            let idx = i * waveStride
            if idx < sampleCount { waveform[i] = channelData[idx] }
        }

        // Apply Hanning window to reduce spectral leakage
        var windowedData = [Float](repeating: 0, count: fftSize)
        for i in 0..<sampleCount {
            windowedData[i] = channelData[i] * window[i]
        }

        // FFT: convert to split-complex format and perform forward transform
        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                // Pack interleaved real data into split-complex format.
                // Stride of 2 is in float-sized units, not DSPComplex units.
                windowedData.withUnsafeBufferPointer { dataBuf in
                    dataBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                        vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }

                let log2n = vDSP_Length(log2(Double(self.fftSize)))
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // Compute squared magnitudes (power spectrum)
                var mags = [Float](repeating: 0, count: halfN)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))

                // Normalise: 4/N² for one-sided power spectrum.
                // The 4× factor (vs naive 1/N²) accounts for the missing
                // negative-frequency energy. Without it, levels are 6dB too low.
                var normFactor = 4.0 / Float(self.fftSize * self.fftSize)
                var scaledMags = [Float](repeating: 0, count: halfN)
                vDSP_vsmul(mags, 1, &normFactor, &scaledMags, 1, vDSP_Length(halfN))

                // Floor to 1e-20 before dB conversion — vDSP_vdbcon requires non-zero input
                for i in 0..<halfN { scaledMags[i] = max(scaledMags[i], 1e-20) }

                // Convert to decibels (10 * log10, flag=1 for power)
                var ref: Float = 1.0
                var dbMags = [Float](repeating: 0, count: halfN)
                vDSP_vdbcon(scaledMags, 1, &ref, &dbMags, 1, vDSP_Length(halfN), 1)

                // Apply static gain boost (for simulator testing with quiet audio)
                if self.staticGainDB != 0 {
                    if self.tapBufferCount <= 3 {
                        alog("Applying gain=\(self.staticGainDB)dB, source=\(self.audioSource), peakDB=\(dbMags[1..<halfN].max() ?? -999)")
                    }
                    var gain = self.staticGainDB
                    vDSP_vsadd(dbMags, 1, &gain, &dbMags, 1, vDSP_Length(halfN))
                }

                // Auto-leveling: track the peak dB across all bins.
                // Ceiling rises instantly to meet loud signals, decays slowly
                // to maintain visual stability during quiet passages.
                var framePeakDB: Float = -120
                for i in 1..<halfN {
                    if dbMags[i] > framePeakDB { framePeakDB = dbMags[i] }
                }
                if framePeakDB > self.adaptiveCeiling {
                    self.adaptiveCeiling = framePeakDB
                } else {
                    self.adaptiveCeiling -= self.autoLevelDecay
                }
                self.adaptiveCeiling = max(self.adaptiveCeiling, self.minCeiling)
                self.adaptiveCeiling = min(self.adaptiveCeiling, self.maxCeiling)
                let dbCeiling = min(self.adaptiveCeiling + 5, 0)  // 5dB headroom
                let dbFloor = dbCeiling - self.displayRange

                // Map FFT bins to logarithmic frequency bands and normalise to 0–1
                let isMusic = self.audioSource == .music
                let tilt = isMusic ? AudioEngine.musicTiltRate : Float(0)
                let power = isMusic ? AudioEngine.musicTiltPower : Float(1)
                let spectrum = AudioEngine.mapToLogBands(dbMags, bandCount: self.bandCount, fftSize: self.fftSize, sampleRate: self.sampleRate, dbFloor: dbFloor, dbCeiling: dbCeiling, spectralTilt: tilt, tiltPower: power)

                // Pitch detection (if enabled)
                var pitchNote = ""
                var pitchCents: Float = 0
                if self.tuningEnabled {
                    if let freq = self.detectPitch(samples: channelData, sampleCount: sampleCount) {
                        self.pitchMissCount = 0

                        // If pitch jumps by more than a semitone from the current median,
                        // flush the buffer — the user has changed notes
                        if !self.pitchSmoothingBuffer.isEmpty {
                            let sorted = self.pitchSmoothingBuffer.sorted()
                            let currentMedian = sorted[sorted.count / 2]
                            let semitoneDistance = abs(12.0 * log2(freq / currentMedian))
                            if semitoneDistance > 1.0 {
                                self.pitchSmoothingBuffer.removeAll()
                            }
                        }

                        self.pitchSmoothingBuffer.append(freq)
                        if self.pitchSmoothingBuffer.count > self.pitchSmoothingCount {
                            self.pitchSmoothingBuffer.removeFirst()
                        }
                        let sorted = self.pitchSmoothingBuffer.sorted()
                        let medianFreq = sorted[sorted.count / 2]
                        let result = AudioEngine.frequencyToNote(medianFreq)
                        pitchNote = result.note
                        pitchCents = result.cents
                    } else {
                        // No pitch detected — clear display after several consecutive misses
                        self.pitchMissCount += 1
                        if self.pitchMissCount >= self.pitchMissLimit {
                            self.pitchSmoothingBuffer.removeAll()
                        } else if !self.pitchSmoothingBuffer.isEmpty {
                            // Hold the last detected pitch briefly during short gaps
                            let sorted = self.pitchSmoothingBuffer.sorted()
                            let medianFreq = sorted[sorted.count / 2]
                            let result = AudioEngine.frequencyToNote(medianFreq)
                            pitchNote = result.note
                            pitchCents = result.cents
                        }
                    }

                    // Log pitch changes (not every frame)
                    let pitchLabel = pitchNote.isEmpty ? "--" : "\(pitchNote) \(String(format: "%+.0f", pitchCents))c"
                    if pitchLabel != self.lastLoggedPitch {
                        if AudioEngine.pitchLoggingEnabled { alog("PITCH: \(pitchLabel)") }
                        self.lastLoggedPitch = pitchLabel
                    }
                }

                // BPM detection (if enabled) — compute multiple onset FFTs per
                // callback for ~43fps onset rate (hop=1024, vs ~10fps with hop=4410).
                // Uses a separate 1024-point FFT for onset detection only.
                var bpm: Int? = nil
                var isBeat = false
                if self.bpmEnabled, let onsetSetup = self.onsetFFTSetup {
                    let hopSize = self.onsetFFTSize  // 1024
                    let baseTimestamp = CACurrentMediaTime()
                    let secondsPerSample = 1.0 / Double(self.sampleRate)
                    var offset = 0
                    while offset + self.onsetFFTSize <= frameCount {
                        let hopTimestamp = baseTimestamp + Double(offset) * secondsPerSample
                        let onsetResult = self.computeOnsetAndDetectBPM(
                            channelData: channelData, offset: offset,
                            fftSetup: onsetSetup, timestamp: hopTimestamp)
                        if onsetResult.bpm != nil { bpm = onsetResult.bpm }
                        if onsetResult.isBeat { isBeat = true }
                        offset += hopSize
                    }
                }

                // DSP performance measurement
                let dspElapsed = CACurrentMediaTime() - dspStart
                self.dspTimingSum += dspElapsed
                self.dspTimingCount += 1
                if dspElapsed > self.dspTimingMax { self.dspTimingMax = dspElapsed }
                if self.dspTimingCount % 100 == 0 {
                    let avgMs = (self.dspTimingSum / Double(self.dspTimingCount)) * 1000
                    let maxMs = self.dspTimingMax * 1000
                    let budgetMs = Double(self.fftSize) / Double(self.sampleRate) * 1000
                    alog("DSP PERF: avg=\(String(format: "%.2f", avgMs))ms, max=\(String(format: "%.2f", maxMs))ms, budget=\(String(format: "%.1f", budgetMs))ms (tuning=\(self.tuningEnabled), bpm=\(self.bpmEnabled))")
                }

                // Capture values for main-thread dispatch (Swift concurrency requires
                // copying mutable vars to let before crossing actor boundaries)
                let finalSpectrum = spectrum
                let publishedFloor = dbFloor
                let publishedCeiling = dbCeiling
                let finalNote = pitchNote
                let finalCents = pitchCents
                let finalBPM = bpm
                let finalIsBeat = isBeat

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.spectrumData = finalSpectrum
                    self.waveformData = waveform
                    self.dbFloor = publishedFloor
                    self.dbCeiling = publishedCeiling
                    self.detectedNote = finalNote
                    self.detectedCents = finalCents
                    self.detectedBPM = finalBPM
                    if finalIsBeat {
                        self.beatFlash = true
                        self.beatFlashCounter = 6  // ~100ms at 60fps
                    }
                }
            }
        }
    }

    // MARK: - Pitch Detection

    /// Time-domain autocorrelation pitch detection.
    /// Computes autocorrelation directly from audio samples using vDSP_dotpr,
    /// which is far more reliable for voice and instruments than the
    /// frequency-domain approach (IFFT of power spectrum exaggerates harmonics).
    /// Searches for the first significant peak in the musical range (65Hz–2000Hz).
    private func detectPitch(samples: UnsafePointer<Float>, sampleCount: Int) -> Float? {
        let n = min(sampleCount, fftSize)

        // Lag range for musical pitches (C2 65Hz to B5 988Hz)
        let minLag = max(2, Int(sampleRate / 1000))    // 1000 Hz — skips noisy short-lag region
        let maxLag = min(Int(sampleRate / 65), n / 2)  // 65 Hz (or half buffer)
        guard minLag < maxLag else { return nil }

        // Compute normalised autocorrelation for each lag in the musical range.
        // Uses Pearson correlation (normalise by overlapping segment energies)
        // to eliminate the short-lag bias that causes false detections in noise.
        var acf = [Float](repeating: 0, count: maxLag + 1)

        // Seed segment energies for the first lag
        var energyL: Float = 0  // energy of x[0..<n-lag]
        var energyR: Float = 0  // energy of x[lag..<n]
        vDSP_dotpr(samples, 1, samples, 1, &energyL, vDSP_Length(n - minLag))
        vDSP_dotpr(samples + minLag, 1, samples + minLag, 1, &energyR, vDSP_Length(n - minLag))

        for lag in minLag...maxLag {
            var dot: Float = 0
            vDSP_dotpr(samples, 1, samples + lag, 1, &dot, vDSP_Length(n - lag))

            let denom = sqrtf(energyL * energyR)
            acf[lag] = denom > 0 ? dot / denom : 0

            // Incrementally update segment energies for next lag
            if lag < maxLag {
                let dropL = samples[n - lag - 1]
                energyL -= dropL * dropL
                let dropR = samples[lag]
                energyR -= dropR * dropR
            }
        }

        // Find the first peak above threshold, scanning from short to long lags.
        // Find the first autocorrelation peak above threshold, scanning from
        // short lags (high freq) to long lags (low freq). With Pearson normalisation
        // and minLag at 1000Hz, noise is bounded well below 0.75.
        var bestLag = minLag
        var bestVal: Float = 0
        var rising = false

        for lag in minLag...maxLag {
            if acf[lag] > bestVal {
                bestVal = acf[lag]
                bestLag = lag
                rising = true
            } else if rising && bestVal > 0.75 {
                // Found a peak above threshold — this is the fundamental
                break
            } else if rising && acf[lag] < bestVal * 0.7 {
                // Peak fell away but wasn't strong enough — reset for next peak
                rising = false
                bestVal = 0
            }
        }

        // Confidence threshold — voice 0.93+, instruments 0.8+, noise <0.7
        if self.tapBufferCount % 20 == 0 {
            let candidateFreq = bestLag > 0 ? sampleRate / Float(bestLag) : 0
            if AudioEngine.pitchLoggingEnabled {
                alog("PITCH DBG: acPeak=\(String(format: "%.3f", bestVal)) lag=\(bestLag) freq=\(String(format: "%.1f", candidateFreq))Hz")
            }
        }
        guard bestVal > 0.75 else { return nil }

        // Parabolic interpolation for sub-sample accuracy
        guard bestLag > minLag && bestLag < maxLag else { return nil }
        let a = acf[bestLag - 1]
        let b = acf[bestLag]
        let c = acf[bestLag + 1]
        let denom = a - 2 * b + c
        let delta: Float = (denom != 0) ? 0.5 * (a - c) / denom : 0
        let refinedLag = Float(bestLag) + delta

        guard refinedLag > 0 else { return nil }
        return sampleRate / refinedLag
    }

    /// Converts a frequency to the nearest musical note name and cents offset from A4=440Hz.
    static func frequencyToNote(_ freq: Float) -> (note: String, cents: Float) {
        let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let semitones = 12.0 * log2(freq / 440.0)
        let roundedSemitones = roundf(semitones)
        let cents = (semitones - roundedSemitones) * 100.0

        // A4 is MIDI note 69
        let midiNote = Int(roundedSemitones) + 69
        let noteIndex = ((midiNote % 12) + 12) % 12
        let octave = (midiNote / 12) - 1

        return ("\(noteNames[noteIndex])\(octave)", cents)
    }

    // MARK: - BPM Detection

    /// Compute a 1024-point onset FFT at the given offset and feed the result
    /// into the BPM detector. Called multiple times per audio callback (hop=1024)
    /// to achieve ~43fps onset rate.
    private func computeOnsetAndDetectBPM(
        channelData: UnsafePointer<Float>, offset: Int,
        fftSetup: FFTSetup, timestamp: Double
    ) -> (bpm: Int?, isBeat: Bool) {
        let n = onsetFFTSize
        let halfN = n / 2

        // Window the samples
        var windowed = [Float](repeating: 0, count: n)
        for i in 0..<n {
            windowed[i] = channelData[offset + i] * onsetWindow[i]
        }

        // FFT → magnitudes (linear, not dB)
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        windowed.withUnsafeBufferPointer { dataBuf in
            dataBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfN))
                let log2n = vDSP_Length(log2(Double(n)))
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))
            }
        }
        // Sqrt to get magnitude (zvmags gives squared magnitudes)
        var magCount = Int32(halfN)
        vvsqrtf(&mags, mags, &magCount)

        // Spectral flux: sum of positive magnitude increases across all bins
        // (broadband — captures kicks, snares, and hi-hats for better rhythm detection)
        var flux: Float = 0
        if let prev = onsetPrevMags {
            for i in 1..<halfN {
                let diff = mags[i] - prev[i]
                if diff > 0 { flux += diff }
            }
        }
        onsetPrevMags = mags

        // Feed flux into BPM detector
        return detectBPM(flux: flux, timestamp: timestamp)
    }

    /// BPM detection via autocorrelation of the onset strength signal.
    ///
    /// Accepts a pre-computed spectral flux value (from the onset FFT).
    /// The flux is log-compressed before storing. The autocorrelation uses
    /// detrending (subtract 2s local mean) and normalisation for robust
    /// detection. Harmonic checking at L/2 resolves octave ambiguity.
    private func detectBPM(flux: Float, timestamp: Double) -> (bpm: Int?, isBeat: Bool) {
        // Log compress the flux before storing — compresses dynamic range so
        // quiet hi-hat onsets become comparable to loud kick drums, preventing
        // a few loud beats from dominating the autocorrelation.
        let compressedFlux = log(1.0 + 10.0 * flux)

        // Smoothed energy for beat flash threshold
        let smoothingAlpha: Float = 0.05
        recentLowEnergy = recentLowEnergy * (1 - smoothingAlpha) + compressedFlux * smoothingAlpha

        // Store compressed flux in circular buffer and track timing
        if spectralFluxHistory.count < fluxHistorySize {
            spectralFluxHistory.append(compressedFlux)
        } else {
            spectralFluxHistory[fluxWriteIndex] = compressedFlux
        }
        fluxWriteIndex = (fluxWriteIndex + 1) % fluxHistorySize
        fluxSampleCount += 1
        if ossFirstTimestamp == 0 { ossFirstTimestamp = timestamp }
        ossLastTimestamp = timestamp

        // Beat flash: simple threshold on compressed flux
        var isBeat = false
        if spectralFluxHistory.count >= 20 {
            let count = Float(spectralFluxHistory.count)
            let mean = spectralFluxHistory.reduce(0, +) / count
            let variance = spectralFluxHistory.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
            let threshold = mean + 1.5 * sqrt(variance)
            if compressedFlux > threshold && compressedFlux > 0.1 && (timestamp - lastBeatTime) > (60.0 / 220.0) {
                isBeat = true
                lastBeatTime = timestamp
            }
        }

        // Need at least ~2 seconds of data before attempting BPM
        let minSamples = 86  // ~2s at ~43fps
        guard spectralFluxHistory.count >= minSamples else { return (nil, isBeat) }

        // Only recompute autocorrelation every ~20 frames (~0.5s at 43fps)
        bpmUpdateCounter += 1
        guard bpmUpdateCounter % 20 == 0 else {
            return (detectedBPM, isBeat)
        }

        // --- Autocorrelation of the onset strength signal ---
        // Linearise the circular buffer
        let n = spectralFluxHistory.count
        var oss = [Float](repeating: 0, count: n)
        for i in 0..<n {
            oss[i] = spectralFluxHistory[(fluxWriteIndex + i) % n]
        }

        // Compute variance of raw flux BEFORE detrending — this measures whether
        // the spectral content is actually changing (beats present) vs steady state.
        // Steady tones have near-zero flux variance; rhythmic music has high variance.
        var rawMean: Float = 0
        vDSP_meanv(oss, 1, &rawMean, vDSP_Length(n))
        var rawVariance: Float = 0
        for i in 0..<n {
            let d = oss[i] - rawMean
            rawVariance += d * d
        }
        rawVariance /= Float(n)

        // Detrend: subtract 2-second local mean to remove slow energy variations.
        // This eliminates false autocorrelation during quiet passages where the
        // DC component of the onset signal produces positive correlation at all lags.
        let elapsed = ossLastTimestamp - ossFirstTimestamp
        guard elapsed > 1.0 else { return (nil, isBeat) }
        let ossRate = Double(fluxSampleCount - 1) / elapsed
        let detrendWindow = max(1, Int(ossRate * 2.0))  // 2 seconds
        for i in 0..<n {
            let start = max(0, i - detrendWindow / 2)
            let end = min(n, i + detrendWindow / 2 + 1)
            var localMean: Float = 0
            for j in start..<end { localMean += oss[j] }
            localMean /= Float(end - start)
            oss[i] = max(0, oss[i] - localMean)  // half-wave rectify after detrending
        }

        // Normalise to unit variance (makes confidence threshold meaningful)
        var ossMean: Float = 0
        var ossStd: Float = 0
        vDSP_normalize(oss, 1, &oss, 1, &ossMean, &ossStd, vDSP_Length(n))
        // If stddev is near zero (silence), no rhythm to detect
        guard ossStd > 1e-6 else {
            bpmSmoothingBuffer.removeAll()
            return (nil, isBeat)
        }

        // Compute autocorrelation for lags in the 80–160 BPM range.
        // This covers the vast majority of popular music. The auto-halve/double
        // below handles tempos outside this range.
        let minLag = max(3, Int(ossRate * 60.0 / 160.0))  // 160 BPM
        let maxLag = min(n / 2, Int(ceil(ossRate * 60.0 / 80.0)))  // 80 BPM

        guard maxLag > minLag + 1 else { return (nil, isBeat) }

        var acValues = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var acValue: Float = 0
            let overlapLength = vDSP_Length(n - lag)
            vDSP_dotpr(oss, 1, Array(oss[lag...]), 1, &acValue, overlapLength)
            acValues[lag] = acValue / Float(n - lag)
        }

        // Find the peak lag
        var bestLag = minLag
        for lag in (minLag + 1)...maxLag {
            if acValues[lag] > acValues[bestLag] {
                bestLag = lag
            }
        }

        guard acValues[bestLag] > 0 else { return (nil, isBeat) }

        // --- Harmonic check: resolve octave ambiguity ---
        // If half-lag (double tempo) has a meaningful peak, prefer it.
        // For periodic signals, the autocorrelation at 2*period is always >= at period,
        // so the slow-tempo peak usually wins without this correction.
        // Compute AC at half-lag even if outside the normal search range,
        // since the double-tempo may exceed the BPM ceiling (e.g. 85→170 BPM).
        let halfLag = bestLag / 2
        if halfLag >= 3 && halfLag < n / 2 {
            let searchLo = max(3, halfLag - 1)
            let searchHi = min(n / 2 - 1, halfLag + 1)
            if searchLo <= searchHi {
                // Compute AC at half-lag candidates (may be outside acValues range)
                var bestHalfLag = searchLo
                var bestHalfAC: Float = -1
                for candidateHalf in searchLo...searchHi {
                    var ac: Float = 0
                    if candidateHalf < acValues.count && acValues[candidateHalf] != 0 {
                        ac = acValues[candidateHalf]
                    } else {
                        // Compute on the fly for lags outside the search range
                        let overlapLen = vDSP_Length(n - candidateHalf)
                        vDSP_dotpr(oss, 1, Array(oss[candidateHalf...]), 1, &ac, overlapLen)
                        ac /= Float(n - candidateHalf)
                    }
                    if ac > bestHalfAC {
                        bestHalfAC = ac
                        bestHalfLag = candidateHalf
                    }
                }
                // Only prefer the half-lag if its BPM falls within the displayable
                // range (70-160). Otherwise the auto-halve will produce a wrong value.
                let halfBPM = Int(round(60.0 * ossRate / Double(bestHalfLag)))
                if bestHalfAC > 0.40 * acValues[bestLag] && halfBPM <= 160 {
                    bestLag = bestHalfLag
                }
            }
        }

        // Parabolic interpolation around the peak for sub-lag accuracy
        var refinedLag = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let a = acValues[bestLag - 1]
            let b = acValues[bestLag]
            let g = acValues[bestLag + 1]
            let denom = a - 2.0 * b + g
            if abs(denom) > 1e-10 {
                let p = Double(0.5 * (a - g) / denom)
                refinedLag = Double(bestLag) + p
            }
        }

        // Convert refined lag to BPM
        var estimatedBPM = Int(round(60.0 * ossRate / refinedLag))

        // Clamp to displayable range. Auto-halve above 160, auto-double below 70.
        while estimatedBPM > 160 { estimatedBPM /= 2 }
        while estimatedBPM < 70 { estimatedBPM *= 2 }

        // Confidence: ratio of peak AC to zero-lag AC (after normalisation)
        var zeroLagAC: Float = 0
        vDSP_dotpr(oss, 1, oss, 1, &zeroLagAC, vDSP_Length(n))
        zeroLagAC /= Float(n)
        let confidence = zeroLagAC > 0 ? acValues[bestLag] / zeroLagAC : 0

        if Self.bpmLoggingEnabled {
            alog("BPM EST: bpm=\(estimatedBPM) lag=\(bestLag) refinedLag=\(String(format: "%.2f", refinedLag)) confidence=\(String(format: "%.0f", confidence * 100))% rawVar=\(String(format: "%.2f", rawVariance)) ossRate=\(String(format: "%.1f", ossRate)) samples=\(n)")
        }

        // Suppress when flux has very low variance (no rhythmic content).
        // Steady tones, silence, and ambient noise all produce near-zero flux variance.
        guard rawVariance > 0.5 else {
            bpmSmoothingBuffer.removeAll()
            return (nil, isBeat)
        }

        // Require meaningful correlation
        guard confidence > 0.15 else {
            bpmSmoothingBuffer.removeAll()
            return (nil, isBeat)
        }
        guard estimatedBPM >= 80 && estimatedBPM <= 200 else {
            bpmSmoothingBuffer.removeAll()
            return (nil, isBeat)
        }

        // --- Tempo-change detection ---
        // If the new estimate consistently diverges from the locked BPM,
        // flush all state and restart. This handles track changes, section
        // transitions, and corrects initial wrong locks — without requiring
        // the user to toggle BPM off and on.
        if lastLockedBPM > 0 && abs(estimatedBPM - lastLockedBPM) > 10 {
            tempoChangeCount += 1
            if tempoChangeCount >= 3 {
                // Sustained divergence — flush and restart
                if Self.bpmLoggingEnabled {
                    alog("BPM CHANGE: \(lastLockedBPM) → \(estimatedBPM) (flushing after \(tempoChangeCount) divergent estimates)")
                }
                spectralFluxHistory.removeAll()
                fluxWriteIndex = 0
                fluxSampleCount = 0
                ossFirstTimestamp = 0
                ossLastTimestamp = 0
                bpmSmoothingBuffer.removeAll()
                onsetPrevMags = nil
                lastLockedBPM = 0
                tempoChangeCount = 0
                return (nil, isBeat)
            }
        } else {
            tempoChangeCount = 0
        }

        // Temporal smoothing: require consensus over 3 estimates
        bpmSmoothingBuffer.append(estimatedBPM)
        if bpmSmoothingBuffer.count > bpmSmoothingSize {
            bpmSmoothingBuffer.removeFirst()
        }

        guard bpmSmoothingBuffer.count >= bpmSmoothingSize else {
            return (detectedBPM, isBeat)
        }
        let median = bpmSmoothingBuffer.sorted()[bpmSmoothingSize / 2]
        let nearMedian = bpmSmoothingBuffer.filter { abs($0 - median) <= 5 }.count
        guard nearMedian >= bpmSmoothingSize - 1 else {
            return (detectedBPM, isBeat)
        }

        lastLockedBPM = median
        return (median, isBeat)
    }

    // MARK: - Static Helpers (extracted for testability)
    //
    // These are `internal static` so unit tests can call them directly
    // without needing audio hardware or a running engine.

    /// Maps linear FFT bins to logarithmic frequency bands and normalises to 0–1.
    ///
    /// Logarithmic mapping gives equal visual weight to each octave (20–40Hz,
    /// 40–80Hz, ..., 10k–20kHz), matching human pitch perception. Linear mapping
    /// would waste half the display on frequencies above 10kHz.
    /// Spectral tilt applied in music mode to compensate for the steep
    /// high-frequency rolloff of commercial music. Uses an exponential curve
    /// (octaves^power) so the boost accelerates toward the treble end.
    /// tiltRate: base dB per octave. tiltPower: exponent (1.0 = linear).
    static let musicTiltRate: Float = 5.0
    static let musicTiltPower: Float = 1.4

    static func mapToLogBands(_ dbMagnitudes: [Float], bandCount: Int, fftSize: Int, sampleRate: Float, dbFloor: Float = -80, dbCeiling: Float = 0, spectralTilt: Float = 0, tiltPower: Float = 1.0) -> [Float] {
        var bands = [Float](repeating: 0, count: bandCount)
        let halfN = fftSize / 2
        let minFreq: Float = 20.0
        let maxFreq: Float = min(sampleRate / 2, 20000.0)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let freqPerBin = sampleRate / Float(fftSize)

        for i in 0..<bandCount {
            // Each band spans a logarithmically-equal slice of the frequency range
            let logLow = logMin + (logMax - logMin) * Float(i) / Float(bandCount)
            let logHigh = logMin + (logMax - logMin) * Float(i + 1) / Float(bandCount)
            let freqLow = pow(10, logLow)
            let freqHigh = pow(10, logHigh)
            let binLow = max(1, Int(freqLow / freqPerBin))
            let binHigh = min(halfN - 1, Int(freqHigh / freqPerBin))

            // Average the dB values of all FFT bins within this band
            if binLow <= binHigh {
                var sum: Float = 0
                for bin in binLow...binHigh { sum += dbMagnitudes[bin] }
                bands[i] = sum / Float(binHigh - binLow + 1)
            } else if binLow < halfN {
                bands[i] = dbMagnitudes[binLow]
            }
        }

        // Apply spectral tilt: boost bands above 200Hz with an exponential curve.
        // Below 200Hz: no change (bass stays natural).
        // Above 200Hz: progressive boost that ramps up toward 20kHz,
        // compensating for the HF rolloff of commercial music.
        if spectralTilt != 0 {
            let refFreq: Float = 200.0
            for i in 0..<bandCount {
                let logLow = logMin + (logMax - logMin) * Float(i) / Float(bandCount)
                let logHigh = logMin + (logMax - logMin) * Float(i + 1) / Float(bandCount)
                let centreFreq = pow(10, (logLow + logHigh) / 2)
                let octavesAboveRef = log2(centreFreq / refFreq)
                if octavesAboveRef > 0 {
                    bands[i] += spectralTilt * pow(octavesAboveRef, tiltPower)
                }
            }
        }

        // Normalise to 0–1 within the current auto-leveled dB range
        let range = dbCeiling - dbFloor
        for i in 0..<bandCount {
            bands[i] = (bands[i] - dbFloor) / range
            bands[i] = max(0, min(1, bands[i]))
        }
        return bands
    }

    /// Exponential smoothing between two arrays.
    /// `factor` controls how much of the new value to use (1.0 = no smoothing).
    static func applySmoothing(current: [Float], previous: [Float], factor: Float) -> [Float] {
        let count = min(current.count, previous.count)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = factor * current[i] + (1.0 - factor) * previous[i]
        }
        return result
    }

    /// Updates peak values: rises instantly to new highs, decays linearly otherwise.
    static func updatePeaks(spectrum: [Float], peaks: [Float], decayRate: Float) -> [Float] {
        let count = min(spectrum.count, peaks.count)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            if spectrum[i] > peaks[i] { result[i] = spectrum[i] }
            else { result[i] = max(0, peaks[i] - decayRate) }
        }
        return result
    }
}
