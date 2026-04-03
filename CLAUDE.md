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

### Philosophy: Maximise Simulator Coverage Before Device

Device testing is expensive — each iteration requires a build, deploy, and manual interaction. The goal is to catch as many issues as possible in the simulator so that by the time the app runs on a real device, confidence is already high. This means:

1. **Every testable mode and feature should be exercisable from the command line** via launch arguments
2. **Bundled test files** (WAV, JSON, images) should exercise features that normally require live input (microphone, camera, network)
3. **Diagnostic logging** should capture algorithmic decisions so issues can be diagnosed from log output, not just visual inspection
4. **Screenshots are useful but logs are better** — a screenshot shows what happened, a log shows why

### Simulator Testing with Launch Arguments

For apps with multiple modes or views, add **launch argument parsing** so visual testing can be fully automated from the command line — never try to tap simulator UI with AppleScript (it's unreliable). Parse `ProcessInfo.processInfo.arguments` in the root view to accept flags like `-mode <value>`.

**Launch arguments must override persisted settings.** When an app uses `@AppStorage` or `UserDefaults` to remember UI state across launches, the persisted values load automatically. Launch arguments for testing must be applied *after* persistence loads (e.g. in `onAppear`) so they take priority. Without this, a test launch with `-mode bars` might be ignored because `@AppStorage` still holds `spectrogram` from the last manual session. Return optionals from launch-arg parsers (nil = no override) so they only replace the persisted value when explicitly provided.

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

### Bundled Test Files for Hardware-Dependent Features

When a feature depends on hardware input (microphone, GPS, camera), create **bundled test files** that exercise the same code path in the simulator:

- **Audio**: Generate WAV files with Python that produce known inputs — pure tones (440Hz sine), multi-tone sequences (pitch changes every 1.5s), periodic beats (120 BPM kick drum). Bundle them in the app and play via `-testfile <name>` launch argument.
- **Location**: Bundle JSON files with known GPS coordinates for map-based testing.
- **Images**: Bundle sample photos with known EXIF data for photo-processing features.

The key principle: **the DSP / processing pipeline shouldn't know or care whether input comes from hardware or a test file**. If the pipeline works correctly with a known test input in the simulator, it will work with real input on device (barring hardware-specific issues like sample rate differences).

Example of generating a test audio file:

```python
import wave, struct, math
sample_rate = 44100
samples = []
for freq, duration in [(261.63, 1.5), (329.63, 1.5), (440.0, 1.5), (0, 1.0)]:
    for i in range(int(sample_rate * duration)):
        t = i / sample_rate
        value = 0.7 * math.sin(2 * math.pi * freq * t) if freq > 0 else 0
        samples.append(int(value * 32767))
with wave.open('test.wav', 'w') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(sample_rate)
    f.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
```

### Diagnostic Logging for Algorithm Debugging

For complex algorithms (DSP, ML, signal processing), add **structured diagnostic logging** that captures the algorithm's internal decisions — not just the final output. Gate verbose logging behind a launch argument so it's off in normal use but available when debugging.

```swift
// In the engine/service
static var verboseLogging = false

// In the algorithm
if Self.verboseLogging {
    alog("PITCH DBG: acPeak=\(peak) lag=\(lag) freq=\(freq)Hz")
}

// In ContentView onAppear
if args.contains("-pitchlog") { AudioEngine.verboseLogging = true }
```

This pattern proved essential in Spectrum's pitch detection: the algorithm was tuned iteratively by deploying to device, singing test tones, and sending the log output back for analysis. Without the per-frame diagnostic output, it would have been impossible to distinguish between "the autocorrelation found the wrong peak" and "the confidence threshold rejected a valid peak".

**What to log:**
- Algorithm confidence/quality metrics (e.g. autocorrelation peak strength, SNR)
- Which branch/threshold was taken
- Input characteristics (signal level, frequency content)
- State changes (note changed, beat detected, silence entered)

**What NOT to log every frame** (too noisy):
- Raw sample values
- Full array contents
- Unchanged state

Use change-only logging for display state (only log when the displayed value changes) and periodic logging for diagnostics (every Nth frame).

### Reading Logs from Simulator and Device

```bash
# Simulator: read the app's Documents directory
CONTAINER=$(xcrun simctl get_app_container booted com.bundle.id data)
cat "$CONTAINER/Documents/app.log"

# Clear log before a test run
> "$CONTAINER/Documents/app.log"

# Device: build, install, launch, and retrieve logs automatically via CLI.
# The device is "Paul's iPhone 16 Pro" (970899A3-153F-5EC2-834F-BAFFCDF2560B).
# When connected, the full build-deploy-test cycle can run without Xcode GUI:

# Build for device (code signing required — no CODE_SIGNING_ALLOWED=NO)
xcodebuild -project ProjectName.xcodeproj -scheme ProjectName \
  -destination "platform=iOS,name=Paul's iPhone 16 Pro" build

# Install and launch with launch arguments
xcrun devicectl device install app --device 970899A3-153F-5EC2-834F-BAFFCDF2560B \
  path/to/ProjectName.app
xcrun devicectl device process launch --device 970899A3-153F-5EC2-834F-BAFFCDF2560B \
  com.pwilliams.ProjectName -- -mode bars -bpmlog

# Copy log file from device container
xcrun devicectl device copy from --device 970899A3-153F-5EC2-834F-BAFFCDF2560B \
  --source Documents/app.log --domain-type appDataContainer \
  --domain-identifier com.pwilliams.ProjectName --destination /tmp/app.log
```

### Performance Testing in the DSP/Rendering Pipeline

For real-time processing (audio, video, rendering), measure execution time to verify the pipeline completes within its time budget:

```swift
let start = CACurrentMediaTime()
// ... processing ...
let elapsed = CACurrentMediaTime() - start
dspTimingSum += elapsed
dspTimingCount += 1
if elapsed > dspTimingMax { dspTimingMax = elapsed }
if dspTimingCount % 100 == 0 {
    let avgMs = (dspTimingSum / Double(dspTimingCount)) * 1000
    let maxMs = dspTimingMax * 1000
    let budgetMs = Double(bufferSize) / Double(sampleRate) * 1000
    alog("DSP PERF: avg=\(avgMs)ms, max=\(maxMs)ms, budget=\(budgetMs)ms")
}
```

The budget is the time between callbacks (e.g. 2048 samples at 44.1kHz = 46.4ms). If average processing exceeds ~50% of the budget, optimise before adding features. If max processing occasionally exceeds the budget, investigate the spike.

### Simulator vs Device Differences

The simulator does NOT replicate everything. Always test on device for:

- **Microphone input** (simulator has no mic hardware)
- **GPS / CoreLocation** (simulator uses simulated locations)
- **Audio session behaviour** (`.playAndRecord` fails on simulator — use `.playback` with `#if targetEnvironment(simulator)`)
- **Sample rates** (simulator often uses 44.1kHz, device may use 48kHz — parameterise, don't hardcode)
- **Real-world signal characteristics** (voice has harmonics, vibrato, breath noise that pure test tones lack — algorithms that work on sine waves may fail on voice)
- **Hardware format edge cases** (0 Hz sample rate, 0 input channels — detect and alert the user)

The ideal workflow: build and iterate in the simulator until unit tests pass and test files produce correct output, then deploy to device for final validation with real-world input.

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

Real-time audio spectrum analyser for iPhone. Captures microphone input or plays local music files, performs FFT analysis using Apple's Accelerate framework (vDSP), and renders six GPU-accelerated visualisation modes via Metal at 60fps with silky-smooth animation, plus a 3D surface waterfall mode with Metal depth buffer and directional lighting. Includes fundamental frequency detection (tuning overlay with note name and cents offset) and BPM detection with beat flash visualisation.

For shared conventions (tech stack, architecture patterns, testing strategy, simulator workflow, diagnostic logging, and common gotchas), see the [parent CLAUDE.md](../CLAUDE.md).

## Architecture

### Data Flow

```
Mic mode:   Microphone → AVAudioEngine (inputNode tap) → vDSP FFT → Log bands → Auto-level → Normalise
Music mode: AVAudioFile → AVAudioPlayerNode → musicMixer (tap) → vDSP FFT → Log bands → Auto-level → Normalise
                                                                       ↓              ↓                    ↓
                                                                Autocorrelation    Spectral flux    DispatchQueue.main → SwiftUI
                                                                (pitch detect)    (BPM detect)              ↓
                                                                       ↓              ↓        MTKView → MetalRenderer (60fps smoothing
                                                                  detectedNote    detectedBPM    + peak tracking + beat flash) → GPU
                                                                  detectedCents   beatFlash
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
- **Single vertex pipeline for 2D modes**: The four 2D visualisation modes (bars, curve, circular, spectrogram) use the same Metal vertex/fragment pipeline with `.triangle` primitives. The spectrogram uses CPU-generated coloured quads rather than a texture, keeping the pipeline simple.
- **Decoupled audio and display rates**: AudioEngine publishes raw normalised spectrum data at ~21fps (audio callback rate). MetalRenderer applies its own 60fps asymmetric smoothing (fast attack, slow decay) for buttery animation independent of the audio update rate.
- **Direct data reading (no @Published for audio data)**: The MetalRenderer holds a weak reference to AudioEngine and reads `spectrumData`/`waveformData`/`dbFloor`/`dbCeiling` directly. These are NOT `@Published` — this eliminates unnecessary SwiftUI re-render cycles per second. Both run on the main thread (CADisplayLink on iOS), so no locking is needed. The dB labels refresh via the 0.5s FPS timer. MetalRenderer maintains its own `displayPeaks` array — AudioEngine does not provide peak data.
- **Circular buffer for spectrogram**: Avoids array shifting overhead. Write index advances every 3rd frame (~20fps), read wraps around.
- **Auto-leveling over fixed range**: The display adapts to the current signal level rather than mapping a fixed dB range, ensuring responsive visuals in any environment from quiet rooms to concerts.
- **Exponential spectral tilt for music mode**: Commercial music has dramatically more energy in bass than treble. In music mode, an exponential dB boost is applied above 200Hz (`rate * octaves^power`), ramping up aggressively toward 20kHz. Bass below 200Hz is untouched. This makes the full spectrum visually active without distorting the natural bass response. Parameters: `musicTiltRate=5.0`, `musicTiltPower=1.4`.
- **Single persistent engine**: One `AVAudioEngine` instance (`let`, never recreated) for the entire app lifetime. Recreating engines mid-lifecycle causes 0 Hz formats and RPC timeouts.
- **Connect ALL nodes before engine.start()**: `playerNode` and `musicMixer` are attached AND connected before `engine.start()`. Connecting after start permanently breaks playerNode with an uncatchable ObjC exception ("player started when in a disconnected state"). This is the single most important architectural rule. `engine.prepare()` is called before `engine.start()`.
- **Nodes never disconnected**: Idle connected nodes pass silence at zero CPU cost (confirmed by AudioKit source). Disconnecting and reconnecting nodes causes crashes. The full graph stays wired at all times.
- **`.playAndRecord` + `.defaultToSpeaker` + `.allowBluetooth` + `.allowBluetoothA2DP`** on device; **`.playback`** on simulator (`#if targetEnvironment(simulator)`). The category is set once and never changed. `.defaultToSpeaker` prevents earpiece routing when no Bluetooth is connected; `.allowBluetooth`/`.allowBluetoothA2DP` respect connected Bluetooth headphones for high-quality stereo output. Mic quality/AGC is identical between `.record` and `.playAndRecord` when both use `.default` mode.
- **Tap swapping for source switching**: `installTap`/`removeTap` are safe while the engine is running (Apple-documented). Source switching only swaps taps — nodes stay connected.
- **Load music library once**: The library is scanned once on first access and cached. Rescanning under different audio session states gives inconsistent results.
- **DRM-aware music library**: Three-tier filtering: (1) `assetURL != nil` rejects cloud-only tracks, (2) `hasProtectedAsset` (iOS 9.2+) rejects DRM-protected tracks, (3) `.movpkg` URL extension rejects Apple Music cached streaming packages — these appear local (`cloud=false`, `protected=false`) but `AVAudioFile` can't read them. Since 2024, all iTunes Store purchases are DRM-free, so tracks passing all three checks are reliably playable.
- **Time-domain autocorrelation for pitch detection**: Computes autocorrelation directly from audio samples using `vDSP_dotpr` with Pearson normalisation (normalise each lag by overlapping segment energies to eliminate short-lag bias). Searches musical range (65Hz--1000Hz) for the first peak above 0.75 confidence. Parabolic interpolation for sub-Hz accuracy. Median-filtered over 3 frames with pitch-jump detection (>1 semitone flushes buffer). Miss counter clears display after ~250ms of silence.
- **Autocorrelation-based BPM detection (Scheirer/Ellis)**: A separate 1024-point FFT runs at hop=1024 (~43fps onset rate), computing broadband spectral flux (all frequencies, not just bass — captures hi-hats and snares). Flux is log-compressed (`log(1+10*x)`) to normalise dynamic range, then stored in a 340-frame circular buffer (~8 seconds). Before autocorrelation: detrend (subtract 2-second local mean to remove slow energy variations), half-wave rectify, normalise to unit variance. Autocorrelate via `vDSP_dotpr` across 90–160 BPM lag range. Harmonic check at half-lag (>40% threshold, constrained to display range) resolves octave ambiguity. Parabolic interpolation for sub-lag accuracy (~1 BPM). Auto-halve above 160, auto-double below 70 for display range. Temporal smoothing (median of 3 estimates, 2/3 consensus within ±5 BPM). Silence gate via raw flux variance (<0.5 suppresses). Tempo-change detection: 3 consecutive estimates diverging >10 BPM from the locked value flushes the entire buffer and restarts, handling track changes and section transitions without requiring the user to toggle BPM off/on. Tested on device across 16 commercial tracks: 14/16 within ±2 BPM (87.5% accuracy), including Missing (EBTG, 123→124), BBC News24 (120→120), Get Lucky (116→116), Sledgehammer (96→97), Relax (115→115), Video Killed the Radio Star (132→131).
- **Beat flash at 60fps**: MetalRenderer reads beatFlash/beatFlashCounter from AudioEngine and applies additive RGB brightness boost to bar/curve vertex colours. Counter decremented per render frame.
- **Separate 3D pipeline for surface mode**: A second `MTLRenderPipelineState` with 3D vertex struct (`SIMD3` position + `SIMD3` normal + `SIMD4` color = 48 bytes), MVP uniform buffer, depth stencil state, and directional lighting fragment shader. The 2D pipeline is untouched -- separating avoids inflating the 2D vertex struct for ~100K vertices per frame. `.surfaceLines` adds bright ridgeline outlines (1.3x colour boost) tracing the frequency curve at each time slice, drawn as thin quads along the top edge of the mesh.
- **Aspect-ratio-adaptive camera**: Two fixed camera positions (normal and compact) blended smoothly by interpolating between aspect ratio 0.55 and 0.75. This avoids a jarring jump when the music browser animates in/out and handles three view sizes (mic, transport bar, full browser).
- **Adaptive Y scale for surface peaks**: Peak height scales from 0.6 (compact view) to 1.2 (full portrait view) based on aspect ratio, making peaks more dramatic when there's vertical room.
- **Unified music header bar**: TransportBarView was removed. A single header line serves as both "Music Library" title and now-playing display. Tapping toggles the browser. Transport controls (play/pause/stop) appear inline when a track is loaded.
- **@AppStorage for persistent UI state**: Mode, source, tuning, BPM toggles persist across launches. Launch arguments override for simulator testing.
- **Long-press tooltips on icon buttons**: All toolbar buttons show label text on 0.4s long-press, auto-dismiss after 1.5s.

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
│   │   └── ContentView.swift          # Root view, icon-based mode picker, tuning/BPM toggle buttons with long-press tooltips, @AppStorage persistence, labels, FPS, -testfile support
│   ├── Audio/
│   │   ├── AudioEngine.swift          # Single persistent AVAudioEngine + vDSP FFT + tap swapping + pitch detection (autocorrelation) + BPM detection (autocorrelation of spectral flux)
│   │   └── MusicPlayer.swift          # MPMediaQuery library browsing + hasProtectedAsset DRM filter
│   ├── Models/
│   │   └── SpectrumData.swift         # AudioSource enum, VisualizationMode enum, SpectrumLayout constants
│   ├── Rendering/
│   │   ├── MetalRenderer.swift        # Metal rendering + 60fps smoothing + FPS tracking + 3D surface pipeline with depth buffer, MVP matrices, directional lighting, aspect-ratio-adaptive camera
│   │   ├── SpectrumMetalView.swift    # UIViewRepresentable wrapping MTKView
│   │   └── Shaders.metal              # Metal vertex/fragment shaders + 3D surface_vertex/surface_fragment pair with normals and uniforms
│   ├── Views/
│   │   └── MusicBrowserView.swift     # Track list grouped by artist, DRM status, drag-to-close
│   ├── Info.plist                      # NSMicrophoneUsageDescription + NSAppleMusicUsageDescription
│   ├── test_tone.wav                   # Bundled 440Hz+880Hz test tone (3s) for automated testing
│   ├── pink_tone.wav                   # 29-tone pink noise profile (25Hz–16kHz, -3dB/oct) for tilt testing
│   ├── beat_120bpm.wav                 # Bundled 120 BPM kick drum test file (5s) for BPM detection testing
│   ├── pitch_test.wav                  # Bundled C4-E4-G4-A4-C5-silence (8.5s) for pitch tracking testing
│   ├── syncopated_123bpm.wav           # Bundled syncopated D&B-style 123 BPM pattern (8s) for BPM testing
│   ├── house_128bpm.wav                # Bundled 128 BPM 4-on-the-floor house pattern (10s) for BPM testing
│   ├── dnb_174bpm.wav                  # Bundled 174 BPM D&B with syncopated kicks + hi-hats (10s)
│   ├── intro_then_beat_123bpm.wav      # 5s quiet intro + 123 BPM beat (15s) for transition testing
│   ├── paul_85bpm.wav                  # 10s extract from real 85 BPM track for complex-signal BPM testing
│   └── Assets.xcassets/
└── SpectrumTests/                      # PBXFileSystemSynchronizedRootGroup (auto-discovered)
    ├── AudioEngineTests.swift          # 32 tests: log band mapping, smoothing, peak tracking, auto-level, frequencyToNote
    ├── MetalRendererTests.swift        # 15 tests: gradient colour, heatmap colour
    └── SpectrumDataTests.swift         # 10 tests: enums, layout constants, NDC conversion
```

## Files

### SpectrumApp.swift
Standard SwiftUI @main entry point with WindowGroup containing ContentView.

### ContentView.swift
- **Source toggle**: Custom icon buttons (mic.fill / music.note) for switching between mic and music input
- Icon-based mode picker (chart.bar.fill, waveform.path, circle.circle, square.grid.3x3.fill, plus surface button)
- **Tuning/BPM toggle buttons** with long-press tooltips
- **@AppStorage persistence** for mode, source, tuning, BPM
- **Launch argument parsing**: `-mode <value>`, `-source <value>`, `-testfile <filename>`, `-tuning`, `-bpm`, `-pitchlog`, `-bpmlog`, `-gain <dB>`
- Metal view taking full remaining space
- GeometryReader overlay for **dynamic dB scale labels**, frequency labels, "WAVEFORM" label
- **FPS counter** in top-right corner, updated every 0.5s
- **Unified musicHeaderBar**: single header line serving as both "Music Library" title and now-playing display; tap toggles browser visibility; inline transport controls (play/pause/stop) appear when a track is loaded
- **MusicBrowserView** at bottom when in music mode
- **Audio hardware alert**: Popup when 0 Hz or 0 input channels detected, asking user to restart phone
- Permission denied state with instructions
- **Tuning overlay**: note name + cents offset displayed on right side (bars/curve/surface/surface+ modes)
- **BPM overlay**: BPM value + beat indicator dot displayed on right side (bars/curve/surface/surface+ modes)
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
- **Pitch detection**: Time-domain autocorrelation via `vDSP_dotpr` with Pearson normalisation. First-peak search (65Hz--1000Hz) with 0.75 confidence threshold. `frequencyToNote()` static method converts Hz to note name + cents offset. Median smoothing over 3 detections with pitch-jump flushing and miss-count clearing. Verbose logging via `-pitchlog` launch argument. Properties: `detectedNote`, `detectedCents`.
- **BPM detection**: Autocorrelation of the onset strength signal. A separate 1024-point FFT runs at hop=1024 (~43fps onset rate), computing broadband spectral flux (not just bass). Flux is log-compressed (`log(1+10*x)`) before storing in a 340-frame circular buffer (~8s). Before autocorrelation: detrend (subtract 2s local mean), half-wave rectify, normalise to unit variance. Autocorrelate via `vDSP_dotpr` across 90–200 BPM lag range. Harmonic check at half-lag (>50% threshold) resolves octave ambiguity. Parabolic interpolation for sub-lag accuracy. Auto-double below 90 BPM, auto-halve above 200 BPM. Temporal smoothing (median of 3 estimates, 2/3 consensus within ±5 BPM). Silence gate via raw flux variance threshold. Verbose logging via `-bpmlog`. Properties: `detectedBPM`, `beatFlash`, `beatFlashCounter`.
- **DSP performance tracking**: Monitors pitch and BPM computation time.

### MusicPlayer.swift
- `ObservableObject` managing music library access and playback state
- Queries `MPMediaQuery.songs()`, three-tier filter: `assetURL != nil` + `hasProtectedAsset == false` + URL extension is not `.movpkg`
- **Loads library once** — `requestAccessAndLoad()` guarded by `libraryLoaded`
- Groups tracks by artist, sorted alphabetically

### SpectrumData.swift
- `AudioSource` enum: `.mic`, `.music`
- `VisualizationMode` enum: `.bars`, `.curve`, `.circular`, `.spectrogram`, `.surface`, `.surfaceLines`
- `SpectrumLayout` with shared NDC coordinate constants and screen-coordinate conversion helpers

### MusicBrowserView.swift
- Track list grouped by artist with playing indicator (cyan speaker icon)
- Drag handle header with close button; drag-to-dismiss gesture
- Empty states: library access required, no eligible tracks (with DRM explanation), loading spinner

### MetalRenderer.swift
- `MTKViewDelegate` driving 60fps rendering
- **60fps asymmetric smoothing**: fast attack (lerp 0.35), slow decay (lerp 0.12)
- **60fps peak tracking**: peaks rise instantly, decay at 0.006/frame (~3.5 seconds full fall)
- Pre-allocates 200K-vertex Metal buffer, single draw call per frame
- Six modes: Bars, Curve, Circular, Spectrogram, Surface, Surface+ + waveform trace + grid lines
- **3D surface pipeline**: Separate vertex/fragment shaders with depth buffer, MVP matrices, directional lighting, and aspect-ratio-adaptive camera
- **Beat flash brightness boost** on bars/curve modes: reads `beatFlash`/`beatFlashCounter` from AudioEngine, applies additive RGB boost to vertex colours

### SpectrumMetalView.swift
- `UIViewRepresentable` wrapping `MTKView`
- Shared `Coordinator` enables FPS readback from MetalRenderer

### Shaders.metal
- Simple vertex pass-through shader (position + colour) for 2D modes
- Non-packed `float2`/`float4` matching Swift's SIMD alignment (32-byte stride)
- 3D `surface_vertex`/`surface_fragment` pair with `SIMD3` normals and MVP uniforms for directional lighting

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
| Audio Session (device) | `.playAndRecord` + `.defaultToSpeaker` + `.allowBluetooth` + `.allowBluetoothA2DP`, `.default` mode |
| Audio Session (simulator) | `.playback`, `.default` mode |
| Pitch Detection Range | 65Hz--1000Hz (C2--B5) |
| Pitch Smoothing | Median filter over 3 detections |
| Pitch Confidence Threshold | Pearson-normalised autocorrelation peak > 0.75 |
| BPM Range | 80--160 BPM search, display 70--160 (auto-halve above 160, auto-double below 70) |
| BPM Onset Rate | ~43fps (hop=1024 with 1024-point onset FFT, separate from display FFT) |
| BPM Flux History | ~8 seconds (340 frames at ~43fps) |
| BPM Onset Signal | Broadband spectral flux, log-compressed: log(1 + 10*flux) |
| BPM Preprocessing | Detrend (subtract 2s local mean), normalise to unit variance |
| BPM Confidence | Autocorrelation peak / zero-lag AC > 15% |
| BPM Tempo Change | 3 consecutive estimates diverging >10 BPM from locked value flushes buffer |
| BPM Smoothing | Median of 3 estimates, 2/3 must agree within ±5 BPM |
| BPM Silence Gate | Raw flux variance < 0.5 suppresses display |
| BPM Harmonic Check | If AC at lag/2 > 40% of AC at lag (and result ≤160 BPM), prefer double tempo |
| Beat Flash Duration | 6 frames (~100ms at 60fps) |
| Surface History Depth | 60 rows (~3s at 20fps) |
| Surface Vertex Count | ~46K solid + ~46K ridgelines for surfaceLines mode (48 bytes each) |
| Surface Camera Normal | azimuth 40, elevation 34, distance 6.5 |
| Surface Camera Compact | azimuth 40, elevation 32, distance 3.5 |
| Surface FOV | 50 degrees |
| Surface Light | (-0.5, 1.0, 0.3) normalised, ambient 0.5 |
| Surface Y Scale | 0.6 (compact) to 1.2 (full view), aspect-adaptive |

## Launch Arguments

| Argument | Description | Example |
|----------|-------------|---------|
| `-mode <value>` | Set initial visualisation mode: `bars`, `curve`, `circular`, `spectrogram`, `surface`, `surface+`/`surfacelines` | `-mode surface+` |
| `-source <value>` | Set initial audio source: `mic`, `music` | `-source music` |
| `-testfile <name>` | Play a bundled audio file directly (skips music browser) | `-testfile test_tone.wav` |
| `-gain <dB>` | Apply static dB boost to FFT output (for simulator testing with quiet audio) | `-gain 50` |
| `-tuning` | Enable tuning overlay | `-tuning` |
| `-bpm` | Enable BPM overlay | `-bpm` |
| `-pitchlog` | Enable verbose pitch detection logging to spectrum.log | `-pitchlog` |
| `-bpmlog` | Enable verbose BPM detection logging to spectrum.log | `-bpmlog` |
| `-autoplay <title>` | Auto-play a track from music library matching title substring | `-autoplay Missing` |

## Testing

### Simulator Testing

Music playback can be tested in the simulator using the bundled test tones. Use `-gain 50` to boost quiet simulator audio to exercise the full visualisation:

```bash
xcrun simctl terminate booted com.pwilliams.Spectrum
xcrun simctl launch booted com.pwilliams.Spectrum -- -testfile pink_tone.wav -mode bars -gain 50
sleep 5
xcrun simctl io booted screenshot /tmp/screenshot.png
```

Three bundled test files:
- `test_tone.wav` — 440Hz + 880Hz sine waves (3s), for verifying FFT peaks
- `pink_tone.wav` — 29 tones at 1/3-octave intervals (25Hz--16kHz) with -3dB/octave rolloff, for testing spectral tilt compensation
- `beat_120bpm.wav` — 120 BPM kick drum pattern (5s), for testing BPM detection with straight beats
- `house_128bpm.wav` — 128 BPM 4-on-the-floor with offbeat hi-hats and snare (10s)
- `dnb_174bpm.wav` — 174 BPM D&B with syncopated kicks, snare, and steady hi-hats (10s)
- `intro_then_beat_123bpm.wav` — 5s quiet pad intro then 123 BPM syncopated beat with hi-hats (15s total)
- `syncopated_123bpm.wav` — 123 BPM D&B-style syncopated kick pattern only (8s)
- `pitch_test.wav` — C4-E4-G4-A4-C5-silence (8.5s), for testing pitch tracking through note changes

BPM detection testing:

```bash
xcrun simctl terminate booted com.pwilliams.Spectrum
xcrun simctl launch booted com.pwilliams.Spectrum -- -testfile beat_120bpm.wav -mode bars -gain 50 -bpm
sleep 5
xcrun simctl io booted screenshot /tmp/screenshot.png
```

The simulator uses `.playback` category and skips mic input. All six visualisation modes work with test files. Note: a clean build is required after adding new WAV files — incremental builds may not copy resources.

Note: Mic mode and source switching cannot be tested on the simulator — the audio daemon lacks mic hardware.

### Unit Tests

```bash
xcodebuild -project Spectrum.xcodeproj -scheme Spectrum \
  -destination 'platform=iOS Simulator,name=iPhone 16' test \
  CODE_SIGNING_ALLOWED=NO
```

67 tests across three suites covering FFT logic, pitch detection, colour functions, and layout constants.

### Device Testing

Device testing is required for:
- Mic input and visualisation
- Source switching (mic → music → play → mic cycle)
- Music library browsing with DRM filtering
- Playing actual purchased/imported tracks
- Mic-based tuning (guitar, voice)
- BPM detection with real music

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

- **Audio recording / export**: Record the analysed audio alongside the visualisation.
- **Custom colour themes**: User-selectable gradient palettes for the visualisation modes.

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
- **Depth buffer format must match across pipelines**: Both 2D and 3D pipeline descriptors must declare `depthAttachmentPixelFormat = .depth32Float` to match MTKView, even though the 2D pipeline doesn't use depth testing.
- **Track switching race condition**: Stopping a track triggers its scheduleFile completion handler asynchronously, which calls musicPlayer.stop(). Solved with a `playbackGeneration` counter -- incremented on every stop/play, checked in the scheduleFile completion handler so stale completions are silently ignored.
- **Simulator vs device aspect ratios differ**: Safe area insets (Dynamic Island, home indicator) change the Metal view's aspect ratio on device. Always test camera positions on device, not just simulator.

### FFT

- **Use `4/N²` normalisation**: Not `1/N²` — the 4× factor accounts for one-sided spectrum.
- **`.default` mode for AGC**: `.measurement` mode disables gain control → very quiet mic input.
- `vDSP_ctoz` stride is in float units, not struct units.
- `vDSP_vdbcon` needs non-zero input — floor to 1e-20.
- **Time-domain autocorrelation, not frequency-domain**: An earlier approach using IFFT of the power spectrum (Wiener-Khinchin) worked for pure tones but failed for voice — squaring the power spectrum exaggerates harmonics, causing octave errors and instability. The current approach computes autocorrelation directly from audio samples via `vDSP_dotpr`, with Pearson normalisation per lag to eliminate short-lag bias. This is robust for voice, instruments, and pure tones.
- **Pearson normalisation is essential**: Dividing by total energy (standard normalisation) inflates short-lag autocorrelation because nearly all samples overlap. Normalising each lag by `sqrt(energyLeft * energyRight)` of the overlapping segments bounds the result to [-1, 1] correctly at every lag. Without this, background noise at lag 24-25 produces peaks of 0.6-0.85 that overwhelm the detector.
- **Start pitch search at 1000Hz, not 2000Hz**: The lag range 24-48 (at 48kHz) is dominated by noise artifacts regardless of normalisation. Musical fundamentals rarely exceed 1000Hz (B5), so starting the search at lag=48 avoids the noisy region entirely.
- **BPM: autocorrelate the flux signal, not onset timestamps**: An earlier approach tracked inter-onset intervals (IOI) from spectral flux peaks. This worked for straight 4/4 beats but failed completely on syncopated music (drum & bass, electronic) where kicks hit on off-beat subdivisions — the IOI histogram scattered across many wrong tempos. The current approach autocorrelates the continuous spectral flux signal itself (Scheirer 1998 / Ellis 2007), which finds periodicity in the overall rhythmic pattern even when individual onsets are syncopated.
- **BPM: use separate onset FFTs, not the display FFT**: The display FFT runs at ~10fps (4410-sample callbacks). At 10fps, integer lags give only ~15 BPM resolution — too coarse. A separate 1024-point FFT at hop=1024 gives ~43fps native onset rate with ~1.5 BPM per lag step. Combined with parabolic interpolation, this achieves ~1 BPM accuracy. An earlier approach used 4x linear upsampling of the 10fps signal — this improved lag resolution but added no information, and the underlying signal was too sparse for reliable autocorrelation.
- **BPM: temporal smoothing prevents display flicker**: The autocorrelation peak can briefly jump to a sub-harmonic (e.g. half-tempo) during syncopated passages. A smoothing buffer of 3 estimates with 2/3 consensus within ±5 BPM prevents these transient blips from reaching the display.
- **BPM: tempo-change detection flushes stale data**: If the autocorrelation consistently finds a new tempo (3 estimates diverging >10 BPM from locked value), the entire flux history, smoothing buffer, and onset state are flushed. Without this, a wrong initial lock persists for 8+ seconds because old flux data in the circular buffer keeps reinforcing the wrong answer. This mirrors the pitch-jump detection in the tuner.
- **BPM: harmonic check must respect display range**: The half-lag check (for octave doubling) must only fire if the resulting BPM is ≤160. Without this constraint, a correct 124 BPM detection at lag 19 gets incorrectly doubled to lag 9 (267 BPM → auto-halved to 133), producing wrong results.
