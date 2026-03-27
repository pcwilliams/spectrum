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

Real-time audio spectrum analyser for iPhone. Captures microphone input or plays local music files, performs FFT analysis using Apple's Accelerate framework (vDSP), and renders four GPU-accelerated visualisation modes via Metal at 60fps with silky-smooth animation.

## Architecture

### Data Flow

```
Mic mode:   Microphone → AVAudioEngine (inputNode tap) → vDSP FFT → Log bands → Auto-level → Normalise
Music mode: AVAudioFile → AVAudioPlayerNode → musicMixer (tap) → vDSP FFT → Log bands → Auto-level → Normalise
                                                                                                          ↓
                                                                            SwiftUI ← direct read ← DispatchQueue.main
                                                                                 ↓
                                                             MTKView → MetalRenderer (60fps smoothing + peak tracking) → GPU
```

### Engine Lifecycle (Critical)

```
1. Configure audio session (.playAndRecord on device, .playback on simulator)
2. engine.attach(playerNode)
3. engine.attach(musicMixer)
4. engine.connect(playerNode, to: musicMixer, format: mixerFormat)     ← MUST be before start()
5. engine.connect(musicMixer, to: engine.mainMixerNode, format: mixerFormat)  ← MUST be before start()
6. engine.inputNode.installTap(...)  [device only]
7. engine.prepare()
8. engine.start()
9. Source switching: removeTap + installTap only — never disconnect/reconnect nodes
```

### Key Design Decisions

- **CPU for FFT, GPU for rendering**: Accelerate/vDSP is SIMD-optimised and faster than GPU compute for typical audio buffer sizes (2048 samples). The GPU-to-CPU data transfer overhead would negate any Metal compute advantage.
- **Single vertex pipeline**: All four visualisation modes use the same Metal vertex/fragment pipeline with `.triangle` primitives. The spectrogram uses CPU-generated coloured quads rather than a texture, keeping the pipeline simple.
- **Decoupled audio and display rates**: AudioEngine publishes raw normalised spectrum data at ~21fps (audio callback rate). MetalRenderer applies its own 60fps asymmetric smoothing (fast attack, slow decay) for buttery animation independent of the audio update rate.
- **Direct data reading (no @Published for audio data)**: The MetalRenderer holds a weak reference to AudioEngine and reads `spectrumData`/`waveformData`/`dbFloor`/`dbCeiling` directly. These are NOT `@Published` — this eliminates unnecessary SwiftUI re-render cycles per second. Both run on the main thread (CADisplayLink on iOS), so no locking is needed. The dB labels refresh via the 0.5s FPS timer. MetalRenderer maintains its own `displayPeaks` array — AudioEngine does not provide peak data.
- **Circular buffer for spectrogram**: Avoids array shifting overhead. Write index advances every 3rd frame (~20fps), read wraps around.
- **Auto-leveling over fixed range**: The display adapts to the current signal level rather than mapping a fixed dB range, ensuring responsive visuals in any environment from quiet rooms to concerts.
- **Exponential spectral tilt for music mode**: Commercial music has dramatically more energy in bass than treble. In music mode, an exponential dB boost is applied above 200Hz (`rate * octaves^power`), ramping up aggressively toward 20kHz. Bass below 200Hz is untouched. This makes the full spectrum visually active without distorting the natural bass response. Parameters: `musicTiltRate=5.0`, `musicTiltPower=1.4`.
- **Single persistent engine**: One `AVAudioEngine` instance (`let`, never recreated) for the entire app lifetime. Recreating engines mid-lifecycle causes 0 Hz formats and RPC timeouts.
- **Connect ALL nodes before engine.start()**: `playerNode` and `musicMixer` are attached AND connected before `engine.start()`. Connecting after start permanently breaks playerNode with an uncatchable ObjC exception ("player started when in a disconnected state"). This is the single most important architectural rule. `engine.prepare()` is called before `engine.start()`.
- **Nodes never disconnected**: Idle connected nodes pass silence at zero CPU cost (confirmed by AudioKit source). Disconnecting and reconnecting nodes causes crashes. The full graph stays wired at all times.
- **`.playAndRecord` + `.defaultToSpeaker`** on device; **`.playback`** on simulator (`#if targetEnvironment(simulator)`). The category is set once and never changed. Mic quality/AGC is identical between `.record` and `.playAndRecord` when both use `.default` mode.
- **Tap swapping for source switching**: `installTap`/`removeTap` are safe while the engine is running (Apple-documented). Source switching only swaps taps — nodes stay connected.
- **Load music library once**: The library is scanned once on first access and cached. Rescanning under different audio session states gives inconsistent results.
- **DRM-aware music library**: Three-tier filtering: (1) `assetURL != nil` rejects cloud-only tracks, (2) `hasProtectedAsset` (iOS 9.2+) rejects DRM-protected tracks, (3) `.movpkg` URL extension rejects Apple Music cached streaming packages — these appear local (`cloud=false`, `protected=false`) but `AVAudioFile` can't read them. Since 2024, all iTunes Store purchases are DRM-free, so tracks passing all three checks are reliably playable.

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
│   │   └── ContentView.swift          # Root view, source/mode pickers, labels, FPS, -testfile support
│   ├── Audio/
│   │   ├── AudioEngine.swift          # Single persistent AVAudioEngine + vDSP FFT + tap swapping
│   │   └── MusicPlayer.swift          # MPMediaQuery library browsing + hasProtectedAsset DRM filter
│   ├── Models/
│   │   └── SpectrumData.swift         # AudioSource enum, VisualizationMode enum, SpectrumLayout constants
│   ├── Rendering/
│   │   ├── MetalRenderer.swift        # Metal rendering + 60fps smoothing + FPS tracking
│   │   ├── SpectrumMetalView.swift    # UIViewRepresentable wrapping MTKView
│   │   └── Shaders.metal              # Metal vertex/fragment shaders
│   ├── Views/
│   │   ├── MusicBrowserView.swift     # Track list grouped by artist, DRM status, drag-to-close
│   │   └── TransportBarView.swift     # Now-playing bar with play/pause/stop, swipe-up to browse
│   ├── Info.plist                      # NSMicrophoneUsageDescription + NSAppleMusicUsageDescription
│   ├── test_tone.wav                   # Bundled 440Hz+880Hz test tone (3s) for automated testing
│   ├── pink_tone.wav                   # 29-tone pink noise profile (25Hz–16kHz, -3dB/oct) for tilt testing
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
- **Source toggle**: Custom icon buttons (mic.fill / music.note) for switching between mic and music input
- Segmented picker for visualisation mode (Bars/Curve/Circular/Spectrogram)
- **Launch argument parsing**: `-mode <value>`, `-source <value>`, `-testfile <filename>`
- Metal view taking full remaining space
- GeometryReader overlay for **dynamic dB scale labels**, frequency labels, "WAVEFORM" label
- **FPS counter** in top-right corner, updated every 0.5s
- **MusicBrowserView** at bottom when in music mode
- **TransportBarView** when a track is playing
- **Audio hardware alert**: Popup when 0 Hz or 0 input channels detected, asking user to restart phone
- Permission denied state with instructions
- `onChange(of: musicPlayer.isPlaying)` only handles pause/resume — initial play is handled by `playTrack` calling `playFile` directly

### AudioEngine.swift
- `ObservableObject` with non-`@Published` spectrum (128 bands), waveform (512 samples), and adaptive dB range
- **Single persistent engine** (`private let engine = AVAudioEngine()`) — never recreated
- **`start()`**: Configures session, attaches nodes, connects ALL nodes, installs initial tap, prepares, starts engine. Uses `#if targetEnvironment(simulator)` for `.playback` category and music-only mode.
- **`switchSource(to:)`**: Swaps taps only — `removeTap` on old source, `installTap` on new source. Nodes stay connected. On simulator, only music mode is supported.
- **`playFile(url:)`**: Opens file, schedules on playerNode, calls `playerNode.play()`. Does NOT reconnect — existing connection handles format conversion.
- **Format validation**: Checks `sampleRate > 0` and `channelCount > 0` before `installTap`
- **`audioHardwareBroken`**: Published flag triggers UI alert when hardware is in bad state
- **Debug logging**: Comprehensive `alog()` function writes to Documents/spectrum.log and console. Covers all user actions, state transitions, and engine events.
- FFT pipeline: Hanning window → `vDSP_ctoz` → `vDSP_fft_zrip` → `vDSP_zvmags` → `vDSP_vdbcon`
- **FFT normalisation**: `4/N²` (one-sided power spectrum correction)
- **Static gain boost**: Optional dB offset (`staticGainDB`) applied post-FFT for simulator testing with quiet audio. Set via `-gain` launch argument.
- Logarithmic frequency band mapping: 20Hz–20kHz across 128 bands
- **Exponential spectral tilt** (music mode only): Boosts frequencies above 200Hz using `rate * octaves^power` curve. Bass untouched, treble boosted aggressively to compensate for music's steep HF rolloff.
- **Auto-leveling**: 40dB window, ceiling [-60, 0] dB with 5dB headroom

### MusicPlayer.swift
- `ObservableObject` managing music library access and playback state
- Queries `MPMediaQuery.songs()`, three-tier filter: `assetURL != nil` + `hasProtectedAsset == false` + URL extension is not `.movpkg`
- **Loads library once** — `requestAccessAndLoad()` guarded by `libraryLoaded`
- Groups tracks by artist, sorted alphabetically

### SpectrumData.swift
- `AudioSource` enum: `.mic`, `.music`
- `VisualizationMode` enum: `.bars`, `.curve`, `.circular`, `.spectrogram`
- `SpectrumLayout` with shared NDC coordinate constants and screen-coordinate conversion helpers

### MusicBrowserView.swift
- Track list grouped by artist with playing indicator (cyan speaker icon)
- Drag handle header with close button; drag-to-dismiss gesture
- Empty states: library access required, no eligible tracks (with DRM explanation), loading spinner

### TransportBarView.swift
- Now-playing bar: track name, play/pause button, stop button
- Swipe-up gesture to show browser

### MetalRenderer.swift
- `MTKViewDelegate` driving 60fps rendering
- **60fps asymmetric smoothing**: fast attack (lerp 0.35), slow decay (lerp 0.12)
- **60fps peak tracking**: peaks rise instantly, decay at 0.006/frame (~3.5 seconds full fall)
- Pre-allocates 200K-vertex Metal buffer, single draw call per frame
- Four modes: Bars, Curve, Circular, Spectrogram + waveform trace + grid lines

### SpectrumMetalView.swift
- `UIViewRepresentable` wrapping `MTKView`
- Shared `Coordinator` enables FPS readback from MetalRenderer

### Shaders.metal
- Simple vertex pass-through shader (position + colour)
- Non-packed `float2`/`float4` matching Swift's SIMD alignment (32-byte stride)

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
| Music Spectral Tilt | Rate 5.0 dB/oct, power 1.4, ref 200Hz (above only) |
| Spectrogram Depth | 128 frames (~20fps update rate) |
| Max Vertices | 200,000 |
| Audio Session (device) | `.playAndRecord` + `.defaultToSpeaker`, `.default` mode |
| Audio Session (simulator) | `.playback`, `.default` mode |

## Launch Arguments

| Argument | Description | Example |
|----------|-------------|---------|
| `-mode <value>` | Set initial visualisation mode: `bars`, `curve`, `circular`, `spectrogram` | `-mode spectrogram` |
| `-source <value>` | Set initial audio source: `mic`, `music` | `-source music` |
| `-testfile <name>` | Play a bundled audio file directly (skips music browser) | `-testfile test_tone.wav` |
| `-gain <dB>` | Apply static dB boost to FFT output (for simulator testing with quiet audio) | `-gain 50` |

## Testing

### Simulator Testing

Music playback can be tested in the simulator using the bundled test tones. Use `-gain 50` to boost quiet simulator audio to exercise the full visualisation:

```bash
xcrun simctl terminate booted com.pwilliams.Spectrum
xcrun simctl launch booted com.pwilliams.Spectrum -- -testfile pink_tone.wav -mode bars -gain 50
sleep 5
xcrun simctl io booted screenshot /tmp/screenshot.png
```

Two bundled test files:
- `test_tone.wav` — 440Hz + 880Hz sine waves (3s), for verifying FFT peaks
- `pink_tone.wav` — 29 tones at 1/3-octave intervals (25Hz–16kHz) with -3dB/octave rolloff, for testing spectral tilt compensation

The simulator uses `.playback` category and skips mic input. All four visualisation modes work with test files. Note: a clean build is required after adding new WAV files — incremental builds may not copy resources.

Note: Mic mode and source switching cannot be tested on the simulator — the audio daemon lacks mic hardware.

### Unit Tests

```bash
xcodebuild -project Spectrum.xcodeproj -scheme Spectrum \
  -destination 'platform=iOS Simulator,name=iPhone 16' test \
  CODE_SIGNING_ALLOWED=NO
```

46 tests across three suites covering FFT logic, colour functions, and layout constants.

### Device Testing

Device testing is required for:
- Mic input and visualisation
- Source switching (mic → music → play → mic cycle)
- Music library browsing with DRM filtering
- Playing actual purchased/imported tracks

### Approach to Debugging Audio Issues

**Research before iterating.** Audio engine issues are extremely difficult to debug through trial-and-error because:
- Each failed attempt can corrupt the phone's audio subsystem (requiring reboot)
- `engine.connect()` and `engine.disconnect()` have undocumented side effects
- ObjC exceptions from CoreAudio cannot be caught by Swift `do/catch`
- The simulator has different audio behaviour from real hardware

When hitting an audio issue, the process should be:
1. Add comprehensive logging (the `alog()` function writes to Documents/spectrum.log)
2. Capture the exact error and state from device logs
3. Research the specific error on Apple Developer Forums, AudioKit issues, and Stack Overflow
4. Design the fix based on documented behaviour, not guessing
5. Test in the simulator first (where possible)
6. Only deploy to device when confident

## Build

```bash
xcodebuild -project Spectrum.xcodeproj -scheme Spectrum \
  -destination 'generic/platform=iOS' build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

## Frameworks Used

- **Metal** + **MetalKit**: GPU-accelerated rendering
- **AVFoundation**: Audio capture (AVAudioEngine) and music file playback (AVAudioPlayerNode)
- **Accelerate**: vDSP FFT and signal processing
- **MediaPlayer**: MPMediaQuery for music library access and DRM filtering
- **SwiftUI**: UI framework

## Future Roadmap

- **Fundamental frequency detection / instrument tuner**: Identify the dominant pitch (e.g. autocorrelation or cepstral analysis on the FFT output) and display the nearest musical note with cents offset.
- **Beat detection / BPM counter**: Detect rhythmic onsets via energy flux in the low-frequency bands, track inter-beat intervals, and display beats per minute.

## Known Gotchas

### Audio Engine (Critical — Read Before Modifying)

- **NEVER connect nodes after engine.start()**: Calling `engine.connect()` on a running engine stops it silently and permanently marks the playerNode as "disconnected". The only reliable sequence is: attach → connect → prepare → start. This was discovered through extensive debugging and confirmed by AudioKit issue #2527.
- **NEVER disconnect nodes**: `engine.disconnectNodeOutput()` permanently breaks the node. Leave idle connections in place — they pass silence at zero cost. This is how AudioKit handles it.
- **NEVER recreate AVAudioEngine**: Creating a fresh `AVAudioEngine()` mid-lifecycle causes 0 Hz formats and RPC timeout crashes (especially on the simulator).
- **NEVER change audio session category after startup**: Switching between `.record` and `.playAndRecord` corrupts the hardware format.
- **NEVER reconnect playerNode in playFile()**: The startup connection handles format conversion. Reconnecting while running crashes.
- **Format validation before installTap**: Always check `sampleRate > 0` and `channelCount > 0`. Invalid formats throw ObjC `NSException` that Swift can't catch.
- **engine.connect() stops the engine**: Even on a "running" engine, connecting nodes stops it. If you must connect at runtime (not recommended), check `engine.isRunning` afterward and restart.

### Audio Session

- **Use `.playAndRecord` for both mic and music on device**: No quality penalty — AGC is controlled by mode (`.default`), not category.
- **Use `.playback` on simulator**: `.playAndRecord` fails because there's no mic hardware. Use `#if targetEnvironment(simulator)`.
- **Don't access `engine.inputNode` on simulator**: It triggers the implicit graph creation which fails with no mic hardware.
- **Don't call `setActive(false)`**: Corrupts hardware format.
- **0 Hz format / 0 input channels**: Usually means the audio subsystem needs a phone reboot. The `audioHardwareBroken` flag triggers a UI alert.

### DRM and Music Library

- **`hasProtectedAsset`**: The reliable DRM check. Since 2024, iTunes Store purchases are DRM-free.
- **`.movpkg` = unplayable**: Apple Music subscription tracks cached locally have `assetURL` with `.movpkg` extension, `cloud=false`, and `protected=false` — but `AVAudioFile` cannot open them (error 2003334207). Filter by URL extension.
- **`AVAudioFile(forReading:)` unreliable for DRM**: Gives inconsistent results depending on audio session state. Removed from the scan filter (but useful as a diagnostic tool).
- **Load library once**: Rescanning under different session states causes tracks to appear/disappear.

### Metal/Swift

- **Struct alignment**: Metal `packed_float2`/`packed_float4` are 24 bytes but Swift's `SIMD2<Float>` + `SIMD4<Float>` is 32 bytes. Use non-packed types in Metal.
- **@Published kills FPS**: Don't use `@Published` on properties read by MetalRenderer at 60fps.

### FFT

- **Use `4/N²` normalisation**: Not `1/N²` — the 4× factor accounts for one-sided spectrum.
- **`.default` mode for AGC**: `.measurement` mode disables gain control → very quiet mic input.
- `vDSP_ctoz` stride is in float units, not struct units.
- `vDSP_vdbcon` needs non-zero input — floor to 1e-20.
