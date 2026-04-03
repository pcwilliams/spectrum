import SwiftUI
import MetalKit

/// Bridges UIKit's `MTKView` into SwiftUI via `UIViewRepresentable`.
///
/// Uses a shared `Coordinator` (injected from ContentView, not created per-view)
/// so that ContentView's FPS timer can read `renderer.currentFPS` without
/// requiring @Published on a 60fps property.
///
/// `updateUIView` is only called when SwiftUI detects a state change (e.g. mode
/// picker), so mode updates are lightweight — they don't interfere with the
/// 60fps draw loop running on CADisplayLink.
struct SpectrumMetalView: UIViewRepresentable {
    let audioEngine: AudioEngine
    let mode: VisualizationMode
    let coordinator: Coordinator

    func makeCoordinator() -> Coordinator {
        coordinator
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.enableSetNeedsDisplay = false  // Continuous rendering via CADisplayLink
        mtkView.isPaused = false
        mtkView.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1.0)
        mtkView.depthStencilPixelFormat = .depth32Float  // needed for 3D surface mode

        if let renderer = MetalRenderer(mtkView: mtkView) {
            renderer.audioEngine = audioEngine
            renderer.mode = mode
            context.coordinator.renderer = renderer
            mtkView.delegate = renderer
        }

        return mtkView
    }

    /// Called by SwiftUI when mode changes. Only updates the mode property —
    /// the renderer's draw loop handles the actual rendering change.
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.mode = mode
    }

    /// Shared coordinator holding a reference to the Metal renderer.
    /// ContentView creates one instance and passes it in, enabling FPS readback.
    class Coordinator {
        var renderer: MetalRenderer?
    }
}
