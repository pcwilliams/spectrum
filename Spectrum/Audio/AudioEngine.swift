import AVFoundation
import Accelerate

class AudioEngine: ObservableObject {
    @Published var spectrumData: [Float]
    @Published var peakData: [Float]
    @Published var waveformData: [Float]
    @Published var isRunning = false
    @Published var permissionDenied = false
    @Published var dbFloor: Float = -80
    @Published var dbCeiling: Float = 0

    private let engine = AVAudioEngine()
    private let fftSize = SpectrumLayout.fftSize
    private let bandCount = SpectrumLayout.bandCount

    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var sampleRate: Float = 44100

    // Audio-thread state (only accessed from tap callback)
    private var smoothedSpectrum: [Float]
    private var currentPeaks: [Float]

    // Auto-level state
    private var adaptiveCeiling: Float = -40
    private let autoLevelDecay: Float = 0.5
    private let displayRange: Float = 40
    private let minCeiling: Float = -60
    private let maxCeiling: Float = 0

    private let smoothingFactor: Float = 0.3
    private let peakDecayRate: Float = 0.008

    init() {
        let bandCount = SpectrumLayout.bandCount
        spectrumData = [Float](repeating: 0, count: bandCount)
        peakData = [Float](repeating: 0, count: bandCount)
        waveformData = [Float](repeating: 0, count: SpectrumLayout.waveformSampleCount)
        smoothedSpectrum = [Float](repeating: 0, count: bandCount)
        currentPeaks = [Float](repeating: 0, count: bandCount)

        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func start() {
        guard !isRunning else { return }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.startEngine()
                } else {
                    self?.permissionDenied = true
                }
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func startEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            sampleRate = Float(format.sampleRate)

            inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: format) { [weak self] buffer, _ in
                self?.processBuffer(buffer)
            }

            try engine.start()
            isRunning = true
        } catch {
            print("Audio engine error: \(error)")
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0],
              let fftSetup = fftSetup else { return }

        let frameCount = Int(buffer.frameLength)
        let sampleCount = min(frameCount, fftSize)

        // Extract waveform (downsample for display)
        let waveformCount = SpectrumLayout.waveformSampleCount
        var waveform = [Float](repeating: 0, count: waveformCount)
        let waveStride = max(1, sampleCount / waveformCount)
        for i in 0..<waveformCount {
            let idx = i * waveStride
            if idx < sampleCount {
                waveform[i] = channelData[idx]
            }
        }

        // Apply Hanning window
        var windowedData = [Float](repeating: 0, count: fftSize)
        for i in 0..<sampleCount {
            windowedData[i] = channelData[i] * window[i]
        }

        // Perform FFT
        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                windowedData.withUnsafeBufferPointer { dataBuf in
                    dataBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                        vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }

                let log2n = vDSP_Length(log2(Double(self.fftSize)))
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // Squared magnitudes
                var mags = [Float](repeating: 0, count: halfN)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))

                // Normalize (4/N² for one-sided power spectrum)
                var normFactor = 4.0 / Float(self.fftSize * self.fftSize)
                var scaledMags = [Float](repeating: 0, count: halfN)
                vDSP_vsmul(mags, 1, &normFactor, &scaledMags, 1, vDSP_Length(halfN))

                // Floor to avoid log(0)
                for i in 0..<halfN {
                    scaledMags[i] = max(scaledMags[i], 1e-20)
                }

                // Convert to power dB
                var ref: Float = 1.0
                var dbMags = [Float](repeating: 0, count: halfN)
                vDSP_vdbcon(scaledMags, 1, &ref, &dbMags, 1, vDSP_Length(halfN), 1)

                // Auto-level: track peak dB with instant rise, slow decay
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

                // Map to logarithmic frequency bands
                let spectrum = AudioEngine.mapToLogBands(dbMags, bandCount: self.bandCount, fftSize: self.fftSize, sampleRate: self.sampleRate, dbFloor: dbFloor, dbCeiling: dbCeiling)

                // Publish raw spectrum — renderer handles smoothing at 60fps for silk
                let finalSpectrum = spectrum
                let finalPeaks = spectrum  // renderer tracks peaks independently

                let publishedFloor = dbFloor
                let publishedCeiling = dbCeiling

                DispatchQueue.main.async { [weak self] in
                    self?.spectrumData = finalSpectrum
                    self?.peakData = finalPeaks
                    self?.waveformData = waveform
                    self?.dbFloor = publishedFloor
                    self?.dbCeiling = publishedCeiling
                }
            }
        }
    }

    static func mapToLogBands(_ dbMagnitudes: [Float], bandCount: Int, fftSize: Int, sampleRate: Float, dbFloor: Float = -80, dbCeiling: Float = 0) -> [Float] {
        var bands = [Float](repeating: 0, count: bandCount)
        let halfN = fftSize / 2
        let minFreq: Float = 20.0
        let maxFreq: Float = min(sampleRate / 2, 20000.0)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let freqPerBin = sampleRate / Float(fftSize)

        for i in 0..<bandCount {
            let logLow = logMin + (logMax - logMin) * Float(i) / Float(bandCount)
            let logHigh = logMin + (logMax - logMin) * Float(i + 1) / Float(bandCount)
            let freqLow = pow(10, logLow)
            let freqHigh = pow(10, logHigh)

            let binLow = max(1, Int(freqLow / freqPerBin))
            let binHigh = min(halfN - 1, Int(freqHigh / freqPerBin))

            if binLow <= binHigh {
                var sum: Float = 0
                for bin in binLow...binHigh {
                    sum += dbMagnitudes[bin]
                }
                bands[i] = sum / Float(binHigh - binLow + 1)
            } else if binLow < halfN {
                bands[i] = dbMagnitudes[binLow]
            }
        }

        // Normalize to 0-1 using the adaptive dB range
        let range = dbCeiling - dbFloor
        for i in 0..<bandCount {
            bands[i] = (bands[i] - dbFloor) / range
            bands[i] = max(0, min(1, bands[i]))
        }

        return bands
    }

    static func applySmoothing(current: [Float], previous: [Float], factor: Float) -> [Float] {
        let count = min(current.count, previous.count)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = factor * current[i] + (1.0 - factor) * previous[i]
        }
        return result
    }

    static func updatePeaks(spectrum: [Float], peaks: [Float], decayRate: Float) -> [Float] {
        let count = min(spectrum.count, peaks.count)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            if spectrum[i] > peaks[i] {
                result[i] = spectrum[i]
            } else {
                result[i] = max(0, peaks[i] - decayRate)
            }
        }
        return result
    }
}
