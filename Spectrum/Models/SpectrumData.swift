import Foundation

/// Audio input source selection.
enum AudioSource: String, CaseIterable {
    case mic = "Mic"
    case music = "Music"
}

/// The four GPU-rendered visualisation modes.
/// All share the same Metal pipeline — the CPU builds different vertex
/// geometry for each mode, but the shaders are identical.
enum VisualizationMode: String, CaseIterable {
    case bars = "Bars"
    case curve = "Curve"
    case circular = "Circular"
    case spectrogram = "Spectrogram"
}

/// Shared layout constants used by both the Metal renderer (for vertex positions)
/// and ContentView (for SwiftUI label positioning). All coordinates are in
/// Normalised Device Coordinates (NDC): x and y range from -1 to +1.
///
/// The screen is divided into two regions:
/// - **Spectrum area** (upper ~75%): frequency bars/curve/circular/spectrogram
/// - **Waveform area** (lower ~15%): time-domain oscilloscope trace
enum SpectrumLayout {
    // NDC coordinates for spectrum area (frequency display)
    static let spectrumLeft: Float = -0.92
    static let spectrumRight: Float = 0.92
    static let spectrumBottom: Float = -0.15
    static let spectrumTop: Float = 0.92

    // NDC coordinates for waveform area (time-domain display)
    static let waveformLeft: Float = -0.92
    static let waveformRight: Float = 0.92
    static let waveformBottom: Float = -0.92
    static let waveformTop: Float = -0.30

    // Audio processing configuration
    static let bandCount = 128         // Logarithmic frequency bands (20Hz–20kHz)
    static let fftSize = 2048          // FFT window size in samples (must be power of 2)
    static let waveformSampleCount = 512  // Downsampled time-domain points

    /// Converts NDC x-coordinate (-1...+1) to screen x-coordinate (0...width).
    static func ndcToScreenX(_ x: Float, width: CGFloat) -> CGFloat {
        CGFloat((x + 1.0) / 2.0) * width
    }

    /// Converts NDC y-coordinate (-1...+1) to screen y-coordinate (0...height).
    /// Note: NDC y increases upward, screen y increases downward — hence (1-y).
    static func ndcToScreenY(_ y: Float, height: CGFloat) -> CGFloat {
        CGFloat((1.0 - y) / 2.0) * height
    }
}
