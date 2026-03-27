import AVFoundation
import Accelerate

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

    // MARK: - Static Gain Boost (for simulator testing)
    //
    // Applied as a dB offset to FFT output, boosting quiet simulator audio
    // to exercise the full visualisation. Set via -gain <dB> launch argument.

    var staticGainDB: Float = 0

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

    // MARK: - Init / Deinit

    init() {
        let bandCount = SpectrumLayout.bandCount
        spectrumData = [Float](repeating: 0, count: bandCount)
        waveformData = [Float](repeating: 0, count: SpectrumLayout.waveformSampleCount)

        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        alog("AudioEngine.init")
    }

    deinit {
        if let setup = fftSetup {
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
            // .defaultToSpeaker routes music to the speaker (not earpiece).
            // AGC quality is identical to .record when using .default mode.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            alog("Audio session: .playAndRecord + .defaultToSpeaker")
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
    func playFile(url: URL) {
        alog("USER ACTION: playFile url=\(url.lastPathComponent)")
        alog("  engine.isRunning=\(engine.isRunning), playerNode.isPlaying=\(playerNode.isPlaying)")

        guard isRunning, engine.isRunning else {
            alog("playFile FAILED: engine not running")
            return
        }

        playerNode.stop()
        tapBufferCount = 0

        do {
            let file = try AVAudioFile(forReading: url)
            currentAudioFile = file
            alog("playFile: file opened — format=\(file.processingFormat.sampleRate)Hz, \(file.processingFormat.channelCount)ch, length=\(file.length)")

            playerNode.scheduleFile(file, at: nil) { [weak self] in
                alog("playFile: scheduleFile completion fired")
                DispatchQueue.main.async { self?.onTrackFinished?() }
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
    }

    // MARK: - FFT Processing
    //
    // Pipeline: raw audio → Hanning window → interleave-to-split-complex →
    // forward FFT → squared magnitudes → 4/N² normalisation → dB conversion →
    // auto-level → logarithmic band mapping → normalise to 0–1

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
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

                // Capture values for main-thread dispatch (Swift concurrency requires
                // copying mutable vars to let before crossing actor boundaries)
                let finalSpectrum = spectrum
                let publishedFloor = dbFloor
                let publishedCeiling = dbCeiling

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.spectrumData = finalSpectrum
                    self.waveformData = waveform
                    self.dbFloor = publishedFloor
                    self.dbCeiling = publishedCeiling
                }
            }
        }
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
