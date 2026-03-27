# Spectrum

A real-time audio spectrum analyser for iPhone, built with Metal and Accelerate.

![Spectrum running on iPhone 16 Pro](https://pcwilliams.design/dev/spectrum/spectrum.png)

Captures live microphone audio or plays music from your library, performs Fast Fourier Transform analysis, and renders beautiful frequency visualisations at 60fps using the GPU.

## Features

- **Four visualisation modes:**
  - **Bars** — Classic equalizer with gradient-coloured vertical bars
  - **Curve** — Smooth filled waveform with bright outline
  - **Circular** — Radial frequency display emanating from centre
  - **Spectrogram** — Scrolling time-frequency heatmap
- **Dual audio source:**
  - **Microphone** — Live real-time analysis of ambient sound
  - **Music library** — Play purchased/imported tracks with real-time spectrum analysis
- **Real-time FFT** via Apple's Accelerate framework (vDSP)
- **GPU rendering** via Metal for smooth 60fps visuals
- **Silky-smooth animation** — asymmetric 60fps smoothing (fast attack, slow decay) decoupled from audio callback rate
- **Auto-leveling** — display adapts to ambient signal level, responsive in any environment
- **Logarithmic frequency scale** (20Hz-20kHz) matching human pitch perception
- **Peak hold indicators** that decay smoothly over ~3.5 seconds
- **Dynamic dB scale** and **frequency labels** — dB range updates with auto-leveling
- **Live waveform display** showing time-domain audio signal
- **FPS counter** in top-right corner
- **Colour gradient** from cool (bass) to hot (treble): blue-cyan-green-yellow-red
- **Spectral tilt compensation** — exponential treble boost in music mode brings the full 20Hz–20kHz range to life
- **DRM-aware library browser** — three-tier filtering removes cloud-only, DRM-protected, and Apple Music cached streaming tracks (`.movpkg`)

## Requirements

- iOS 17.0+
- iPhone (portrait only)
- Xcode 16+
- Microphone access (for mic mode)
- Media & Apple Music access (for music mode)

## Setup

1. Open `Spectrum.xcodeproj` in Xcode
2. Select your development team
3. Build and run on a physical iPhone (microphone required for mic mode)
4. Grant microphone permission when prompted
5. For music mode, grant Media & Apple Music permission

## How It Works

1. **Audio Capture**: AVAudioEngine taps the microphone input (with AGC) or plays music via AVAudioPlayerNode
2. **Windowing**: A Hanning window is applied to reduce spectral leakage
3. **FFT**: Accelerate's vDSP performs a real-to-complex FFT on 2048 samples
4. **Band Mapping**: FFT bins are mapped to 128 logarithmic frequency bands
5. **Auto-Leveling**: Display range adapts to the current signal (40dB window, instant rise, slow decay)
6. **Spectral Tilt** (music mode): Exponential treble boost compensates for the steep high-frequency rolloff of commercial music
7. **60fps Smoothing**: Metal renderer interpolates between audio frames with asymmetric lerp for buttery animation
8. **Rendering**: Metal builds and renders up to 200K coloured vertices per frame

## Music Mode

Tap the music note icon to browse your music library. Only purchased and imported tracks are shown — unplayable tracks are removed by three checks: no asset URL (cloud-only), `hasProtectedAsset` (DRM-protected), and `.movpkg` URL extension (Apple Music cached streaming packages that look local but can't be decoded).

The app uses a single persistent audio engine with all nodes connected at startup. Switching between mic and music mode swaps audio taps — the engine never stops. Transport controls (play/pause/stop) appear at the bottom when playing.

## Launch Arguments

For automated testing, the app accepts command-line arguments:

| Argument | Description |
|----------|-------------|
| `-mode bars` | Launch in Bars mode (default) |
| `-mode curve` | Launch in Curve mode |
| `-mode circular` | Launch in Circular mode |
| `-mode spectrogram` | Launch in Spectrogram mode |
| `-source mic` | Launch in Mic mode (default) |
| `-source music` | Launch in Music mode |
| `-testfile <name>` | Play a bundled audio file (skips library browser) |
| `-gain <dB>` | Static dB boost for simulator testing with quiet audio |

```bash
xcrun simctl launch booted com.pwilliams.Spectrum -- -testfile test_tone.wav -mode spectrogram
```

## Testing

46 unit tests covering FFT band mapping, auto-level range parameters, smoothing, peak tracking, gradient/heatmap colour functions, layout constants, and coordinate conversion. Run with:

```bash
xcodebuild -project Spectrum.xcodeproj -scheme Spectrum \
  -destination 'platform=iOS Simulator,name=iPhone 16' test \
  CODE_SIGNING_ALLOWED=NO
```

Music playback is tested in the simulator using a bundled 440Hz+880Hz test tone (`test_tone.wav`). Mic input and source switching require a physical device.

## Roadmap

- **Instrument tuner** — Fundamental frequency detection with musical note display and cents offset
- **BPM counter** — Beat detection via low-frequency energy flux with tempo display

## Tech Stack

- **Swift 5** / **SwiftUI**
- **Metal** + **MetalKit** for GPU rendering
- **Accelerate** (vDSP) for FFT signal processing
- **AVFoundation** for audio capture and music playback
- **MediaPlayer** for music library browsing
- Zero external dependencies

## Documentation

See [Architecture](https://pcwilliams.design/dev/spectrum/architecture.html) for interactive diagrams, [Tutorial](https://pcwilliams.design/dev/spectrum/tutorial.html) for the build narrative, and [CLAUDE.md](CLAUDE.md) for the full developer reference.
