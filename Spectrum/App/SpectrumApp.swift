import SwiftUI

/// App entry point. Single-window SwiftUI app — all state management
/// and audio lifecycle is handled by ContentView and its owned objects.
@main
struct SpectrumApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
