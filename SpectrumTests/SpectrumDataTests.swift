import Foundation
import Testing
@testable import Spectrum

struct SpectrumDataTests {

    // MARK: - VisualizationMode

    @Test func visualizationMode_hasFourCases() {
        #expect(VisualizationMode.allCases.count == 4)
    }

    @Test func visualizationMode_rawValues() {
        #expect(VisualizationMode.bars.rawValue == "Bars")
        #expect(VisualizationMode.curve.rawValue == "Curve")
        #expect(VisualizationMode.circular.rawValue == "Circular")
        #expect(VisualizationMode.spectrogram.rawValue == "Spectrogram")
    }

    @Test func visualizationMode_allCasesOrder() {
        let cases = VisualizationMode.allCases
        #expect(cases[0] == .bars)
        #expect(cases[1] == .curve)
        #expect(cases[2] == .circular)
        #expect(cases[3] == .spectrogram)
    }

    // MARK: - SpectrumLayout constants

    @Test func layout_bandCount_is128() {
        #expect(SpectrumLayout.bandCount == 128)
    }

    @Test func layout_fftSize_isPowerOfTwo() {
        let fft = SpectrumLayout.fftSize
        #expect(fft > 0)
        #expect(fft & (fft - 1) == 0, "FFT size must be a power of 2")
    }

    @Test func layout_spectrumBoundsAreValid() {
        #expect(SpectrumLayout.spectrumLeft < SpectrumLayout.spectrumRight)
        #expect(SpectrumLayout.spectrumBottom < SpectrumLayout.spectrumTop)
        // Must be within NDC range [-1, 1]
        #expect(SpectrumLayout.spectrumLeft >= -1)
        #expect(SpectrumLayout.spectrumRight <= 1)
        #expect(SpectrumLayout.spectrumBottom >= -1)
        #expect(SpectrumLayout.spectrumTop <= 1)
    }

    @Test func layout_waveformBoundsAreValid() {
        #expect(SpectrumLayout.waveformLeft < SpectrumLayout.waveformRight)
        #expect(SpectrumLayout.waveformBottom < SpectrumLayout.waveformTop)
        #expect(SpectrumLayout.waveformLeft >= -1)
        #expect(SpectrumLayout.waveformRight <= 1)
        #expect(SpectrumLayout.waveformBottom >= -1)
        #expect(SpectrumLayout.waveformTop <= 1)
    }

    @Test func layout_waveformBelowSpectrum() {
        #expect(SpectrumLayout.waveformTop < SpectrumLayout.spectrumBottom,
                "Waveform area should be below spectrum area")
    }

    // MARK: - NDC to screen coordinate conversion

    @Test func ndcToScreenX_leftEdge() {
        let x = SpectrumLayout.ndcToScreenX(-1.0, width: 400)
        #expect(abs(x - 0) < 0.001)
    }

    @Test func ndcToScreenX_rightEdge() {
        let x = SpectrumLayout.ndcToScreenX(1.0, width: 400)
        #expect(abs(x - 400) < 0.001)
    }

    @Test func ndcToScreenX_center() {
        let x = SpectrumLayout.ndcToScreenX(0, width: 400)
        #expect(abs(x - 200) < 0.001)
    }

    @Test func ndcToScreenY_topEdge() {
        // NDC y=1 should map to screen y=0 (top)
        let y = SpectrumLayout.ndcToScreenY(1.0, height: 800)
        #expect(abs(y - 0) < 0.001)
    }

    @Test func ndcToScreenY_bottomEdge() {
        // NDC y=-1 should map to screen y=height (bottom)
        let y = SpectrumLayout.ndcToScreenY(-1.0, height: 800)
        #expect(abs(y - 800) < 0.001)
    }

    @Test func ndcToScreenY_center() {
        let y = SpectrumLayout.ndcToScreenY(0, height: 800)
        #expect(abs(y - 400) < 0.001)
    }

    @Test func ndcToScreen_invertedYAxis() {
        // Higher NDC y should map to lower screen y (NDC y-up vs screen y-down)
        let yHigh = SpectrumLayout.ndcToScreenY(0.5, height: 800)
        let yLow = SpectrumLayout.ndcToScreenY(-0.5, height: 800)
        #expect(yHigh < yLow)
    }

    @Test func ndcToScreen_scalesWithDimensions() {
        let x1 = SpectrumLayout.ndcToScreenX(0.5, width: 200)
        let x2 = SpectrumLayout.ndcToScreenX(0.5, width: 400)
        #expect(abs(x2 - x1 * 2) < 0.001)
    }
}
