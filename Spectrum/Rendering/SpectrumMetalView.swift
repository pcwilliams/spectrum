import SwiftUI
import MetalKit

struct SpectrumMetalView: UIViewRepresentable {
    let audioEngine: AudioEngine
    let mode: VisualizationMode
    let coordinator: Coordinator

    func makeCoordinator() -> Coordinator {
        coordinator
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1.0)

        if let renderer = MetalRenderer(mtkView: mtkView) {
            renderer.audioEngine = audioEngine
            renderer.mode = mode
            context.coordinator.renderer = renderer
            mtkView.delegate = renderer
        }

        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.mode = mode
    }

    class Coordinator {
        var renderer: MetalRenderer?
    }
}
