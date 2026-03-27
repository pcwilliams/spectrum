#!/usr/bin/env python3
"""Generate a multi-tone WAV simulating commercial music's spectral profile.

Dense tones (one per 1/3-octave) from 25Hz to 20kHz with -3dB/octave rolloff.
This fills all 128 display bands so the spectral tilt effect is clearly visible.
"""
import wave
import struct
import math

SAMPLE_RATE = 44100
DURATION = 5.0
NUM_SAMPLES = int(SAMPLE_RATE * DURATION)

# Generate 1/3-octave spaced tones from 25Hz to 20kHz
# This gives ~30 tones, filling the spectrum densely
freqs = []
f = 25.0
while f <= 20000:
    freqs.append(f)
    f *= 2 ** (1/3)  # 1/3 octave steps

# -3dB per octave from 25Hz (pink noise profile)
ref_freq = freqs[0]
amplitudes = []
for f in freqs:
    octaves = math.log2(f / ref_freq)
    db_drop = -3.0 * octaves
    amplitudes.append(10 ** (db_drop / 20.0))

print(f"Generating {len(freqs)} tones from {freqs[0]:.0f}Hz to {freqs[-1]:.0f}Hz")
print(f"Amplitude range: {-3 * math.log2(freqs[-1]/ref_freq):+.1f}dB at top")

# Generate summed signal
samples = []
for i in range(NUM_SAMPLES):
    t = i / SAMPLE_RATE
    val = sum(a * math.sin(2 * math.pi * f * t) for f, a in zip(freqs, amplitudes))
    samples.append(val)

# Normalise to 90% of 16-bit range (louder for simulator testing)
peak = max(abs(s) for s in samples)
scale = 0.9 * 32767 / peak
samples = [int(s * scale) for s in samples]

output_path = "Spectrum/pink_tone.wav"
with wave.open(output_path, "w") as wf:
    wf.setnchannels(1)
    wf.setsampwidth(2)
    wf.setframerate(SAMPLE_RATE)
    for s in samples:
        wf.writeframes(struct.pack("<h", max(-32768, min(32767, s))))

print(f"Written to {output_path}")
