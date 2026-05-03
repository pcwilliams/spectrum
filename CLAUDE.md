
# iOS Development Conventions

Native iOS apps built with Swift and SwiftUI. No storyboards, no external dependencies.

## Tech Stack

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
├── CLAUDE.md                    # Developer reference
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

Smaller projects (e.g. Where) may flatten this into fewer files — simplicity over ceremony.

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

**Launch arguments must override persisted settings.** When an app uses `@AppStorage` or `UserDefaults`, launch arguments must be applied *after* persistence loads (e.g. in `onAppear`) so they take priority. Return optionals from launch-arg parsers (nil = no override).

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

This pattern was established in ShiftingSands and adopted in Spectrum. Every new project with multiple visual states should support this from the start.

### Bundled Test Files for Hardware-Dependent Features

When a feature depends on hardware input (microphone, GPS, camera), create **bundled test files** that exercise the same code path in the simulator:

- **Audio**: Generate WAV files with Python — pure tones (440Hz sine), multi-tone sequences, periodic beats. Bundle and play via `-testfile <name>` launch argument.
- **Location**: Bundle JSON files with known GPS coordinates for map-based testing.
- **Images**: Bundle sample photos with known EXIF data for photo-processing features.

The DSP/processing pipeline shouldn't know or care whether input comes from hardware or a test file.

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

For complex algorithms (DSP, ML, signal processing), add **structured diagnostic logging** gated behind a launch argument:

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

**What to log:** algorithm confidence metrics, which branch/threshold was taken, input characteristics, state changes.

**What NOT to log every frame:** raw sample values, full array contents, unchanged state.

Use change-only logging for display state and periodic logging for diagnostics (every Nth frame).

### Reading Logs from Simulator and Device

```bash
# Simulator: read the app's Documents directory
CONTAINER=$(xcrun simctl get_app_container booted com.bundle.id data)
cat "$CONTAINER/Documents/app.log"

# Clear log before a test run
> "$CONTAINER/Documents/app.log"

# Device: stream logs via:
xcrun devicectl device syslog --device <udid>
```

### Performance Testing in the DSP/Rendering Pipeline

For real-time processing, measure execution time against the time budget:

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

Budget = time between callbacks (e.g. 2048 samples at 44.1kHz = 46.4ms). If average exceeds ~50% of budget, optimise before adding features.

### Simulator vs Device Differences

The simulator does NOT replicate everything. Always test on device for:

- **Microphone input** (simulator has no mic hardware)
- **GPS / CoreLocation** (simulator uses simulated locations)
- **Audio session behaviour** (`.playAndRecord` fails on simulator — use `.playback` with `#if targetEnvironment(simulator)`)
- **Sample rates** (simulator often uses 44.1kHz, device may use 48kHz — parameterise, don't hardcode)
- **Real-world signal characteristics** (voice has harmonics, vibrato, breath noise that pure test tones lack)
- **Hardware format edge cases** (0 Hz sample rate, 0 input channels — detect and alert the user)

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

### GPU rendering — 3D surfaces, terrain, waterfalls, landscapes

For any feature that renders a 2D value field as a lit, animated 3D surface (frequency × time, day × hour, X × Y × any-Z, ridgelines, terrain), use the **`3dsurface`** skill. It captures the canonical Metal pipeline, mesh, camera math, lighting, smoothing, and animation patterns extracted from HeartMap and Spectrum — including the non-obvious decisions (fixed colour scales, smoothing-decoupled-from-colour, face normals, locked camera) that make a surface read as *stunning* rather than just correct.

### Apple Health / HealthKit

For any feature that reads heart rate, steps, workouts, sleep, or other Apple Health data, use the **`healthkit`** skill. It captures the actor-based service shape, authorization (single combined prompt; read perms aren't queryable), the optimized fetch patterns (per-month queries, server-side bucketing via `HKStatisticsCollectionQuery + .cumulativeSum`, parallel `async let`), the three-phase load (disk-cache seed → current-month refresh → background stream), the empty-result fallback to demo data, infinity-safe JSON disk caching, workout activity type → label/symbol mapping, and entitlements/provisioning gotchas (wildcard profiles can't carry HealthKit).

For *clinical interpretation* of that data — fitness scores, resting heart rate calculations, AHA active-minute zones, age-adjusted scoring, evidence-based step thresholds — use the **`health`** skill. It's platform-agnostic (useful in web dashboards too) and always carries an explicit "not medical advice" disclaimer.

## App Icons

Generated programmatically using **Python/Pillow** — not designed in a graphics tool. Three variants at 1024x1024:

- **Standard** (light mode)
- **Dark** (dark mode)
- **Tinted** (greyscale for tinted mode)

Referenced in `Contents.json` with `luminosity` appearance variants. Use `Image.new("RGB", ...)` not `"RGBA"` — iOS strips alpha for app icons, causing compositing artefacts with semi-transparent overlays.

## Documentation

Each project includes four living documents that must be kept up to date:

### CLAUDE.md (developer reference)

Must be updated whenever: a file, model, view, or service is added/removed; an architectural decision is made; a new API is integrated; a non-obvious bug is fixed; build configuration or project structure changes.

This is the single source of truth for project context. A future session should be able to read CLAUDE.md and understand the entire project without exploring the codebase.

### README.md (user-facing)

Must be updated whenever: features are added/changed/removed; setup instructions change; project structure changes significantly; screenshots become outdated.

### architecture.html (architecture diagrams)

Interactive Mermaid.js diagrams. Must be updated whenever: view hierarchy changes; data flow changes; new major subsystems are added.

Use `graph TD` for readability. Load Mermaid.js from CDN. Apply the shared dark theme with CSS custom properties and project-appropriate accent colours.

### tutorial.html (build narrative)

A step-by-step record of how the app was built. Must be updated whenever: a significant new feature is added; a major refactor is made; an interesting problem is solved through iterative prompting.

**Prompt tone:** Use collaborative language — "Could we try...", "How about...", "I'd love it if..." rather than imperatives. Use "I'm seeing..." for problems rather than assertive declarations.

### Formatting conventions

- Plain Markdown in `.md` files (no inline HTML except README badges). Images use `![alt](src)` syntax, not `<img>` tags
- HTML docs use a shared dark theme with CSS custom properties and Mermaid.js loaded from CDN
- HTML docs include a hero screenshot in a phone-frame wrapper (black background, rounded corners, drop shadow) below the title/badges

## Common Gotchas

- **Keychain: always delete before add** to avoid `errSecDuplicateItem`
- **SwiftUI `.refreshable` cancels structured concurrency** — wrap network calls in an unstructured `Task`
- **Wikimedia geosearch caps at 10,000m radius** — clamp before sending
- **Wikipedia disambiguation pages** — filter out articles where extract contains "may refer to"

---


# 3D Surface Rendering — Battle-Tested Patterns

Both HeartMap (`heart-rate × day × hour`) and Spectrum (`amplitude × frequency × time`) independently converged on essentially the same 3D-surface pipeline. This skill captures that pipeline as a reusable starting point — the shader pair, vertex layout, camera math, mesh construction, animation discipline, and the small handful of decisions that make a surface *stunning* rather than merely correct.

The two reference implementations live in:

- `~/appledev/heartmap/HeartMap/Rendering/{HeartMapRenderer.swift,Shaders.metal}`
- `~/appledev/spectrum/Spectrum/Rendering/{MetalRenderer.swift,Shaders.metal}`

Read those if any pattern below is unclear — they're the ground truth.

## When to use

A 3D surface is the right tool when you have a 2D grid of values that varies in two independent dimensions (time × something, day × hour, X × Y) and you want the user to *feel* the shape of the data — peaks, valleys, ridges, isolated spikes. It is not the right tool for sparse data, categorical data, or anything that would read better as a chart, table, or flat heatmap.

## The shader pair (canonical)

Both projects use identical Metal shaders for the surface pipeline. Use this verbatim — it is the settled answer:

```metal
#include <metal_stdlib>
using namespace metal;

// Must match Swift's SurfaceVertex layout exactly:
// SIMD3<Float> + SIMD3<Float> + SIMD4<Float> = 48 bytes stride.
struct SurfaceVertexIn {
    float3 position;
    float3 normal;
    float4 color;
};

// Must match Swift's SurfaceUniforms layout:
// float4x4 (64) + float4 (16) = 80 bytes.
struct SurfaceUniforms {
    float4x4 mvpMatrix;
    float4 lightDirectionAndAmbient;  // xyz = light dir, w = ambient
};

struct SurfaceVertexOut {
    float4 position [[position]];
    float4 color;
    float3 normal;
};

vertex SurfaceVertexOut surface_vertex(
    const device SurfaceVertexIn* vertices [[buffer(0)]],
    constant SurfaceUniforms& uniforms [[buffer(1)]],
    uint vid [[vertex_id]])
{
    SurfaceVertexOut out;
    out.position = uniforms.mvpMatrix * float4(vertices[vid].position, 1.0);
    out.color = vertices[vid].color;
    out.normal = vertices[vid].normal;
    return out;
}

fragment float4 surface_fragment(
    SurfaceVertexOut in [[stage_in]],
    constant SurfaceUniforms& uniforms [[buffer(1)]])
{
    float3 N = normalize(in.normal);
    float3 L = uniforms.lightDirectionAndAmbient.xyz;
    float ambient = uniforms.lightDirectionAndAmbient.w;
    float NdotL = max(dot(N, L), 0.0);
    float lighting = ambient + (1.0 - ambient) * NdotL;
    return float4(in.color.rgb * lighting, in.color.a);
}
```

The CPU does all the interesting work — building vertices, computing normals, picking colours, animating heights. The shader is intentionally minimal: transform, light, draw.

## Swift mirror structs (exact byte layout)

```swift
import simd

/// Must match Metal's SurfaceVertexIn (48 bytes: 3·float3-aligned-as-float4 + float4).
struct SurfaceVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

/// Must match Metal's SurfaceUniforms (80 bytes).
struct SurfaceUniforms {
    var mvpMatrix: simd_float4x4
    var lightDirectionAndAmbient: SIMD4<Float>  // xyz = normalised dir, w = ambient
}
```

**Alignment rule (the bug everyone hits once):** Use **non-packed** `float3`/`float4` in Metal so the strides match Swift's `SIMD3<Float>` (16-byte aligned) and `SIMD4<Float>` (16-byte aligned). `packed_float3`/`packed_float4` give 4-byte alignment and a different stride — which produces silently garbled rendering, not a crash. If the surface looks scrambled, this is the first thing to check.

## Pipeline & MTKView setup

```swift
mtkView.device = device
mtkView.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1.0)
mtkView.preferredFramesPerSecond = 60
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.colorPixelFormat = .bgra8Unorm

let desc = MTLRenderPipelineDescriptor()
desc.vertexFunction = library.makeFunction(name: "surface_vertex")
desc.fragmentFunction = library.makeFunction(name: "surface_fragment")
desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
desc.colorAttachments[0].isBlendingEnabled = true
desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
desc.depthAttachmentPixelFormat = .depth32Float

let depthDesc = MTLDepthStencilDescriptor()
depthDesc.depthCompareFunction = .less
depthDesc.isDepthWriteEnabled = true
let depthStencilState = device.makeDepthStencilState(descriptor: depthDesc)!
```

When encoding the draw call:

```swift
encoder.setRenderPipelineState(pipelineState)
encoder.setDepthStencilState(depthStencilState)
encoder.setFrontFacing(.counterClockwise)
encoder.setCullMode(.none)              // surfaces are viewed from above; back faces visible at edges
encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
```

**`.cullMode(.none)`** is deliberate: the camera looks down at ~30° elevation, so the underside of folded ridges occasionally faces forward. Culling them gives ugly black flickers at peaks. The performance hit at these triangle counts is invisible.

**Depth format on every pipeline.** If your project has more than one pipeline (e.g. a 2D pass plus this 3D one), every pipeline descriptor must declare `depthAttachmentPixelFormat = .depth32Float` to match the MTKView, even if the 2D pipeline doesn't use depth testing. Mismatch is a crash on first draw.

## Camera math (proj * view, no model)

The reference apps use a standard right-handed look-at + perspective matrix and pre-multiply on the CPU each frame:

```swift
private func buildMVPMatrix() -> simd_float4x4 {
    let azRad = azimuth * .pi / 180.0
    let elRad = elevation * .pi / 180.0
    let camX = distance * cos(elRad) * sin(azRad)
    let camY = distance * sin(elRad)
    let camZ = distance * cos(elRad) * cos(azRad)
    let eye = SIMD3<Float>(camX, camY, camZ)
    let target = SIMD3<Float>(0, heightScale * 0.35, 0)  // look slightly above the floor
    let up = SIMD3<Float>(0, 1, 0)
    let view = lookAtMatrix(eye: eye, target: target, up: up)
    let proj = perspectiveMatrix(fovY: 50.0 * .pi / 180.0,
                                  aspect: max(0.2, aspectRatio),
                                  near: 0.1, far: 100.0)
    return proj * view
}

private func lookAtMatrix(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    var m = matrix_identity_float4x4
    m[0][0] = s.x; m[1][0] = s.y; m[2][0] = s.z
    m[0][1] = u.x; m[1][1] = u.y; m[2][1] = u.z
    m[0][2] = -f.x; m[1][2] = -f.y; m[2][2] = -f.z
    m[3][0] = -simd_dot(s, eye)
    m[3][1] = -simd_dot(u, eye)
    m[3][2] = simd_dot(f, eye)
    return m
}

private func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1.0 / tan(fovY / 2.0)
    let x = y / aspect
    let z = far / (near - far)
    var m = simd_float4x4(0)
    m[0][0] = x
    m[1][1] = y
    m[2][2] = z
    m[2][3] = -1.0
    m[3][2] = z * near
    return m
}
```

### Default camera framing

| Parameter | Value | Why |
|-----------|-------|-----|
| Azimuth | **40°** | Three-quarters view — both grid axes legible, ridges read as ridges. Pure 0° or 90° loses depth cues. |
| Elevation | **30°** (HeartMap) / **34°** (Spectrum) | Low enough to feel the topology; high enough to see all rows without back rows occluding front rows. |
| Distance | **5.2** (HeartMap) / **6.5** (Spectrum) | Tuned per-app so peaks at the corners don't clip the viewport. Push back if you see clipping. |
| FOV (Y) | **50°** | Slightly wider than the classic 45° — gives breathing room around the corners on phone aspect ratios. |
| Target Y | `heightScale * 0.35` | Look slightly above the floor so the surface centres in the frame, not the base plane. |

### Aspect-adaptive camera (Spectrum's twist)

When the surrounding UI animates in/out (a music browser, a slide-up panel) the Metal view's aspect ratio changes mid-animation. A hard threshold causes a jarring camera jump. The fix is to interpolate between two preset camera positions across an aspect-ratio range:

```swift
let t = max(0, min(1, (aspectRatio - 0.55) / (0.75 - 0.55)))
let azimuth = azNormal + t * (azCompact - azNormal)
let elevation = elNormal + t * (elCompact - elNormal)
let distance = dNormal + t * (dCompact - dNormal)
```

Use this *only* when the view actually resizes during the session. For a fixed-layout surface, lock the camera and lock it hard.

### Camera locked vs. orbit

Both apps eventually disabled their camera orbit. A slow ambient orbit looks beautiful in isolation but breaks any SwiftUI overlay that needs to project through the same MVP (axis labels, peak connectors, hover targets). A locked camera lets the SwiftUI side compute screen positions from a stable matrix once per layout pass instead of once per frame. **Default to locked.** If you want movement, animate the data, not the camera.

## Building the mesh

The unit cube is `[-1.05, 1.05]` on X and Z, `[0, heightScale]` on Y. The 1.05 (instead of 1.0) is so axis lines and tick marks at the edges aren't lost to the camera frustum. `heightScale = 1.1` lifts peaks slightly above the cube top so workout/loud-note ridges have presence against perspective foreshortening.

Two triangles per cell, **face normals** (not vertex normals — the surfaces are intentionally faceted; vertex normals smooth out the geometric story you're trying to tell):

```swift
for d in 0..<(rows - 1) {
    let z0 = zFor(d), z1 = zFor(d + 1)
    for b in 0..<(cols - 1) {
        let x0 = xFor(b), x1 = xFor(b + 1)

        let p00 = SIMD3<Float>(x0, h00 * heightScale, z0)
        let p01 = SIMD3<Float>(x1, h01 * heightScale, z0)
        let p10 = SIMD3<Float>(x0, h10 * heightScale, z1)
        let p11 = SIMD3<Float>(x1, h11 * heightScale, z1)

        // Face normal — same for both triangles of the cell so the lighting
        // is per-quad, not per-triangle. Reads as a faceted surface, not a
        // jagged one.
        let edge1 = p01 - p00
        let edge2 = p10 - p00
        var normal = simd_cross(edge2, edge1)
        let len = simd_length(normal)
        if len > 0 { normal /= len } else { normal = SIMD3<Float>(0, 1, 0) }

        // Triangle 1 + Triangle 2 sharing the (p01, p10) edge.
        vertices.append(SurfaceVertex(position: p00, normal: normal, color: c00))
        vertices.append(SurfaceVertex(position: p01, normal: normal, color: c01))
        vertices.append(SurfaceVertex(position: p10, normal: normal, color: c10))
        vertices.append(SurfaceVertex(position: p01, normal: normal, color: c01))
        vertices.append(SurfaceVertex(position: p11, normal: normal, color: c11))
        vertices.append(SurfaceVertex(position: p10, normal: normal, color: c10))
    }
}
```

**Cross-product order matters.** HeartMap uses `simd_cross(edge2, edge1)`; Spectrum uses `simd_cross(edge1, edge2)`. They produce opposite normals — and combined with each app's light direction, they happen to look right. If your surface comes out lit *darker* on top than underneath, swap the cross-product order.

## Animation: target vs. display fields

A surface that snaps to new data looks cheap. A surface that smoothly morphs feels alive. The pattern in both apps:

```swift
private var targetHeights: [[Float]] = []      // what we want to be
private var displayHeights: [[Float]] = []     // what we are right now
private var morphLerp: Float = 0.09            // ~330 ms half-life

// In draw():
for d in 0..<displayHeights.count {
    for b in 0..<displayHeights[d].count {
        let cur = displayHeights[d][b]
        let tgt = targetHeights[d][b]
        displayHeights[d][b] = cur + (tgt - cur) * morphLerp
    }
}
```

When new data arrives, set `targetHeights` only. Each frame interpolates one step. With `lerp = 0.09` at 60fps, ~330ms half-life — slow enough for the eye to track, fast enough not to feel sluggish.

For data sets where dimensions can change (different month lengths, different history depths), **pad to a fixed maximum** so the per-cell lerp always has matching slots. HeartMap pads every month to 31 day-rows; missing days have their data mask cleared but the slot exists.

### Decoupling colour from smoothed height

The single most important "stunning" trick from HeartMap. If you smooth the height field for visual flow *and* derive colour from the same smoothed field, brief peaks lose their colour:

```
A 150 bpm spike flanked by 60 bpm rest, after a [1,2,1]/4 blur,
becomes ~0.28 height — which maps to cyan-green on a fixed scale.
But 150 bpm should be red-orange.
```

Fix: keep two parallel fields. `displayHeights` is smoothed and drives mesh Y. `displayColorHeights` is **raw pre-smooth** and drives vertex colour. Both lerp toward their targets in lock-step so transitions stay coherent. Result: the geometry flows gently, but a 150 bpm bucket renders unmistakably 150-bpm-coloured.

This is a pattern, not a bug. Use it whenever colour carries meaning that smoothing would dilute.

## Smoothing — separable [1,2,1]/4, mask-aware

A two-pass separable blur is the right amount of smoothing — enough to flow, not so much that signal is lost. Two passes (horizontal then vertical) of `[1,2,1]/4` is equivalent to a 3×3 Gaussian-ish kernel for a fraction of the multiplies.

The non-obvious requirement: **mask-aware**. Empty cells must stay at the floor and must not pull populated neighbours down. The data/no-data boundary should remain crisp, not feathered:

```swift
static func smooth(heights: [[Float]], mask: [[Bool]]) -> [[Float]] {
    let rows = heights.count, cols = heights[0].count
    var pass1 = heights
    for d in 0..<rows {
        for b in 1..<(cols - 1) where mask[d][b] {
            let center = heights[d][b]
            let l = mask[d][b - 1] ? heights[d][b - 1] : center
            let r = mask[d][b + 1] ? heights[d][b + 1] : center
            pass1[d][b] = (l + 2 * center + r) * 0.25
        }
    }
    var pass2 = pass1
    for d in 1..<(rows - 1) {
        for b in 0..<cols where mask[d][b] {
            let center = pass1[d][b]
            let up = mask[d - 1][b] ? pass1[d - 1][b] : center
            let dn = mask[d + 1][b] ? pass1[d + 1][b] : center
            pass2[d][b] = (up + 2 * center + dn) * 0.25
        }
    }
    return pass2
}
```

When a neighbour is empty, fall back to the centre value rather than zero — that's what keeps the boundary crisp instead of producing a gentle slope down to nothing.

## Colour and lighting choices

### Lighting

Directional N·L plus an ambient floor — that's the entire fragment shader. Tunable parameters:

| Parameter | HeartMap | Spectrum | Why |
|-----------|----------|----------|-----|
| Light direction | `normalize(-0.4, 1.0, 0.35)` | `normalize(-0.5, 1.0, 0.3)` | Above-left, slightly forward. Casts visible shadow on the right of every ridge — reads as depth. |
| Ambient | **0.55** (HeartMap) / **0.5** (Spectrum) | — | High ambient floor (≥0.5) keeps shadowed faces visible. Below 0.4 and dark valleys become unreadable. |

Both apps use **face normals**, not vertex normals — see the mesh-building section. Vertex normals smooth out the very ridges you're trying to celebrate.

### Colour ramps

Two valid strategies, pick based on what your data means:

**1. Position-based (Spectrum's curve/surface modes).** Colour reflects *where* on the X axis the vertex is — frequency band → blue→cyan→green→yellow→red. Five-stop linear ramp over `t ∈ [0, 1]`. Good when X has its own meaning the user should track (which frequency? which day?).

**2. Height-based with a fixed scale (HeartMap).** Colour reflects *what* the value is, anchored to a domain-meaningful scale (40–190 bpm, 0–4000 steps). Critically: **don't auto-scale per frame**. A 170 bpm peak in January should look the same shade of red as a 170 bpm peak in May. Auto-scaled colour ramps lie — they make every dataset look equally dramatic. A fixed scale makes the slider a real comparison tool.

### The "no-data floor" pattern

If your grid can have empty cells, give them a **distinct colour** — not just "low value". HeartMap uses deep navy `SIMD4(0.04, 0.06, 0.18, 1)`, visually separate from the active gradient's resting blue. Combined with mask-aware smoothing keeping the boundary crisp, the result reads as "no reading" rather than "low reading", which matters for medical/meaningful data.

### Ridgelines (Spectrum's `surfaceLines` mode)

A wireframe-over-solid look that makes individual time slices easier to track. Draw a second set of thin quads along the top edge of each row, offset slightly above the surface (`+0.002` Y), with **1.3× colour boost** so they pop against the lit surface beneath:

```swift
let bc = Self.gradientColor(at: t) * SIMD4(1.3, 1.3, 1.3, 1.0)
// Then draw thin quads at (x, surfaceY + 0.002, z) along each row.
```

The `1.3×` deliberately exceeds 1.0, clamping bright at the GPU. Reads as "lit edges" without needing a separate emissive shader.

## Performance discipline

The whole point of GPU rendering is staying off the main thread's critical path. The two reference apps sustain 60fps with these rules:

- **Pre-allocate one large MTLBuffer at init** sized for the worst case (HeartMap: 200K vertices × 48 bytes ≈ 9.6 MB; Spectrum surface: 70K vertices). Never allocate buffers per-frame.
- **One draw call per frame.** Build all geometry — surface mesh, ridgelines, axis lines, tick marks — into the same buffer and issue one `drawPrimitives`. Multiple draw calls are not free at this scale.
- **Reserve vertex array capacity once.** `vertices.reserveCapacity((rows-1) * (cols-1) * 6 + 64)` — the `+ 64` covers axis decorations.
- **Don't `@Published` data the renderer reads at 60fps.** SwiftUI re-renders the entire view tree on every `@Published` change. The renderer should hold a `weak` reference to its data source and read directly. UI labels that need the same data can refresh from a 0.5s timer.
- **Per-cell work is the budget.** A 31×48 grid is 1488 cells × 6 vertices × 48 bytes = 428 KB to upload per frame. Trivial. A 128×128 grid is 6.3 MB — still fine. Past that, switch to instanced rendering or a vertex shader that reads heights from a texture.

## SwiftUI integration

Wrap the `MTKView` in a `UIViewRepresentable`. Don't try to layer SwiftUI views *inside* the Metal view — instead, overlay them on top and project through the renderer's MVP:

```swift
// In the renderer, expose a project() helper:
func project(_ point: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
    let mvp = buildMVPMatrix()
    let clip = mvp * SIMD4<Float>(point.x, point.y, point.z, 1)
    guard clip.w > 0.0001 else { return nil }
    let ndcX = clip.x / clip.w, ndcY = clip.y / clip.w
    let x = (CGFloat(ndcX) * 0.5 + 0.5) * viewSize.width
    let y = (1.0 - (CGFloat(ndcY) * 0.5 + 0.5)) * viewSize.height
    return CGPoint(x: x, y: y)
}

// Also expose a height-readback for spline endpoints landing on the surface:
func surfaceYAt(day d: Int, bucket b: Int) -> Float? { ... }
func surfaceTargetYAt(day d: Int, bucket b: Int) -> Float? { ... }  // FINAL value, not lerping
```

Now SwiftUI can place axis labels, tooltips, peak markers, or animated spline connectors at exact 3D points. **Spline tips that need to land on a peak across animations should read `surfaceTargetYAt` (the final value), not `surfaceYAt` (the currently-lerping value)** — otherwise mode/data changes leave the spline tip stuck near the floor while the mesh catches up.

Animated geometry on top of the surface — like HeartMap's peak connectors — works well as custom SwiftUI `Shape`s with `animatableData = AnimatablePair<Double, Double>(day, hour)`. SwiftUI interpolates the fractional cell coordinates; each intermediate `path(in:)` bilinearly samples the height field. The result is a marker that glides smoothly across the mesh instead of teleporting.

## Common gotchas

| Symptom | Cause | Fix |
|---------|-------|-----|
| Garbled/scrambled rendering on first run | Vertex struct stride mismatch | Use non-packed `float3`/`float4` in Metal so stride matches Swift's SIMD alignment |
| Crash on first draw with depth error | Pipeline missing `depthAttachmentPixelFormat` | Set `.depth32Float` on **every** pipeline descriptor that shares the MTKView |
| Bright peaks render as wrong colour | Smoothing-then-colouring | Decouple: smoothed field for geometry, raw field for colour |
| Hard pop on month/mode change | No interpolation | `targetHeights` + `displayHeights` + per-frame lerp at ~0.09 |
| Spline overlay teleports across mesh | Reading `displayHeights` mid-morph | Read `targetHeights` for final-position queries |
| 30fps instead of 60fps when data updates | `@Published` triggering view-tree rebuild | Renderer holds `weak` data ref, reads directly; refresh non-render UI from timer |
| Camera jumps when surrounding UI animates | Hard threshold on aspect ratio | Interpolate camera params across an aspect range |
| Black flickers at peak edges | `.cullMode(.back)` killing forward-facing back faces | Use `.cullMode(.none)` |
| SwiftUI overlay labels jitter | Camera orbiting | Lock camera; project once per layout, not per frame |
| Surface lit darker on top than underneath | Cross-product order vs. light direction | Swap `cross(edge1, edge2)` ↔ `cross(edge2, edge1)` |
| Data/no-data boundary feathers into fog | Naive smoothing crosses the mask | Mask-aware blur — empty neighbours fall back to centre value |
| Test for an unusual peak shape only fails on device | Simulator vs device aspect ratios differ | Always test camera framing on a real device, not just the simulator |

## Stunning vs. just-working — the small handful of decisions that mattered

If a future surface is going to feel *compelling*, not just functional, these are the calls that made the difference in the reference apps:

1. **Fixed colour scales, not auto-scaled.** A 170 BPM peak today should look identical to a 170 BPM peak six months ago. Auto-scale lies.
2. **Decouple smoothing from colour.** Smooth the geometry; colour the raw value. Brief peaks keep their identity.
3. **Distinct "no-data" colour.** Don't conflate "no reading" with "low reading" — give it its own deep, calm shade.
4. **Mask-aware smoothing.** Crisp data/no-data edges read as honest. Feathered edges read as wrong.
5. **Face normals, not vertex normals.** The faceting is the visual story.
6. **Lock the camera by default.** Surface drama comes from the data, not camera moves. Locked cameras let SwiftUI overlays project cleanly.
7. **High ambient floor (≥0.5).** Shadowed faces must remain visible — undertows of dark unreadable geometry kill the look.
8. **Subtle axis lines + tick marks at the front edge.** Architectural ground-plan aesthetic, not a 3D chart with full wire cube.
9. **Animate transitions, never snap.** ~300ms half-life on `displayHeights → targetHeights` lerp — slow enough to track, fast enough to feel responsive.
10. **One draw call per frame, one MTLBuffer pre-allocated.** Stay 60fps rock-solid; everything else compounds from there.

## Reference implementations

Both apps run on iPhone, both deploy via `xcodebuild`, both have unit-tested smoothing/colour logic. When in doubt:

- **HeartMap** (`~/appledev/heartmap/`) — the height-as-meaning case, with mode crossfade, fixed colour scale, and SwiftUI peak-connector overlays projecting through the renderer's MVP.
- **Spectrum** (`~/appledev/spectrum/`) — the time-streaming case, with circular-buffer history, aspect-adaptive camera, and an optional bright-ridgeline pass.

The accompanying `tutorial.html` files in each project describe the conversational journey that produced these patterns — read those for the *why* behind a non-obvious decision before changing it.

---

# Spectrum - Claude Code Developer Reference

## Overview

Real-time audio spectrum analyser for iPhone. Captures microphone input or plays local music files, performs FFT analysis using Apple's Accelerate framework (vDSP), and renders six GPU-accelerated visualisation modes via Metal at 60fps with silky-smooth animation, plus a 3D surface waterfall mode with Metal depth buffer and directional lighting. Includes fundamental frequency detection (tuning overlay with note name and cents offset) and BPM detection with beat flash visualisation.

Shared iOS conventions (tech stack, MVVM architecture, simulator launch-arg testing, diagnostic logging) and the canonical Metal 3D-surface pipeline live in the `ios` and `3dsurface` skills referenced above.

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

The bundled `run_phone.sh` does the build → install → launch flow in one
step, with proper code-signing (it reads `APPLE_TEAM_ID` / `IPHONE_UDID` /
`IPHONE_BUILD_ID` from `~/appledev/setupenv.sh`). Trailing arguments are
forwarded to the app's launch-arg parser:

```bash
./run_phone.sh                                         # plain launch
./run_phone.sh -mode surface+ -source music            # specific mode/source
./run_phone.sh -autoplay "Missing" -bpm                # play track + BPM overlay
./run_phone.sh -tuning -pitchlog                       # tuner with verbose log
```

If you need to invoke `xcodebuild` manually, use the `id=$IPHONE_BUILD_ID`
+ `-allowProvisioningUpdates` + `DEVELOPMENT_TEAM=$APPLE_TEAM_ID` form —
the bare `name="Paul's iPhone…"` destination silently produces an
*unsigned* `.app` that fails to install with `No code signature found`.

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
