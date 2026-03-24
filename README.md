# Spectrum

A real-time audio spectrum analyser for iPhone, built with Metal and Accelerate.

![Spectrum running on iPhone 16 Pro](https://pcwilliams.design/dev/spectrum/spectrum.png)

Captures live microphone audio, performs Fast Fourier Transform analysis, and renders beautiful frequency visualisations at 60fps using the GPU.

## Features

- **Four visualisation modes:**
  - **Bars** — Classic equalizer with gradient-coloured vertical bars
  - **Curve** — Smooth filled waveform with bright outline
  - **Circular** — Radial frequency display emanating from centre
  - **Spectrogram** — Scrolling time-frequency heatmap
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

## Requirements

- iOS 17.0+
- iPhone (portrait only)
- Xcode 16+
- Microphone access

## Setup

1. Open `Spectrum.xcodeproj` in Xcode
2. Select your development team
3. Build and run on a physical iPhone (microphone required)
4. Grant microphone permission when prompted

## How It Works

1. **Audio Capture**: AVAudioEngine taps the microphone input with AGC enabled for maximum sensitivity
2. **Windowing**: A Hanning window is applied to reduce spectral leakage
3. **FFT**: Accelerate's vDSP performs a real-to-complex FFT on 2048 samples
4. **Band Mapping**: FFT bins are mapped to 128 logarithmic frequency bands
5. **Auto-Leveling**: Display range adapts to the current signal (40dB window, instant rise, slow decay)
6. **60fps Smoothing**: Metal renderer interpolates between audio frames with asymmetric lerp for buttery animation
7. **Rendering**: Metal builds and renders up to 200K coloured vertices per frame

## Launch Arguments

For automated simulator testing, the app accepts command-line arguments:

| Argument | Description |
|----------|-------------|
| `-mode bars` | Launch in Bars mode (default) |
| `-mode curve` | Launch in Curve mode |
| `-mode circular` | Launch in Circular mode |
| `-mode spectrogram` | Launch in Spectrogram mode |

```bash
xcrun simctl launch booted com.pwilliams.Spectrum -- -mode spectrogram
```

## Testing

46 unit tests covering FFT band mapping, auto-level range parameters, smoothing, peak tracking, gradient/heatmap colour functions, layout constants, and coordinate conversion. Run with:

```bash
xcodebuild -project Spectrum.xcodeproj -scheme Spectrum \
  -destination 'platform=iOS Simulator,name=iPhone 16' test \
  CODE_SIGNING_ALLOWED=NO
```

## Roadmap

- **Instrument tuner** — Fundamental frequency detection with musical note display and cents offset
- **BPM counter** — Beat detection via low-frequency energy flux with tempo display

## Tech Stack

- **Swift 5** / **SwiftUI**
- **Metal** + **MetalKit** for GPU rendering
- **Accelerate** (vDSP) for FFT signal processing
- **AVFoundation** for audio capture
- Zero external dependencies

## Documentation

See [Architecture](https://pcwilliams.design/dev/spectrum/architecture.html) for interactive diagrams, [Tutorial](https://pcwilliams.design/dev/spectrum/tutorial.html) for the build narrative, and [CLAUDE.md](CLAUDE.md) for the full developer reference.
