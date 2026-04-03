# BPM/Tempo Detection: Comprehensive Algorithm Research

**Date:** 2 April 2026
**Context:** Spectrum iOS app -- real-time audio analyser using Accelerate/vDSP, Metal rendering at 60fps. Current BPM detection uses autocorrelation of spectral flux at ~10fps onset rate.

---

## 1. Current Implementation Analysis

The existing `detectBPM()` in `AudioEngine.swift` has these characteristics:

- **Onset signal:** Spectral flux of low-frequency bins (20--200Hz), half-wave rectified
- **History buffer:** 170 frames (~8 seconds at ~21fps), circular buffer
- **Upsampling:** 4x linear interpolation to improve lag resolution from ~15 BPM/step to ~3-4 BPM/step
- **Autocorrelation:** Unnormalised `vDSP_dotpr` divided by overlap length, no perceptual weighting
- **Peak finding:** Simple argmax over lag range (60--200 BPM)
- **Smoothing:** Median of 5 consecutive estimates, requiring 4/5 consensus within +/-5 BPM
- **Silence gating:** Mean-squared flux threshold

**Root causes of the four reported problems:**

1. **False detections during quiet intros:** The silence threshold (`fluxEnergy < 5.0`) is too low. During quiet passages, small fluctuations in the spectral flux produce autocorrelation peaks that pass the 20% confidence threshold. The confidence metric (peak AC / zero-lag AC) is fundamentally unreliable for noise -- white noise autocorrelation at any lag can be 20-30% of zero-lag.

2. **Slow convergence (~15s):** Caused by three compounding factors: (a) 4 seconds minimum before any attempt, (b) the smoothing buffer requires 5 consistent estimates spaced every 5 frames (~0.5s each), adding ~2.5s, (c) the onset signal itself runs at only ~10fps, so 8 seconds of history contains only ~80 native samples -- barely two periods at 60 BPM.

3. **Octave errors (half-tempo):** The autocorrelation at lag L is always >= the autocorrelation at lag L/2 for periodic signals. Without explicit octave disambiguation, the longest-period (lowest-tempo) harmonic wins. The code comment says "no perceptual weighting -- let the signal speak for itself; weighting caused octave errors with coarse lags." This was the right instinct (weighting at coarse resolution introduces bias) but the wrong conclusion (the fix is better resolution + smarter disambiguation, not no weighting).

4. **Low onset rate (~10fps):** At 4410 samples per callback at 44.1kHz, callbacks arrive at ~10Hz. The 4x upsampling helps resolution but does not add information -- it just interpolates between points. True temporal resolution is still ~100ms, which is marginal for 200 BPM (300ms period = only 3 samples per beat period).

---

## 2. Onset Envelope Computation: What Works Best for BPM

### 2.1 Spectral Flux (Current Approach)

Half-wave rectified difference of magnitude spectrum between consecutive frames. Only positive changes (energy increases) are counted, capturing note onsets but not offsets.

```
flux(t) = sum_k max(0, |X(t,k)| - |X(t-1,k)|)
```

**Strengths:** Simple, computationally cheap, works well for percussive music.
**Weaknesses:** Sensitive to the frequency range used. Using only 20-200Hz misses hi-hat and snare transients that carry rhythmic information in many genres. Broadband spectral flux captures more rhythm but also more noise.

### 2.2 Mel-Frequency Onset Strength (librosa's Approach) -- RECOMMENDED

This is what librosa and Ellis (2007) use. The algorithm:

1. Compute mel spectrogram (typically 128 mel bands, 22050 Hz SR, hop_length=512 = ~23ms)
2. Apply power-to-dB conversion: `S_dB = 10 * log10(S + 1e-10)`
3. Compute first-order difference along time axis with a lag (default lag=1)
4. Half-wave rectify: `onset(t,f) = max(0, S_dB(t,f) - S_dB(t-lag,f))`
5. Apply local max filtering along frequency axis (suppresses broadband noise)
6. Aggregate across frequency bands: `odf(t) = mean_f(onset(t,f))`
7. Optionally detrend (subtract local mean)

**Why this is better than raw spectral flux:**

- **Log compression** (step 2) is critical. It compresses the dynamic range so that a quiet hi-hat onset becomes comparable in magnitude to a loud kick drum. Without log compression, the onset signal is dominated by bass energy, masking the rhythmic contribution of higher frequencies. This directly causes the false-detection-in-quiet-passages problem -- small absolute energy changes in the bass become visible in log domain only when there's actual musical content.

- **Mel frequency scale** concentrates resolution where human pitch perception is most sensitive and where most rhythmic information lives (below 5kHz). This is more efficient than linear-frequency spectral flux.

- **Multi-band aggregation** (averaging across mel bands) naturally suppresses narrowband noise -- a broadband onset (drum hit) activates many bands simultaneously, while noise tends to affect individual bands randomly. This is mathematically equivalent to the "multi-band onset detection" of Scheirer (1998) but with a perceptually-motivated frequency scale.

**Computational cost for Spectrum:** Moderate. A 128-band mel spectrogram requires a mel filterbank matrix multiply. With vDSP, this is a single `vDSP_mmul` call. The log conversion, differencing, and rectification are all element-wise vector operations. Total cost: ~0.1ms per frame on a modern iPhone.

### 2.3 Complex Domain Onset Detection

Uses both magnitude and phase of the STFT:

```
CD(t,k) = |X(t,k)| - |X_predicted(t,k)|
where X_predicted(t,k) = |X(t-1,k)| * exp(j * (2*phase(t-1,k) - phase(t-2,k)))
```

This detects onsets where either the magnitude changes unexpectedly OR the phase deviates from its expected trajectory (indicating a new note even at constant amplitude).

**Strengths:** Better for pitched instruments, detects soft onsets.
**Weaknesses:** Phase is unreliable at low frequencies and with short windows. More complex to implement. For BPM detection (as opposed to onset detection), the added complexity rarely improves results -- rhythmic periodicity is well captured by magnitude-only methods.

**Recommendation for Spectrum:** Not worth the complexity. Mel-frequency onset strength is sufficient.

### 2.4 Multi-Band Onset Detection (Scheirer 1998)

Scheirer's original approach splits the signal into 6 octave-wide bands (200Hz lowpass through 3200Hz highpass), extracts envelopes via rectification + smoothing, computes first-order difference with half-wave rectification, then sums across bands. This is essentially the same idea as mel-frequency onset strength but with fewer, wider bands.

**For Spectrum:** The mel approach generalises this with finer resolution and perceptual weighting. Use mel.

---

## 3. Tempo Estimation Methods: Detailed Comparison

### 3.1 Autocorrelation of the Onset Envelope

**How it works:**

The autocorrelation function (ACF) of the onset strength signal reveals periodicities. A peak at lag L corresponds to a tempo of `60 * SR_onset / L` BPM.

```
ACF(lag) = sum_t odf(t) * odf(t + lag)
```

**Critical preprocessing (what the current implementation is missing):**

1. **Log compression of onset envelope:** After computing the onset strength, apply `log(1 + C * odf)` where C is a compression factor (librosa uses C=1 by default via `power_to_db`, which is effectively log). This prevents a few loud onsets from dominating the autocorrelation.

2. **High-pass filtering / detrending:** Subtract the local mean (e.g., over a 1-second window) from the onset envelope before autocorrelation. This removes slow energy variations (like a gradual crescendo) that create spurious long-lag correlations. This is the single most effective fix for false detections during quiet intros -- the DC component of the onset signal during silence produces positive autocorrelation at all lags.

3. **Normalisation:** Divide ACF by zero-lag value (standard normalisation) or use Pearson normalisation per lag (as in the pitch detector). For BPM, standard normalisation is sufficient because the onset signal is already relatively stationary over the analysis window.

**Window length:** librosa uses `ac_size = 8` seconds by default. At ~10fps onset rate, this gives ~80 samples. At 120 BPM, one beat period is ~5 samples -- so 80 samples covers ~16 beat periods, which is adequate for autocorrelation. However, longer windows (10-12 seconds) improve frequency resolution.

**The upsampling problem:** The current 4x linear interpolation is a reasonable hack but has a fundamental limitation: it cannot create information that wasn't in the original signal. A better approach is to increase the native onset rate. With a 2048-sample FFT at 44.1kHz, each frame is ~46ms. If the audio callback delivers 4410 samples, you could compute TWO overlapping FFTs per callback (hop = 2048), doubling the onset rate to ~20fps. Or use a 1024-sample FFT for the onset computation only (separate from the display FFT), giving ~43fps onset rate -- this completely eliminates the upsampling problem.

**Computational cost:** O(N * L) where N is window length and L is the number of lags tested. With vDSP_dotpr, each lag is a single vectorised call. For 80 native samples, ~30 lags: trivial. For 400 upsampled samples, ~120 lags: still under 0.1ms.

### 3.2 Comb Filter Bank (Scheirer 1998)

**How it works:**

A bank of IIR comb filters, each tuned to a different tempo, is applied to the onset signal in parallel. Each comb filter resonates at its tuned period -- if the onset signal has energy at that period, the filter output accumulates energy. The filter with the highest output energy indicates the tempo.

The IIR comb filter for period T:

```
y(t) = (1 - alpha) * x(t) + alpha * y(t - T)
```

where `alpha` controls the memory (typically 0.8--0.99). Higher alpha = longer memory = slower response but more stable.

**Advantages over autocorrelation:**

- **Naturally causal and streaming:** Each filter maintains its own state across frames. No windowing or circular buffers needed.
- **Continuous adaptation:** The filter output responds immediately to tempo changes (the rate depending on alpha).
- **Energy accumulation, not correlation:** A comb filter resonates even if only every other beat is present (syncopation), as long as SOME energy arrives at the right period. Autocorrelation requires the signal to correlate with a shifted copy of itself, which is more fragile for syncopated rhythms.

**Disadvantages:**
- **More filters = more computation:** To cover 60--200 BPM at ~1 BPM resolution, you need ~140 filters. Each filter is cheap (one multiply-add per frame per filter), but the total adds up.
- **Octave ambiguity remains:** A filter at period T resonates just as strongly (or more strongly) for a signal at period T/2.
- **alpha tuning is tricky:** Too high = slow to respond to tempo changes. Too low = noisy output.

**Implementation for Spectrum:**

```swift
// Comb filter bank: one filter per candidate BPM
let bpmRange = 60...200  // 141 filters
var combEnergy = [Float](repeating: 0, count: 201)  // indexed by BPM

for bpm in bpmRange {
    let period = ossRate * 60.0 / Double(bpm)
    let periodInt = Int(round(period))
    // IIR: y[t] = (1-a)*x[t] + a*y[t-period]
    // Access the circular buffer at the appropriate lag
    let lagIdx = (fluxWriteIndex - periodInt + fluxHistorySize) % fluxHistorySize
    let delayed = spectralFluxHistory[lagIdx]
    combEnergy[bpm] = (1 - alpha) * currentFlux + alpha * combEnergy[bpm]
    // Note: this is simplified -- proper implementation accumulates 
    // filter state separately from the onset buffer
}
```

**For Spectrum:** The comb filter approach is worth serious consideration. It solves the convergence speed problem (no minimum window requirement -- the filter starts accumulating from the first beat) and handles syncopation more gracefully. The main implementation challenge is that it needs its own state array (141 floats), but this is trivial memory-wise. However, the approach used by BTrack (see section 7) combines autocorrelation WITH comb filtering, which may be the best hybrid.

### 3.3 Tempogram (Grosche & Muller 2010)

**How it works:**

A tempogram is essentially an STFT of the onset strength signal. Each column shows the tempo content at a particular time, like a spectrogram shows frequency content over time.

Two variants:
- **Autocorrelation tempogram:** Windowed autocorrelation computed at each time step. This is what librosa's `tempogram()` computes.
- **Fourier tempogram:** Short-time Fourier transform of the onset signal. Magnitude shows tempo strength.

The **cyclic tempogram** maps tempo to a single octave (like chroma maps pitch), folding tempos related by powers of 2 (60, 120, 240 BPM) onto the same bin. This explicitly handles octave ambiguity by design.

**For Spectrum:** The full tempogram is overkill for a real-time BPM display -- it's designed for offline analysis where you want to see how tempo varies over a song. However, the cyclic tempogram concept is valuable: when you detect a peak at lag L, check whether L/2 or 2*L also has a peak, and use the ratio to disambiguate octaves (see section 4).

---

## 4. Octave Ambiguity Resolution -- The Core Problem

This is the most important section for fixing Spectrum's half-tempo detections.

### 4.1 Why It Happens

For a signal with period P, the autocorrelation has peaks at P, 2P, 3P, ... (harmonics). The peak at 2P (half-tempo) is often STRONGER than at P because:
- More of the signal overlaps at longer lags (more averaging)
- The normalisation `/ (N - lag)` doesn't fully compensate
- For some rhythms (e.g., alternating strong-weak beats), the half-period peak genuinely is stronger

### 4.2 Perceptual Tempo Prior (Ellis / librosa Approach)

Ellis (2007) applies a log-Gaussian weighting window to the autocorrelation:

```
weight(bpm) = exp(-0.5 * ((log2(bpm) - log2(start_bpm)) / sigma)^2)
```

Default `start_bpm = 120`, `sigma` in librosa is approximately `std_bpm` (the spread).

This weights the autocorrelation so that tempos near 120 BPM are favoured. The key insight: it operates in **log-BPM space**, so the weighting is symmetric in octaves. A peak at 60 BPM is penalised the same amount as 240 BPM (both one octave from 120).

**Why this failed in the current implementation:** At ~10fps with 4x upsampling, the lag resolution is ~3-4 BPM. At this coarse resolution, the weighting window distorts the peak shape, pushing the maximum to a wrong BPM. The fix is to increase the onset rate (to ~40fps native) so that lag resolution is < 1 BPM, THEN apply the perceptual prior.

**Recommended parameters for electronic/dance music:**
- `start_bpm = 120` (centre of the weighting)
- `sigma = 1.0` octave (covers 60--240 BPM at 1-sigma, broad enough for most music)

### 4.3 Harmonic/Sub-harmonic Checking (RECOMMENDED)

After finding the peak at lag L (corresponding to tempo T BPM), check the autocorrelation at L/2 (tempo 2T):

```swift
let acAtLag = acValues[bestLag]
let halfLag = bestLag / 2
if halfLag >= minLag {
    let acAtHalfLag = acValues[halfLag]
    // If the half-lag peak is at least 80% as strong as the full-lag peak,
    // the true tempo is probably the faster one (2T)
    if acAtHalfLag > 0.80 * acAtLag {
        bestLag = halfLag
    }
}
```

**Why 80%?** For a truly periodic signal at period P, the ACF at P equals the ACF at 2P. So if the peak at L/2 is nearly as strong as at L, the signal genuinely has periodicity at L/2 and L is just the subharmonic. The 80% threshold accounts for noise and imperfect periodicity.

**Also check the triple relationship:** For compound meters (6/8, 12/8) or genres like D&B where the kick pattern repeats every 3 beats, check L/3 as well.

### 4.4 Librosa's Specific Approach

Librosa's `tempo()` function:

1. Computes onset autocorrelation tempogram
2. Averages the tempogram columns to get a global autocorrelation
3. Applies the log-Gaussian prior (centred at `start_bpm`, default 120)
4. Finds the top 2 peaks
5. Returns them as `(slower_tempo, faster_tempo)` with relative strengths

The `prior` parameter can be a `scipy.stats` distribution for custom weighting. The default is `lognorm` centred at 120 BPM.

### 4.5 Recommended Octave Resolution Strategy for Spectrum

Combine three techniques:

1. **Log-Gaussian prior** centred at 120 BPM with 1-octave sigma (gentle bias, not aggressive)
2. **Harmonic checking** at L/2 with 80% threshold
3. **Minimum BPM floor of 80** -- below 80 BPM, almost all music is perceived at double tempo. Set the search range to 80--200 BPM (lag range adjusted accordingly). If the strongest peak is below 80 BPM, automatically double it.

```swift
// After finding bestLag via argmax:
var candidateBPM = 60.0 * ossRate / refinedLag

// Harmonic check: is there a peak at double tempo?
let halfLag = bestLag / 2
if halfLag >= minLag && acValues[halfLag] > 0.80 * acValues[bestLag] {
    candidateBPM *= 2
}

// Floor check
if candidateBPM < 80 { candidateBPM *= 2 }
if candidateBPM > 200 { candidateBPM /= 2 }

// Perceptual prior (applied AFTER candidate selection, as a confidence modifier)
let priorWeight = exp(-0.5 * pow(log2(candidateBPM / 120.0) / 1.0, 2))
let adjustedConfidence = confidence * Float(priorWeight)
```

---

## 5. Onset Envelope Preprocessing for Better Autocorrelation

### 5.1 Log Compression of Onset Strength

**The single most impactful change.** Raw spectral flux has enormous dynamic range -- a loud kick drum produces flux values 100x larger than a quiet hi-hat. Autocorrelation is dominated by the few largest values.

Apply log compression AFTER computing the onset strength:

```swift
// After computing flux for this frame:
let compressedFlux = log(1.0 + 10.0 * flux)  // C=10 is a good starting point
```

The constant C controls compression strength:
- C=1: mild compression
- C=10: moderate (recommended for mixed music)
- C=100: heavy (useful for music with extreme dynamic range)

With vDSP, apply to the entire buffer before autocorrelation:

```swift
// Compress the linearised OSS before autocorrelation
var c: Float = 10.0
vDSP_vsmul(oss, 1, &c, &oss, 1, vDSP_Length(n))  // multiply by C
var one: Float = 1.0
vDSP_vsadd(oss, 1, &one, &oss, 1, vDSP_Length(n))  // add 1
// log in-place
var nn = Int32(n)
vvlogf(&oss, oss, &nn)  // from Accelerate (vecLib)
```

### 5.2 High-Pass Filtering / Detrending

Remove slow variations from the onset envelope to eliminate false autocorrelation during intros and transitions.

**Method 1: Subtract local mean** (simplest, recommended)

```swift
// Compute running mean with a ~2 second window
let windowSize = Int(ossRate * 2.0)
for i in 0..<n {
    let start = max(0, i - windowSize / 2)
    let end = min(n, i + windowSize / 2)
    let localMean = oss[start..<end].reduce(0, +) / Float(end - start)
    oss[i] = max(0, oss[i] - localMean)  // half-wave rectify after detrending
}
```

**Method 2: First-order IIR high-pass** (more efficient)

```swift
// Single-pole high-pass: y[n] = alpha * (y[n-1] + x[n] - x[n-1])
// alpha = 0.99 gives cutoff at ~0.16 Hz (removes variations slower than ~6 seconds)
let alpha: Float = 0.99
var prev_x: Float = oss[0]
var prev_y: Float = 0
for i in 0..<n {
    let y = alpha * (prev_y + oss[i] - prev_x)
    prev_x = oss[i]
    prev_y = y
    oss[i] = max(0, y)  // half-wave rectify
}
```

### 5.3 Normalisation

After detrending and log compression, normalise to unit variance:

```swift
var mean: Float = 0, std: Float = 0
vDSP_normalize(oss, 1, &oss, 1, &mean, &std, vDSP_Length(n))
```

This ensures the autocorrelation values are comparable across different signal levels, making the confidence threshold meaningful.

### 5.4 Recommended Preprocessing Pipeline

```
Raw spectral flux (per frame)
  -> Log compression: log(1 + 10*x)
  -> Store in circular buffer
  -> [When computing BPM:]
  -> Linearise circular buffer
  -> Subtract local mean (2s window)
  -> Half-wave rectify
  -> Normalise to zero mean, unit variance
  -> Autocorrelate
```

---

## 6. Real-Time Adaptation Strategies

### 6.1 Increasing the Onset Rate

The most impactful architectural change. Options:

**Option A: Multiple FFTs per audio callback (RECOMMENDED)**

Each audio callback delivers 4410 samples. Instead of one 2048-sample FFT, compute multiple overlapping FFTs:

```swift
let hopSize = 1024  // 50% overlap
let fftSize = 2048
var offset = 0
while offset + fftSize <= bufferLength {
    // Compute FFT of samples[offset..<offset+fftSize]
    // Compute onset strength from this FFT
    // Add to onset buffer
    offset += hopSize
}
```

At 44.1kHz with hop=1024, onset rate = 44100/1024 = ~43fps. This gives lag resolution of ~1.5 BPM at 120 BPM -- sufficient to apply perceptual weighting without distortion.

**Option B: Smaller FFT for onset only**

Use a 1024-sample FFT (23ms window) specifically for onset detection, separate from the 2048-sample FFT used for display. The frequency resolution is halved (21Hz per bin vs 10.5Hz) but that doesn't matter for onset strength -- we only need the broad spectral shape.

**Option C: Time-domain onset detection**

Skip the FFT entirely for onset detection. Compute the short-term energy in a sliding window:

```swift
// Energy onset function (very fast, no FFT needed)
let windowSize = 1024
var energy: Float = 0
vDSP_dotpr(samples, 1, samples, 1, &energy, vDSP_Length(windowSize))
let onsetStrength = max(0, energy - previousEnergy)
previousEnergy = energy
```

This runs at sample rate / windowSize = ~43fps with zero FFT cost. However, it loses frequency selectivity -- it can't distinguish bass onsets from broadband noise.

### 6.2 Faster Convergence

**Target: reliable BPM within 3-4 seconds of beat onset.**

Changes needed:
1. Reduce minimum samples from 40 to 20 (~2 seconds at 10fps, or ~1s at 43fps)
2. Reduce smoothing buffer from 5 to 3 estimates
3. Use comb filter bank for initial estimate (responds within 1-2 beat periods), then refine with autocorrelation
4. Start with wide BPM range (60-200), narrow to +/-10% of initial estimate once locked

**Hybrid approach (comb filters for fast lock, autocorrelation for accuracy):**

```swift
// Phase 1: Comb filter bank (fast, rough estimate)
// Updates every frame, converges in ~2 seconds
var combEstimate: Int?
for bpm in stride(from: 60, through: 200, by: 2) {  // coarse: 2 BPM steps
    // update comb filter state
}
combEstimate = bpmOfMaxCombEnergy

// Phase 2: Once comb filter has a candidate, refine with autocorrelation
// in a narrow range (+/- 15 BPM of comb estimate)
if let coarse = combEstimate, fluxHistory.count >= 30 {
    let refinedBPM = autocorrelateNarrowRange(coarse - 15, coarse + 15)
}
```

### 6.3 Handling Beat Dropouts and Tempo Changes

**Beat dropout (e.g., breakdown in electronic music):**

- Detect when onset energy drops below a threshold for > 2 seconds
- Freeze the displayed BPM (don't clear it) but stop the beat flash
- When energy returns, use the previous BPM as a strong prior for the first few seconds
- If the new beats are at a different tempo, the autocorrelation will override within 3-4 seconds

```swift
// Track "silence" duration
if fluxEnergy < silenceThreshold {
    silentFrameCount += 1
} else {
    silentFrameCount = 0
}

// During silence: keep BPM displayed but stop beat flash
if silentFrameCount > Int(ossRate * 2.0) {
    // Don't clear detectedBPM -- keep showing the last known tempo
    // But do suppress beat flash
    return (detectedBPM, false)
}
```

**Tempo change:**

- Use an exponentially-weighted moving average of the autocorrelation rather than a snapshot
- When the new peak diverges from the old by > 10 BPM, start a "transition" period where the smoothing buffer is reset
- During transition, require only 2/3 consensus instead of 4/5

### 6.4 Causal Onset Detection

All onset detection methods described here are causal (they only use the current and previous frames). The only non-causal element in typical implementations is the median filtering used for detrending. Replace with a causal alternative:

```swift
// Causal local mean: only use past values
let pastWindow = min(i, Int(ossRate * 2.0))
let localMean = oss[(i - pastWindow)..<i].reduce(0, +) / Float(pastWindow)
```

---

## 7. Open-Source Implementations: Key Takeaways

### 7.1 librosa (Python) -- `beat_track()` and `tempo()`

**Algorithm (Ellis 2007):**
1. Compute onset strength envelope via mel spectrogram -> log -> diff -> HWR -> mean
2. Compute windowed autocorrelation (8-second window) of onset envelope
3. Apply log-Gaussian tempo prior (centre 120 BPM)
4. Find peaks in weighted autocorrelation
5. Dynamic programming to select beat times consistent with estimated tempo

**Key parameters:**
- `sr=22050`, `hop_length=512` (~23ms per frame, ~43fps onset rate)
- `start_bpm=120` (centre of prior)
- `tightness=100` (DP penalty for deviating from expected beat interval)
- `ac_size=8.0` (seconds of autocorrelation window)
- 128 mel bands, fmax=sr/2

**Relevance to Spectrum:** The hop_length of 512 at 22050Hz gives ~43fps -- confirming that our 10fps is too low. The mel-based onset strength with log compression is the key difference from our implementation. The DP beat tracking is offline (non-causal) and not applicable to real-time, but the tempo estimation via weighted autocorrelation is directly applicable.

### 7.2 BTrack (C++) -- Real-Time Beat Tracker

**Algorithm (Stark, Davies, Plumbley 2009):**
1. Onset detection: complex spectral difference (magnitude + phase)
2. Tempo estimation: autocorrelation of onset signal, weighted by comb filter output
3. Beat prediction: cumulative beat strength signal with peak picking

**Key innovation:** BTrack uses autocorrelation to estimate tempo candidates, then applies comb filters tuned to those candidates to track the beat phase. This hybrid approach gets the frequency resolution of autocorrelation with the phase-tracking ability of comb filters.

**Parameters:**
- Hop size: 512 samples (default)
- Frame size: 1024 (2x hop)
- Onset detection frame stored in circular buffer
- Adaptive threshold for onset detection

**Relevance to Spectrum:** The hybrid autocorrelation + comb filter approach is the most promising architecture for our use case. It could be implemented incrementally -- first improve the autocorrelation (sections 4-5), then add comb filters for beat tracking and phase lock.

### 7.3 aubio (C) -- Causal Tempo Tracker

**Algorithm (Davies & Plumbley 2004, 2007):**
1. Onset detection: spectral flux (multiple methods available)
2. Tempo estimation: autocorrelation with a Rayleigh-distribution tempo weighting
3. Beat tracking: agent-based prediction with score function

**Key detail about octave ambiguity:** The aubio documentation explicitly states "the BPM value may be half or double of the real BPM, as the algorithm prefers measurements around 107 BPM." This confirms that octave ambiguity is inherent -- even professional libraries don't fully solve it, they just bias toward a particular octave.

**aubio's Rayleigh weighting:** Instead of a Gaussian centred at 120 BPM, aubio uses a Rayleigh distribution peaking at ~107 BPM and skewed toward faster tempos. This reflects the finding that most music is in the 100--130 BPM range.

**Relevance to Spectrum:** The 107 BPM centre is interesting -- it may work better for electronic music than the 120 BPM centre used by librosa.

### 7.4 Essentia (C++) -- Multi-Feature Approach

**RhythmExtractor2013:**

Two modes:
- **'degara'**: Single beat tracker based on complex spectral difference onset function
- **'multifeature'**: Runs 5 independent beat trackers and uses mutual agreement. Returns BPM, beat positions, and confidence.

The multifeature approach is the most robust but also the most expensive (5x the computation). It explicitly addresses octave ambiguity by having different trackers that may lock onto different octaves, then using voting to determine the consensus.

**Relevance to Spectrum:** Running 5 beat trackers is too expensive for real-time on mobile. However, the concept of running 2 trackers (one at the fundamental tempo, one at double tempo) and comparing their beat alignment is feasible and could resolve octave ambiguity.

### 7.5 madmom (Python) -- State of the Art

**Architecture:**
- Uses bidirectional RNNs (BLSTMs) or temporal convolutional networks (TCNs) to produce beat activation functions
- Comb filter bank for tempo estimation from the activation
- Dynamic Bayesian Network or HMM for beat tracking

**Key insight:** madmom uses comb filters (not autocorrelation) for its tempo estimation stage, confirming that comb filters are considered more robust by current researchers.

**Not applicable to Spectrum** (no ML models), but the comb filter preference is informative.

---

## 8. Drum & Bass and Syncopated Music

### 8.1 The Problem

D&B typically runs at 160-180 BPM. The kick drum pattern is heavily syncopated -- kicks land on off-beats, ghost notes, and irregular subdivisions. The hi-hat usually carries the steady pulse, but at much lower energy than the kick.

Standard BPM detectors see the kick pattern and detect half-tempo (80-90 BPM) because:
- The bass-heavy onset function has a strong sub-harmonic at half-tempo
- The perceptual prior (120 BPM) pulls toward 90 rather than 180
- The kick spacing is genuinely irregular at the quarter-note level

### 8.2 How DJ Software Handles It

**Rekordbox:** Allows users to set a BPM range (e.g., 98-195 BPM). When analysis returns 87.5 BPM for a D&B track, the range setting forces it to double to 175 BPM. This is essentially the "minimum BPM floor" approach.

**Traktor:** Uses a similar range-based approach with additional heuristics.

**Serato:** Proprietary algorithm, but user reports suggest it handles D&B better than Rekordbox, possibly due to multi-band onset detection that weighs hi-hat transients more heavily.

### 8.3 Technical Solutions

1. **Raise the minimum BPM to 80-90:** For popular music, almost nothing is genuinely below 80 BPM. Set the search range to 80-200 BPM and auto-double any result below 80. This single change would fix most D&B half-tempo issues.

2. **Multi-band onset detection with explicit hi-hat weighting:** D&B hi-hats (4-12kHz) carry the steady pulse. Add a high-frequency onset channel:

```swift
let hiHatFlux = computeFlux(bands: 4000...12000)
let kickFlux = computeFlux(bands: 20...200)
let combinedFlux = 0.5 * kickFlux + 0.5 * hiHatFlux
```

Equal weighting ensures the hi-hat pulse contributes to the autocorrelation even though it has less absolute energy.

3. **Harmonic checking (section 4.3):** After finding a peak at lag L, check L/2. For D&B, the peak at L/2 (corresponding to the actual tempo) will typically be 60-80% of the peak at L. With the 80% threshold, borderline cases will be caught.

---

## 9. Recommended Implementation Plan for Spectrum

Priority-ordered changes, each independently testable:

### Phase 1: Fix False Detections (highest impact, easiest)

1. **Add log compression** to the spectral flux before storing in circular buffer
2. **Detrend** the onset signal before autocorrelation (subtract 2-second local mean)
3. **Raise silence threshold** significantly (from 5.0 to something derived from the signal statistics, e.g., require flux variance > threshold)
4. **Normalise onset signal** to unit variance before autocorrelation

### Phase 2: Fix Octave Ambiguity

5. **Add harmonic checking** (section 4.3) -- if AC at L/2 > 80% of AC at L, prefer half-lag
6. **Set minimum BPM to 80** -- auto-double anything below 80
7. **Add gentle log-Gaussian prior** centred at 120 BPM with 1-octave sigma (only after onset rate is increased)

### Phase 3: Improve Convergence Speed

8. **Increase onset rate** to ~40fps by computing multiple FFTs per audio callback (hop=1024)
9. **Reduce smoothing requirements** -- 3 consistent estimates instead of 5
10. **Reduce minimum samples** from 40 to 20

### Phase 4: Advanced (Optional)

11. **Add comb filter bank** for initial tempo lock (converges in 1-2 seconds)
12. **Multi-band onset detection** (mel-frequency) instead of bass-only spectral flux
13. **Beat-phase tracking** for more accurate beat flash timing

### Parameter Recommendations

| Parameter | Current | Recommended |
|-----------|---------|-------------|
| Onset rate | ~10fps | ~40fps (hop=1024) |
| History size | 170 frames (~8s) | 320 frames (~8s at 40fps) |
| Min samples for BPM | 40 (~4s) | 80 (~2s at 40fps) |
| Smoothing buffer | 5 estimates | 3 estimates |
| BPM range | 60-200 | 80-200 (auto-double below 80) |
| Confidence threshold | 0.20 | 0.30 (after normalisation) |
| Log compression | None | log(1 + 10*x) |
| Detrending | Subtract global mean | Subtract 2s local mean |
| Perceptual prior | None | log-Gaussian, centre=120, sigma=1.0 octaves |
| Harmonic check | None | L/2 at 80% threshold |
| Upsampling | 4x linear | Remove (native rate sufficient at 40fps) |

---

## Sources

- [librosa beat_track documentation](https://librosa.org/doc/main/generated/librosa.beat.beat_track.html)
- [librosa onset_strength documentation](https://librosa.org/doc/main/generated/librosa.onset.onset_strength.html)
- [librosa source: beat.py](https://librosa.org/doc/main/_modules/librosa/beat.html)
- [librosa source: onset.py](https://librosa.org/doc/main/_modules/librosa/onset.html)
- [Beat Tracking and Tempo Estimation -- DeepWiki](https://deepwiki.com/librosa/librosa/5.2-beat-tracking-and-tempo-estimation)
- [Daniel Ellis -- Beat Tracking by Dynamic Programming (2007)](https://www.ee.columbia.edu/~dpwe/pubs/Ellis07-beattrack.pdf)
- [Beat Tracking by Dynamic Programming -- AudioLabs Erlangen](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C6/C6S3_BeatTracking.html)
- [Baseline Approach -- Tempo, Beat and Downbeat Estimation Tutorial](https://tempobeatdownbeat.github.io/tutorial/ch2_basics/baseline.html)
- [Scheirer (1998) -- Tempo and Beat Analysis of Acoustic Musical Signals](https://cagnazzo.wp.imt.fr/files/2013/05/Scheirer98.pdf)
- [BTrack -- A Real-Time Beat Tracker (Adam Stark)](https://github.com/adamstark/BTrack)
- [Stark -- Real-Time Visual Beat Tracking using a Comb Filter Matrix (ICMC 2011)](https://www.adamstark.co.uk/pdf/papers/comb-filter-matrix-ICMC-2011.pdf)
- [aubio tempo detection](https://github.com/aubio/aubio/blob/master/src/tempo/tempo.c)
- [Davies & Plumbley -- Causal Tempo Tracking of Audio (ISMIR 2004)](https://archives.ismir.net/ismir2004/paper/000226.pdf)
- [Essentia -- Beat Detection and BPM Estimation Tutorial](https://essentia.upf.edu/tutorial_rhythm_beatdetection.html)
- [Essentia RhythmExtractor2013](https://essentia.upf.edu/reference/std_RhythmExtractor2013.html)
- [madmom beat tracking](https://madmom.readthedocs.io/en/v0.16/modules/features/beats.html)
- [Grosche & Muller -- Cyclic Tempogram (ICASSP 2010)](https://www.researchgate.net/publication/224149883_Cyclic_tempogram-A_mid-level_tempo_representation_for_musicsignals)
- [OBTAIN -- Real-Time Beat Tracking in Audio Signals](https://arxiv.org/pdf/1704.02216)
- [Rekordbox D&B BPM Issues (Pioneer DJ Forum)](https://forums.pioneerdj.com/hc/en-us/community/posts/203054289-Why-does-Rekordbox-think-all-Drum-And-Bass-is-half-speed)
- [Music Tempo Estimation: Are We Done Yet? (TISMIR)](https://transactions.ismir.net/articles/10.5334/tismir.43)
- [librosa tempogram documentation](https://librosa.org/doc-playground/0.9.1/generated/librosa.feature.tempogram.html)
- [Onset Detection Revisited -- Dixon (2006)](https://ofai.at/papers/oefai-tr-2006-12.pdf)
