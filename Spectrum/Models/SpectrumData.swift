import Foundation

enum VisualizationMode: String, CaseIterable {
    case bars = "Bars"
    case curve = "Curve"
    case circular = "Circular"
    case spectrogram = "Spectrogram"
}

enum SpectrumLayout {
    // NDC coordinates for spectrum area
    static let spectrumLeft: Float = -0.92
    static let spectrumRight: Float = 0.92
    static let spectrumBottom: Float = -0.15
    static let spectrumTop: Float = 0.92

    // NDC coordinates for waveform area
    static let waveformLeft: Float = -0.92
    static let waveformRight: Float = 0.92
    static let waveformBottom: Float = -0.92
    static let waveformTop: Float = -0.30

    // Band and FFT configuration
    static let bandCount = 128
    static let fftSize = 2048
    static let waveformSampleCount = 512

    // Convert NDC to screen coordinates
    static func ndcToScreenX(_ x: Float, width: CGFloat) -> CGFloat {
        CGFloat((x + 1.0) / 2.0) * width
    }

    static func ndcToScreenY(_ y: Float, height: CGFloat) -> CGFloat {
        CGFloat((1.0 - y) / 2.0) * height
    }
}
