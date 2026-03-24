# Apple Dev - Claude Code Project Conventions

This folder contains native iOS apps built entirely through conversation with Claude Code. This file captures the shared principles, patterns, and preferences that apply across all projects.

## Tech Stack

Every project uses the same foundation:

- **Language:** Swift 5
- **UI Framework:** SwiftUI (no storyboards, no XIBs)
- **Minimum Target:** iOS 17.0+ (some projects use iOS 18.0+)
- **Xcode:** 16+
- **Device:** iPhone only (`TARGETED_DEVICE_FAMILY = 1`)
- **Orientation:** Portrait only
- **Dependencies:** Zero external dependencies — pure Apple frameworks only (SwiftUI, MapKit, CoreLocation, Photos, CryptoKit, Swift Charts, etc.)

## Architecture

All projects follow **MVVM** with SwiftUI's reactive data binding:

- **View models** are `ObservableObject` classes with `@Published` properties, observed via `@StateObject` in views
- **Views** are declarative SwiftUI — no UIKit unless wrapping a system controller (e.g. `SFSafariViewController`)
- **Services/API clients** use the `actor` pattern for thread safety
- **Networking** uses native `URLSession` with `async/await` — no external HTTP libraries
- **View models** are annotated `@MainActor` when they drive UI state

## Project Structure

Each project follows this standard layout:

```
ProjectName/
├── ProjectName.xcodeproj/
├── CLAUDE.md                    # Developer reference (this kind of file)
├── README.md                    # User-facing documentation
├── architecture.html            # Interactive Mermaid.js architecture diagrams
├── tutorial.html                # Build narrative with prompts and responses
└── ProjectName/
    ├── App/
    │   ├── ProjectNameApp.swift # @main entry point
    │   └── ContentView.swift    # Root view / navigation
    ├── Models/                  # Data model structs and SwiftData @Models
    ├── Views/                   # SwiftUI views
    │   └── Components/          # Reusable view components
    ├── Services/                # API clients, managers, business logic
    ├── ViewModels/              # ObservableObject state management
    ├── Extensions/              # Formatters and helpers
    └── Assets.xcassets/
        ├── AppIcon.appiconset/  # 1024x1024 icons (standard, dark, tinted)
        └── AccentColor.colorset/
```

Smaller projects (e.g. Where) may flatten this into fewer files — the principle is simplicity over ceremony.

## Xcode Project File (project.pbxproj)

Projects are created and maintained by writing `project.pbxproj` directly, not via the Xcode GUI. When adding new Swift files to a target that doesn't use file system sync, register in four places:

1. **PBXBuildFile section** — build file entry
2. **PBXFileReference section** — file reference entry
3. **PBXGroup** — add to the appropriate group's `children` list
4. **PBXSourcesBuildPhase** — add build file to the target's Sources phase

ID patterns vary per project but follow a consistent incrementing convention within each project. Test targets may use `PBXFileSystemSynchronizedRootGroup` (Xcode 16+), meaning test files are auto-discovered.

## Build Verification

Always verify the build after any code change:

```bash
xcodebuild -project ProjectName.xcodeproj -scheme ProjectName \
  -destination 'generic/platform=iOS' build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

A clean result ends with `** BUILD SUCCEEDED **`. Fix any errors before considering a task complete.

## Testing

```bash
xcodebuild -project ProjectName.xcodeproj -scheme ProjectName \
  -destination 'platform=iOS Simulator,name=iPhone 16' test \
  CODE_SIGNING_ALLOWED=NO
```

- Use **in-memory containers** for SwiftData tests (fast, isolated)
- Use the **Swift Testing framework** (`import Testing`, `@Test`, `#expect()`) for newer projects
- **Extract pure decision logic as `internal static` methods** with explicit parameters so tests can inject values directly — avoid testing through singletons, UserDefaults, or system frameworks
- Test files that use Foundation types must `import Foundation` alongside `import Testing`

### Simulator Testing with Launch Arguments

For apps with multiple modes or views, add **launch argument parsing** so visual testing can be fully automated from the command line — never try to tap simulator UI with AppleScript (it's unreliable). Parse `ProcessInfo.processInfo.arguments` in the root view to accept flags like `-mode <value>`.

```swift
// In ContentView or root view
private static func initialMode() -> Mode {
    let args = ProcessInfo.processInfo.arguments
    if let idx = args.firstIndex(of: "-mode"), idx + 1 < args.count {
        return Mode(rawValue: args[idx + 1]) ?? .default
    }
    return .default
}
```

Then test each mode from the command line:

```bash
xcrun simctl install booted path/to/App.app
xcrun simctl privacy booted grant microphone com.bundle.id  # if needed
xcrun simctl terminate booted com.bundle.id
xcrun simctl launch booted com.bundle.id -- -mode someMode
sleep 2
xcrun simctl io booted screenshot /tmp/screenshot.png
```

This pattern was established in ShiftingSands (which supports `-mode`, `-count`, `-test`, `-autostart`, etc.) and adopted in Spectrum (`-mode bars|curve|circular|spectrogram`). Every new project with multiple visual states should support this from the start.

## Key Patterns

### Persistence

- **SwiftData** for structured app data (e.g. PillRecord)
- **UserDefaults / @AppStorage** for preferences, settings, and cache
- **iOS Keychain** for API credentials and secrets (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- **JSON encoding** in UserDefaults for lightweight structured data (e.g. portfolio, saved places)

### Networking

- **Graceful degradation:** The app should work with reduced functionality when API calls fail. Isolate independent API calls in separate `do/catch` blocks so one failure doesn't take down the others
- **Task cancellation:** Cancel in-flight tasks before starting new ones. Check `Task.isCancelled` before publishing results
- **Debouncing:** Use 0.8-second debounce for rapid user interactions (e.g. map panning) to prevent API spam
- **Caching:** Cache API responses with TTLs in UserDefaults (e.g. 5-min for quotes, 30-min for historical data)

### Concurrency

- **Actor-based services** for thread-safe API clients
- **`async let` for parallel fetching** of independent data
- Wrap work in an unstructured `Task` inside `.refreshable` to prevent SwiftUI from cancelling structured concurrency children when `@Published` properties trigger re-renders
- **`Task.detached(.utility)`** for background work like photo library scanning
- **Swift 6 concurrency:** Use `guard let self else { return }` in detached task closures; copy mutable `var` to `let` before `await MainActor.run`

### Timers

- Prefer **one-shot `DispatchWorkItem`** over polling `Timer.publish`
- Avoid always-running timers — schedule on demand, cancel on completion

### SwiftUI

- **`.id()` modifier** on views for animated identity changes (e.g. month transitions)
- **GeometryReader** for proportional layouts
- **Asymmetric slide transitions** with tracked direction state
- **NavigationStack** with `.toolbar` and `.sheet` for settings
- **`.refreshable`** for pull-to-refresh
- **Segmented pickers** for mode selection (chart periods, map styles, etc.)
- **@AppStorage** for persisting UI preferences across launches
- **`.contentShape(Rectangle())`** for full-row tap targets

## App Icons

Generated programmatically using **Python/Pillow** — not designed in a graphics tool. Three variants at 1024x1024:

- **Standard** (light mode)
- **Dark** (dark mode)
- **Tinted** (greyscale for tinted mode)

Referenced in `Contents.json` with `luminosity` appearance variants. Use `Image.new("RGB", ...)` not `"RGBA"` — iOS strips alpha for app icons, causing compositing artefacts with semi-transparent overlays.

## Documentation

Each project includes four living documents that must be kept up to date as the project evolves:

### CLAUDE.md (developer reference)

The comprehensive knowledge base for Claude Code sessions. Must be updated whenever:
- A new file, model, view, or service is added or removed
- An architectural decision is made or changed
- A new API is integrated or an existing one changes
- A non-obvious bug is fixed or a gotcha is discovered
- Build configuration, test coverage, or project structure changes

This is the single source of truth for project context. A future session should be able to read CLAUDE.md and understand the entire project without exploring the codebase.

### README.md (user-facing)

The public-facing project overview. Must be updated whenever:
- Features are added, changed, or removed
- Setup instructions change (new dependencies, API keys, permissions)
- The project structure changes significantly
- Screenshots become outdated (note when a new screenshot is needed)

Keep it concise and practical — someone should be able to clone the repo and get running by following the README.

### architecture.html (architecture diagrams)

Interactive Mermaid.js diagrams rendered in a standalone HTML file. Must be updated whenever:
- The view hierarchy changes (new views, removed views, restructured navigation)
- Data flow changes (new services, new API integrations, changed data pipelines)
- New major subsystems are added (e.g. a notification system, a caching layer, a P&L calculator)

Use `graph TD` (top-down) for readability on narrow screens. Load Mermaid.js from CDN. Apply the shared dark theme with CSS custom properties and project-appropriate accent colours.

### tutorial.html (build narrative)

A step-by-step record of how the app was built through Claude Code conversation. Must be updated whenever:
- A significant new feature is added via a notable prompt interaction
- A major refactor or architectural change is made
- An interesting problem is solved through iterative prompting

Capture the essence of the prompt, the approach taken, and the outcome. This documents the collaborative development process and serves as a guide for building similar features in future projects.

**Prompt tone:** Prompts recorded in the tutorial should sound collaborative, not demanding. Use phrases like "Could we try...", "How about...", "Would you mind...", "Would it be worth...", "I'd love it if..." rather than "Make...", "Add...", "I want...", "I need...". When describing problems, use "I'm seeing..." or "I'm noticing..." rather than assertive declarations. The tone should reflect a partnership — two people working together on something, not instructions being issued.

### Formatting conventions

- Use plain Markdown in `.md` files (no inline HTML except README badges). Images must use `![alt](src)` syntax, not `<img>` tags
- HTML docs use a shared dark theme with CSS custom properties and Mermaid.js loaded from CDN
- HTML docs include a hero screenshot in a phone-frame wrapper (black background, rounded corners, drop shadow) below the title/badges

## Common Gotchas

- **Keychain: always delete before add** to avoid `errSecDuplicateItem`
- **SwiftUI `.refreshable` cancels structured concurrency** — wrap network calls in an unstructured `Task`
- **Wikimedia geosearch caps at 10,000m radius** — clamp before sending
- **Wikipedia disambiguation pages** — filter out articles where extract contains "may refer to"

---

# Spectrum - Claude Code Developer Reference

## Overview

Real-time audio spectrum analyser for iPhone. Captures microphone input, performs FFT analysis using Apple's Accelerate framework (vDSP), and renders four GPU-accelerated visualisation modes via Metal at 60fps with silky-smooth animation.

## Architecture

### Data Flow

```
Microphone → AVAudioEngine (tap) → vDSP FFT → Log band mapping → Auto-level → Normalise
                                                                                    ↓
                                                             SwiftUI ← @Published ← DispatchQueue.main
                                                                  ↓
                                              MTKView → MetalRenderer (60fps smoothing + peak tracking) → GPU
```

### Key Design Decisions

- **CPU for FFT, GPU for rendering**: Accelerate/vDSP is SIMD-optimised and faster than GPU compute for typical audio buffer sizes (2048 samples). The GPU-to-CPU data transfer overhead would negate any Metal compute advantage.
- **Single vertex pipeline**: All four visualisation modes use the same Metal vertex/fragment pipeline with `.triangle` primitives. The spectrogram uses CPU-generated coloured quads rather than a texture, keeping the pipeline simple.
- **Decoupled audio and display rates**: AudioEngine publishes raw normalised spectrum data at ~21fps (audio callback rate). MetalRenderer applies its own 60fps asymmetric smoothing (fast attack, slow decay) for buttery animation independent of the audio update rate.
- **Direct data reading**: The MetalRenderer holds a weak reference to AudioEngine and reads `@Published` data directly in the draw call. Both run on the main thread (CADisplayLink on iOS), so no locking is needed.
- **Circular buffer for spectrogram**: Avoids array shifting overhead. Write index advances every 3rd frame (~20fps), read wraps around.
- **Auto-leveling over fixed range**: The display adapts to the current signal level rather than mapping a fixed dB range, ensuring responsive visuals in any environment from quiet rooms to concerts.

## Project Structure

```
Spectrum/
├── Spectrum.xcodeproj/
├── CLAUDE.md
├── README.md
├── architecture.html
├── tutorial.html
├── Spectrum/
│   ├── App/
│   │   ├── SpectrumApp.swift          # @main entry point
│   │   └── ContentView.swift          # Root view with mode picker, labels, FPS counter, launch args
│   ├── Audio/
│   │   └── AudioEngine.swift          # AVAudioEngine + vDSP FFT + auto-leveling
│   ├── Models/
│   │   └── SpectrumData.swift         # VisualizationMode enum, SpectrumLayout constants
│   ├── Rendering/
│   │   ├── MetalRenderer.swift        # Metal rendering + 60fps smoothing + FPS tracking
│   │   ├── SpectrumMetalView.swift    # UIViewRepresentable wrapping MTKView
│   │   └── Shaders.metal              # Metal vertex/fragment shaders
│   ├── Info.plist                      # NSMicrophoneUsageDescription
│   └── Assets.xcassets/
└── SpectrumTests/                      # PBXFileSystemSynchronizedRootGroup (auto-discovered)
    ├── AudioEngineTests.swift          # 21 tests: log band mapping, smoothing, peak tracking, auto-level
    ├── MetalRendererTests.swift        # 15 tests: gradient colour, heatmap colour
    └── SpectrumDataTests.swift         # 10 tests: enums, layout constants, NDC conversion
```

## Files

### SpectrumApp.swift
Standard SwiftUI @main entry point with WindowGroup containing ContentView.

### ContentView.swift
- Segmented picker for visualisation mode (Bars/Curve/Circular/Spectrogram)
- **Launch argument parsing**: `-mode <value>` sets initial mode via `ProcessInfo.processInfo.arguments`
- Metal view taking full remaining space
- GeometryReader overlay for **dynamic dB scale labels** (reflect auto-leveling range), frequency labels, "WAVEFORM" label
- **FPS counter** in top-right corner, updated every 0.5s from renderer via shared coordinator
- Permission denied state with instructions

### AudioEngine.swift
- `ObservableObject` with `@Published` spectrum (128 bands), waveform (512 samples), and adaptive dB range
- Requests microphone permission via `AVAudioApplication.requestRecordPermission`
- Configures `AVAudioSession` with `.record` category, `.default` mode (AGC enabled for maximum mic sensitivity)
- Installs tap on `engine.inputNode` with buffer size 2048
- FFT pipeline: Hanning window → `vDSP_ctoz` → `vDSP_fft_zrip` → `vDSP_zvmags` → `vDSP_vdbcon`
- **FFT normalisation**: `4/N²` (one-sided power spectrum correction, +6dB vs naive `1/N²`)
- Logarithmic frequency band mapping: 20Hz–20kHz across 128 bands
- **Auto-leveling**: tracks peak dB with instant rise and slow decay (0.5 dB/frame), adapts a 40dB display window. Ceiling clamped to [-60, 0] dB with 5dB headroom. Publishes `dbFloor`/`dbCeiling` for dynamic label display.
- Normalises to 0–1 range using the adaptive dB window
- Publishes **raw normalised** data — renderer handles smoothing at 60fps

### SpectrumData.swift
- `VisualizationMode` enum: `.bars`, `.curve`, `.circular`, `.spectrogram`
- `SpectrumLayout` with shared NDC coordinate constants and screen-coordinate conversion helpers

### MetalRenderer.swift
- `MTKViewDelegate` driving 60fps rendering
- **60fps asymmetric smoothing**: fast attack (lerp 0.35) for responsive rises, slow decay (lerp 0.12) for smooth falls — decoupled from the ~21fps audio callback rate
- **60fps peak tracking**: peaks rise instantly, decay at 0.006/frame (~3.5 seconds full fall)
- **FPS counter**: tracks frame times, publishes `currentFPS` every 0.5s
- Pre-allocates 200K-vertex Metal buffer (shared storage mode)
- `reserveCapacity` based on mode before building vertices (spectrogram needs ~100K)
- Builds all vertices on CPU, uploads to GPU via `copyMemory`, single draw call per frame
- **Bars mode**: Gradient-coloured vertical bars with peak indicators (white horizontal lines)
- **Curve mode**: Filled area under smooth curve with bright outline and peak dots
- **Circular mode**: Radial bars from centre with aspect-ratio correction for portrait
- **Spectrogram mode**: 128×128 grid of coloured quads from circular history buffer, throttled to ~20fps updates
- **Waveform**: Cyan line trace in lower portion with centre reference line
- Grid lines (dB horizontals + frequency verticals) for bars/curve modes
- Gradient helper: blue→cyan→green→yellow→red based on frequency position
- Heatmap helper: black→dark blue→cyan→yellow→red for spectrogram intensity

### SpectrumMetalView.swift
- `UIViewRepresentable` wrapping `MTKView`
- Accepts a shared `Coordinator` from ContentView (enables FPS readback)
- Creates `MetalRenderer` in `makeUIView`, passes `AudioEngine` reference
- Updates mode in `updateUIView` (only called on mode changes)

### Shaders.metal
- Simple vertex pass-through shader (position + colour)
- Fragment shader outputs interpolated vertex colour
- Uses non-packed `float2`/`float4` types to match Swift's `SIMD2<Float>`/`SIMD4<Float>` alignment (32-byte stride)
- Alpha blending enabled in pipeline for transparency effects

## Configuration

| Setting | Value |
|---------|-------|
| FFT Size | 2048 samples |
| FFT Normalisation | 4/N² (one-sided power spectrum) |
| Frequency Bands | 128 (logarithmic, 20Hz–20kHz) |
| Waveform Samples | 512 |
| Frame Rate | 60fps |
| Display Smoothing | Attack 0.35, decay 0.12 (per frame at 60fps) |
| Peak Decay Rate | 0.006/frame (~3.5s full fall) |
| Auto-Level Range | 40dB window, ceiling [-60, 0] dB |
| Auto-Level Decay | 0.5 dB/frame (~10 dB/sec) |
| Spectrogram Depth | 128 frames (~20fps update rate) |
| Max Vertices | 200,000 |
| Audio Session | `.record` category, `.default` mode |

## Launch Arguments

| Argument | Description | Example |
|----------|-------------|---------|
| `-mode <value>` | Set initial visualisation mode: `bars`, `curve`, `circular`, `spectrogram` | `-mode spectrogram` |

Used for automated simulator testing:
```bash
xcrun simctl terminate booted com.pwilliams.Spectrum
xcrun simctl launch booted com.pwilliams.Spectrum -- -mode circular
sleep 2
xcrun simctl io booted screenshot /tmp/screenshot.png
```

## Build

```bash
xcodebuild -project Spectrum.xcodeproj -scheme Spectrum \
  -destination 'generic/platform=iOS' build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

## Test

```bash
xcodebuild -project Spectrum.xcodeproj -scheme Spectrum \
  -destination 'platform=iOS Simulator,name=iPhone 16' test \
  CODE_SIGNING_ALLOWED=NO
```

### Test Architecture

Pure decision logic is extracted as `internal static` methods so tests can call them directly without audio hardware or Metal devices:

- **AudioEngine.mapToLogBands** — logarithmic frequency band mapping and dB normalisation (with configurable dB range)
- **AudioEngine.applySmoothing** — exponential smoothing between frames
- **AudioEngine.updatePeaks** — peak tracking with decay
- **MetalRenderer.gradientColor** — frequency-to-colour gradient (blue→cyan→green→yellow→red)
- **MetalRenderer.heatmapColor** — intensity-to-colour mapping for spectrogram

Test target uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+) for auto-discovery of test files.

### Test Coverage (46 tests)

| Suite | Tests | Coverage |
|-------|-------|----------|
| AudioEngineTests | 21 | Log band mapping (boundary values, clamping, band count, frequency distribution, sample rate, custom dB range, narrow range detail), smoothing (factor=0, 0.5, 1, default, mismatched lengths), peak tracking (new peak, decay, floor at zero, multi-frame) |
| MetalRendererTests | 15 | Gradient colour stops (blue, cyan, green, yellow, red), interpolation, alpha consistency, non-negative components, smooth transitions, heatmap stops (black, red), clamping, brightness ordering |
| SpectrumDataTests | 10 | Enum cases/raw values/ordering, layout constants (band count, FFT power-of-2, NDC bounds, waveform below spectrum), coordinate conversion (edges, centre, inverted Y, scaling) |

## Frameworks Used

- **Metal** + **MetalKit**: GPU-accelerated rendering
- **AVFoundation**: Audio capture (AVAudioEngine)
- **Accelerate**: vDSP FFT and signal processing
- **SwiftUI**: UI framework

## Future Roadmap

- **Fundamental frequency detection / instrument tuner**: Identify the dominant pitch (e.g. autocorrelation or cepstral analysis on the FFT output) and display the nearest musical note with cents offset. Would enable use as a guitar/instrument tuner.
- **Beat detection / BPM counter**: Detect rhythmic onsets via energy flux in the low-frequency bands, track inter-beat intervals, and display beats per minute. Could drive visual pulse effects synced to the beat.

## Known Gotchas

- **Metal/Swift struct alignment**: Metal `packed_float2`/`packed_float4` are 24 bytes but Swift's `SIMD2<Float>` + `SIMD4<Float>` is 32 bytes (SIMD4 has 16-byte alignment, adding 8 bytes of padding). Use non-packed `float2`/`float4` in Metal to match Swift's layout. Mismatched stride causes garbled rendering and GPU stalls from degenerate geometry.
- **Audio session mode matters**: `.measurement` mode disables AGC, resulting in very quiet mic input. Use `.default` mode for maximum sensitivity in a visualiser.
- **FFT normalisation**: Use `4/N²` not `1/N²` for one-sided power spectrum — the 4× factor accounts for the missing negative-frequency energy. Without it, levels are 6dB too low.
- **Decouple audio and display rates**: Smoothing at the audio callback rate (~21fps) produces jerky animation. Move smoothing to the renderer's 60fps draw loop with asymmetric lerp (fast attack, slow decay) for professional-quality visuals.
- `vDSP_ctoz` stride parameter (2) is measured in float-sized units, not DSPComplex struct units
- `vDSP_vdbcon` requires non-zero input — floor magnitudes to 1e-20 before calling
- MTKView on iOS uses CADisplayLink (main thread) — no threading concerns between SwiftUI updates and Metal draw calls
- Circular mode needs aspect-ratio correction (multiply x offsets by 1/aspectRatio) to avoid elliptical distortion in portrait
- Audio tap callback runs on audio thread — must dispatch to main thread before setting @Published properties
