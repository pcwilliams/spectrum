import Foundation
import Testing
@testable import Spectrum

struct AudioEngineTests {

    // MARK: - mapToLogBands

    @Test func mapToLogBands_allZeroDB_returnsAllOnes() {
        // 0 dB maps to (0 + 80) / 80 = 1.0
        let halfN = 1024
        let dbMags = [Float](repeating: 0, count: halfN)
        let result = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        #expect(result.count == 128)
        for value in result {
            #expect(value == 1.0)
        }
    }

    @Test func mapToLogBands_allMinusEightyDB_returnsAllZeros() {
        // -80 dB maps to (-80 + 80) / 80 = 0.0
        let halfN = 1024
        let dbMags = [Float](repeating: -80, count: halfN)
        let result = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        for value in result {
            #expect(value == 0.0)
        }
    }

    @Test func mapToLogBands_beyondRange_clampsToZeroOne() {
        let halfN = 1024
        // Values above 0 dB should clamp to 1.0
        let loudMags = [Float](repeating: 20, count: halfN)
        let loudResult = AudioEngine.mapToLogBands(loudMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        for value in loudResult {
            #expect(value == 1.0)
        }

        // Values below -80 dB should clamp to 0.0
        let quietMags = [Float](repeating: -120, count: halfN)
        let quietResult = AudioEngine.mapToLogBands(quietMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        for value in quietResult {
            #expect(value == 0.0)
        }
    }

    @Test func mapToLogBands_correctBandCount() {
        let halfN = 1024
        let dbMags = [Float](repeating: -40, count: halfN)

        let result16 = AudioEngine.mapToLogBands(dbMags, bandCount: 16, fftSize: 2048, sampleRate: 44100)
        #expect(result16.count == 16)

        let result64 = AudioEngine.mapToLogBands(dbMags, bandCount: 64, fftSize: 2048, sampleRate: 44100)
        #expect(result64.count == 64)

        let result128 = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        #expect(result128.count == 128)
    }

    @Test func mapToLogBands_uniformInput_returnsUniformOutput() {
        let halfN = 1024
        let dbMags = [Float](repeating: -40, count: halfN)
        let result = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        // -40 dB should map to (-40 + 80) / 80 = 0.5
        for value in result {
            #expect(abs(value - 0.5) < 0.01)
        }
    }

    @Test func mapToLogBands_respectsSampleRate() {
        let halfN = 1024
        let dbMags = [Float](repeating: -40, count: halfN)
        // Different sample rates should still produce valid results
        let result1 = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        let result2 = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 48000)
        #expect(result1.count == result2.count)
        // Both should be valid (all values in 0-1)
        for value in result1 + result2 {
            #expect(value >= 0 && value <= 1)
        }
    }

    @Test func mapToLogBands_lowBandsUseLowerFrequencies() {
        // Create a signal with energy only in low frequencies (bins 1-10)
        let halfN = 1024
        var dbMags = [Float](repeating: -80, count: halfN)
        for i in 1..<10 {
            dbMags[i] = -20 // louder in low freq bins
        }
        let result = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        // Low bands should have higher values than high bands
        let lowAvg = result[0..<16].reduce(0, +) / 16
        let highAvg = result[112..<128].reduce(0, +) / 16
        #expect(lowAvg > highAvg)
    }

    // MARK: - applySmoothing

    @Test func applySmoothing_factorOne_returnsCurrentValues() {
        let current: [Float] = [1.0, 0.5, 0.0]
        let previous: [Float] = [0.0, 0.0, 1.0]
        let result = AudioEngine.applySmoothing(current: current, previous: previous, factor: 1.0)
        #expect(result == current)
    }

    @Test func applySmoothing_factorZero_returnsPreviousValues() {
        let current: [Float] = [1.0, 0.5, 0.0]
        let previous: [Float] = [0.0, 0.0, 1.0]
        let result = AudioEngine.applySmoothing(current: current, previous: previous, factor: 0.0)
        #expect(result == previous)
    }

    @Test func applySmoothing_halfFactor_returnsAverage() {
        let current: [Float] = [1.0, 0.0, 0.6]
        let previous: [Float] = [0.0, 1.0, 0.4]
        let result = AudioEngine.applySmoothing(current: current, previous: previous, factor: 0.5)
        for i in 0..<result.count {
            #expect(abs(result[i] - 0.5) < 0.001)
        }
    }

    @Test func applySmoothing_defaultFactor_blends() {
        let current: [Float] = [1.0]
        let previous: [Float] = [0.0]
        let result = AudioEngine.applySmoothing(current: current, previous: previous, factor: 0.3)
        #expect(abs(result[0] - 0.3) < 0.001)
    }

    @Test func applySmoothing_mismatchedLengths_usesMinimum() {
        let current: [Float] = [1.0, 0.5]
        let previous: [Float] = [0.0, 0.0, 0.0]
        let result = AudioEngine.applySmoothing(current: current, previous: previous, factor: 0.5)
        #expect(result.count == 2)
    }

    // MARK: - mapToLogBands with custom dB range (auto-leveling)

    @Test func mapToLogBands_customRange_normalisesCorrectly() {
        let halfN = 1024
        // Signal at -40dB with range [-60, -20] should map to 0.5
        let dbMags = [Float](repeating: -40, count: halfN)
        let result = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100,
                                                dbFloor: -60, dbCeiling: -20)
        for value in result {
            #expect(abs(value - 0.5) < 0.01)
        }
    }

    @Test func mapToLogBands_customRange_ceilingMapsToOne() {
        let halfN = 1024
        let dbMags = [Float](repeating: -20, count: halfN)
        let result = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100,
                                                dbFloor: -60, dbCeiling: -20)
        for value in result {
            #expect(value == 1.0)
        }
    }

    @Test func mapToLogBands_customRange_floorMapsToZero() {
        let halfN = 1024
        let dbMags = [Float](repeating: -60, count: halfN)
        let result = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100,
                                                dbFloor: -60, dbCeiling: -20)
        for value in result {
            #expect(value == 0.0)
        }
    }

    @Test func mapToLogBands_narrowRange_increasesDetail() {
        let halfN = 1024
        // -45dB signal: with default [-80, 0] range → (−45+80)/80 = 0.4375
        // with narrow [-50, -40] range → (−45+50)/10 = 0.5
        let dbMags = [Float](repeating: -45, count: halfN)
        let wide = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100)
        let narrow = AudioEngine.mapToLogBands(dbMags, bandCount: 128, fftSize: 2048, sampleRate: 44100,
                                                dbFloor: -50, dbCeiling: -40)
        // Narrow range should show more detail (higher value) for this signal
        #expect(narrow[0] > wide[0])
    }

    // MARK: - updatePeaks

    @Test func updatePeaks_signalHigherThanPeak_setsNewPeak() {
        let spectrum: [Float] = [0.8, 0.5, 1.0]
        let peaks: [Float] = [0.5, 0.5, 0.5]
        let result = AudioEngine.updatePeaks(spectrum: spectrum, peaks: peaks, decayRate: 0.01)
        #expect(result[0] == 0.8)
        #expect(result[2] == 1.0)
    }

    @Test func updatePeaks_signalLowerThanPeak_decays() {
        let spectrum: [Float] = [0.3, 0.2, 0.1]
        let peaks: [Float] = [0.5, 0.5, 0.5]
        let result = AudioEngine.updatePeaks(spectrum: spectrum, peaks: peaks, decayRate: 0.01)
        #expect(abs(result[0] - 0.49) < 0.001)
        #expect(abs(result[1] - 0.49) < 0.001)
        #expect(abs(result[2] - 0.49) < 0.001)
    }

    @Test func updatePeaks_peakDoesNotGoBelowZero() {
        let spectrum: [Float] = [0.0]
        let peaks: [Float] = [0.005]
        let result = AudioEngine.updatePeaks(spectrum: spectrum, peaks: peaks, decayRate: 0.01)
        #expect(result[0] == 0.0)
    }

    @Test func updatePeaks_signalEqualsPeak_decays() {
        let spectrum: [Float] = [0.5]
        let peaks: [Float] = [0.5]
        // Equal means not greater, so it decays
        let result = AudioEngine.updatePeaks(spectrum: spectrum, peaks: peaks, decayRate: 0.01)
        #expect(abs(result[0] - 0.49) < 0.001)
    }

    @Test func updatePeaks_multipleFramesOfDecay() {
        var peaks: [Float] = [1.0]
        let spectrum: [Float] = [0.0]
        let decayRate: Float = 0.1
        for _ in 0..<10 {
            peaks = AudioEngine.updatePeaks(spectrum: spectrum, peaks: peaks, decayRate: decayRate)
        }
        #expect(peaks[0] == 0.0)
    }
}
