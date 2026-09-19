# AnimalTracker Plan B: Voice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Voice recording with on-device analysis: two Swift packages (audio features, statistics) validated against a librosa oracle, and the Voice tab (Record, History, Ask, Insights) in the AnimalTracker app on the merged models.

**Architecture:** `AnimalVoiceAudio` decodes, segments, and extracts pitch, loudness, centroid, and MFCC features per vocalization. `AnimalVoiceStats` standardizes features and runs a kNN plus naive Bayes ensemble with leave-one-out evaluation and a readiness rule. The app stores recordings as m4a files in the media store, vocalizations and tags in SwiftData, and predicts per selected animal. Tasks 1 to 12 are the package tasks carried over unchanged from `2026-09-15-cat-voice.md`; tasks 13 to 18 are the app tasks rewritten for Plan A's foundation and the model contract.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftData, AVFoundation, Accelerate, Swift Charts, XCTest, Python 3.13 + librosa (oracle only).

**Spec:** `docs/superpowers/specs/2026-09-16-animal-tracker-design.md` (Voice tab, Voice domain, Voice packages) and `docs/superpowers/specs/2026-09-18-model-contract.md` (VoiceRecording, Vocalization, VoiceTag). Plan A (`2026-09-18-animal-tracker-A-foundation.md`) must be complete first.

## Global Constraints

- Packages: `swift-tools-version: 5.9`, platforms `.iOS(.v17)`, `.macOS(.v14)`, tested with `scripts/test-packages.sh` on the Mac. App tasks tested with `scripts/test-app.sh` (`@testable import AnimalTracker`).
- Working sample rate after decode: `16_000` Hz mono Float32.
- Segmenter defaults: frame 40 ms, hop 20 ms, active if within 20 dB of loudest frame and above -50 dBFS, drop runs shorter than 80 ms, bridge gaps shorter than 100 ms.
- Pitch: YIN, 40 ms frames, 20 ms hop, 60 to 3000 Hz, voiced when aperiodicity < 0.3, f0 stats nil when fewer than 3 voiced frames.
- Spectral: 1024-point FFT, hop 320 samples, 26 mel bands (slaney scale and norm), 13 MFCCs, `top_db` 80, librosa `center=True` zero padding.
- Feature vector (21 columns): `durationS, f0Mean, f0Min, f0Max, f0Slope, voicedFraction, rmsDb, spectralCentroidHz, mfcc0 … mfcc12`; nil encoded as `Double.nan`.
- Readiness: at least 2 distinct meaning labels each with at least 5 labeled vocalizations. kNN k = 5 distance-weighted; naive Bayes Gaussian with variance floor; ensemble averages.
- The Meowsic research hint is shown only when `animal.isCat`.
- Models exactly as the contract: `VoiceRecording`, `Vocalization`, `VoiceTag`; audio files `<uuid>-audio.m4a` via `MediaStore.saveAudio(from:)`; recordings cap at 5 minutes.
- Registration points: `PersistenceController.modelTypes`, `Seeds.all`, `AnimalDeletionPolicy.recordCounts` ("voice recordings"), `RootTabView` Voice tab line, `SettingsPlaceholderRow(title: "Voice tags")`.
- Voice tab root is inside Plan A's NavigationStack with the shared toolbar; it must not add its own NavigationStack. Screens read the animal via `@Environment(\.selectedAnimal)`.
- Commit after every task with the message shown; do not push. Prose without em-dashes.

## Fixture

`~/Downloads/cat1.m4a` is the sample recording (91 s cat audio). Tasks 1 to 3 copy it into the package fixtures and make a 16 kHz WAV with ffmpeg.

---

### Task 1: AudioLoader (decode any file to 16 kHz mono)

**Files:**
- Create: `Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/AudioLoader.swift`
- Create: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/TestSignals.swift`, `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/AudioLoaderTests.swift`
- Create fixture: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/cat1.m4a` (copy of `~/Downloads/cat1.m4a`)

**Interfaces:**
- Consumes: `AudioBuffer`.
- Produces: `AudioLoader.load(_ url: URL) throws -> AudioBuffer` (always 16 kHz mono); `AudioLoader.targetSampleRate`; test helpers `TestSignals.sine(frequency:seconds:sampleRate:amplitude:) -> [Float]` and `TestSignals.writeWav(_:sampleRate:channels:) throws -> URL`.

- [ ] **Step 1: Copy the fixture and write the test helper**

```bash
cp ~/Downloads/cat1.m4a Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/cat1.m4a
```

`Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/TestSignals.swift`:
```swift
import AVFoundation
import Foundation

enum TestSignals {
    static func sine(frequency: Double, seconds: Double, sampleRate: Double = 16_000, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { i in amplitude * Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) }
    }

    static func silence(seconds: Double, sampleRate: Double = 16_000) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Writes mono samples to a 16-bit PCM WAV, duplicating the channel if `channels` > 1.
    static func writeWav(_ samples: [Float], sampleRate: Double, channels: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("animalvoice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for c in 0..<channels {
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![c].update(from: src.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
        return url
    }

    static func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/AudioLoaderTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceAudio

final class AudioLoaderTests: XCTestCase {
    func testResamplesStereo48kToMono16k() throws {
        let src = TestSignals.sine(frequency: 440, seconds: 1.0, sampleRate: 48_000)
        let url = try TestSignals.writeWav(src, sampleRate: 48_000, channels: 2)
        let buffer = try AudioLoader.load(url)
        XCTAssertEqual(buffer.sampleRate, 16_000)
        XCTAssertEqual(buffer.samples.count, 16_000, accuracy: 100)
        XCTAssertEqual(buffer.samples.max() ?? 0, 0.5, accuracy: 0.05)
    }

    func testLoadsM4aFixture() throws {
        let buffer = try AudioLoader.load(TestSignals.fixtureURL("cat1.m4a"))
        XCTAssertEqual(buffer.sampleRate, 16_000)
        XCTAssertEqual(buffer.durationS, 91.0, accuracy: 0.5)
        XCTAssertGreaterThan(buffer.samples.map(abs).max() ?? 0, 0.5)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try AudioLoader.load(URL(fileURLWithPath: "/nonexistent.wav")))
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter AudioLoaderTests 2>&1 | tail -5`
Expected: compile error, `AudioLoader` not found.

- [ ] **Step 4: Implement AudioLoader**

`Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/AudioLoader.swift`:
```swift
import AVFoundation
import Foundation

public enum AudioLoaderError: Error {
    case allocationFailed
    case conversionFailed(String)
}

public enum AudioLoader {
    public static let targetSampleRate: Double = 16_000

    /// Decodes any AVFoundation-readable file (m4a, wav, caf, mp3) to mono Float32 at 16 kHz.
    public static func load(_ url: URL) throws -> AudioBuffer {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(max(file.length, 1))
        guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw AudioLoaderError.allocationFailed
        }
        try file.read(into: src)

        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw AudioLoaderError.conversionFailed("cannot build converter from \(srcFormat)")
        }
        let ratio = targetSampleRate / srcFormat.sampleRate
        let dstCapacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 4096
        guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            throw AudioLoaderError.allocationFailed
        }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: dst, error: &conversionError) { _, outStatus in
            if delivered {
                outStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return src
        }
        if status == .error {
            throw AudioLoaderError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }
        let count = Int(dst.frameLength)
        guard let channel = dst.floatChannelData?[0] else { throw AudioLoaderError.allocationFailed }
        return AudioBuffer(samples: Array(UnsafeBufferPointer(start: channel, count: count)), sampleRate: targetSampleRate)
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter AudioLoaderTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`. If the stereo test's sample count is off by more than 100, the converter needs a second `convert` call: wrap the convert in `repeat { … } while status == .haveData && dst.frameLength < dstCapacity` and note it in the commit.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(audio): AudioLoader decodes any file to 16 kHz mono

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Segmenter (energy-based vocalization events)

**Files:**
- Create: `Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/Segmenter.swift`
- Create: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/SegmenterTests.swift`
- Create fixture: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/cat1_16k.wav`

**Interfaces:**
- Consumes: `AudioBuffer`, `AudioLoader`.
- Produces: `SegmenterConfig` (defaults from spec), `Segment(startS: Double, endS: Double)` with `durationS`, `Segmenter.frameRmsDb(_:config:) -> [Float]`, `Segmenter.segment(_:config:) -> [Segment]`.

- [ ] **Step 1: Make the 16 kHz WAV fixture**

```bash
ffmpeg -hide_banner -loglevel error -y -i ~/Downloads/cat1.m4a -ac 1 -ar 16000 -sample_fmt s16 \
  Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/cat1_16k.wav
ls -la Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/
```
Expected: `cat1_16k.wav` about 2.9 MB.

- [ ] **Step 2: Write the failing tests**

`Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/SegmenterTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceAudio

final class SegmenterTests: XCTestCase {
    private func burstsBuffer() -> AudioBuffer {
        // 0.5 s silence, 0.3 s tone, 0.5 s silence, 0.05 s gap-bridged pair (0.2 s tone, 0.05 s gap, 0.2 s tone), 0.5 s silence, 0.03 s blip (too short)
        var s: [Float] = []
        s += TestSignals.silence(seconds: 0.5)
        s += TestSignals.sine(frequency: 500, seconds: 0.3)
        s += TestSignals.silence(seconds: 0.5)
        s += TestSignals.sine(frequency: 500, seconds: 0.2)
        s += TestSignals.silence(seconds: 0.05)
        s += TestSignals.sine(frequency: 500, seconds: 0.2)
        s += TestSignals.silence(seconds: 0.5)
        s += TestSignals.sine(frequency: 500, seconds: 0.03)
        s += TestSignals.silence(seconds: 0.5)
        return AudioBuffer(samples: s, sampleRate: 16_000)
    }

    func testFindsBurstsBridgesGapsDropsShortRuns() {
        let segs = Segmenter.segment(burstsBuffer())
        XCTAssertEqual(segs.count, 2, "\(segs)")
        XCTAssertEqual(segs[0].startS, 0.5, accuracy: 0.05)
        XCTAssertEqual(segs[0].endS, 0.8, accuracy: 0.06)
        XCTAssertEqual(segs[1].startS, 1.3, accuracy: 0.05)
        XCTAssertEqual(segs[1].endS, 1.75, accuracy: 0.06)
    }

    func testSilenceYieldsNothing() {
        let segs = Segmenter.segment(AudioBuffer(samples: TestSignals.silence(seconds: 2), sampleRate: 16_000))
        XCTAssertEqual(segs, [])
    }

    func testQuietSignalBelowFloorYieldsNothing() {
        // -60 dBFS tone is below the -50 dBFS floor even though it is the loudest thing present
        let quiet = TestSignals.sine(frequency: 500, seconds: 1, amplitude: 0.001)
        XCTAssertEqual(Segmenter.segment(AudioBuffer(samples: quiet, sampleRate: 16_000)), [])
    }

    func testFrameRmsDbShape() {
        let b = AudioBuffer(samples: TestSignals.sine(frequency: 500, seconds: 1.0, amplitude: 1.0), sampleRate: 16_000)
        let db = Segmenter.frameRmsDb(b)
        XCTAssertEqual(db.count, 49) // 1 + (16000 - 640) / 320
        XCTAssertEqual(db[10], -3.01, accuracy: 0.2) // full-scale sine rms = 0.707
    }

    func testSampleRecordingSegmentCount() throws {
        let b = try AudioLoader.load(TestSignals.fixtureURL("cat1_16k.wav"))
        let segs = Segmenter.segment(b)
        print("cat1 segments:", segs.map { String(format: "%.2f-%.2f", $0.startS, $0.endS) })
        XCTAssertTrue((10...14).contains(segs.count), "got \(segs.count) segments")
        XCTAssertTrue(segs.contains { abs($0.startS - 36.68) < 0.05 }, "expected the loud meow near 36.7 s")
        XCTAssertTrue(segs.contains { abs($0.startS - 60.34) < 0.05 }, "expected the loud meow near 60.3 s")
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter SegmenterTests 2>&1 | tail -5`
Expected: compile error, `Segmenter` not found.

- [ ] **Step 4: Implement Segmenter**

`Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/Segmenter.swift`:
```swift
import Accelerate
import Foundation

public struct SegmenterConfig: Equatable {
    public var frameSeconds: Double = 0.04
    public var hopSeconds: Double = 0.02
    public var relativeThresholdDb: Float = 20
    public var absoluteFloorDbfs: Float = -50
    public var minSegmentSeconds: Double = 0.08
    public var maxGapSeconds: Double = 0.10

    public init() {}
}

public struct Segment: Equatable, Codable {
    public var startS: Double
    public var endS: Double

    public init(startS: Double, endS: Double) {
        self.startS = startS
        self.endS = endS
    }

    public var durationS: Double { endS - startS }
}

public enum Segmenter {
    /// RMS level in dBFS per frame. Frame i covers samples [i*hop, i*hop+frame).
    public static func frameRmsDb(_ buffer: AudioBuffer, config: SegmenterConfig = .init()) -> [Float] {
        let frame = Int(config.frameSeconds * buffer.sampleRate)
        let hop = Int(config.hopSeconds * buffer.sampleRate)
        guard buffer.samples.count >= frame, frame > 0, hop > 0 else { return [] }
        let n = 1 + (buffer.samples.count - frame) / hop
        var out = [Float](repeating: -160, count: n)
        buffer.samples.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let slice = UnsafeBufferPointer(rebasing: p[(i * hop)..<(i * hop + frame)])
                let rms = vDSP.rootMeanSquare(slice)
                out[i] = 20 * log10(max(rms, 1e-8))
            }
        }
        return out
    }

    public static func segment(_ buffer: AudioBuffer, config: SegmenterConfig = .init()) -> [Segment] {
        let db = frameRmsDb(buffer, config: config)
        guard let peak = db.max() else { return [] }
        let threshold = max(peak - config.relativeThresholdDb, config.absoluteFloorDbfs)
        let active = db.map { $0 > threshold }

        // Runs of active frames as inclusive frame index ranges.
        var runs: [(Int, Int)] = []
        var start: Int?
        for (i, a) in active.enumerated() {
            if a, start == nil { start = i }
            if !a, let s = start { runs.append((s, i - 1)); start = nil }
        }
        if let s = start { runs.append((s, active.count - 1)) }

        // Bridge short gaps.
        let maxGapFrames = Int(config.maxGapSeconds / config.hopSeconds)
        var merged: [(Int, Int)] = []
        for r in runs {
            if let last = merged.last, r.0 - last.1 - 1 < maxGapFrames {
                merged[merged.count - 1].1 = r.1
            } else {
                merged.append(r)
            }
        }

        // Drop short runs and convert to seconds.
        let minFrames = Int((config.minSegmentSeconds / config.hopSeconds).rounded())
        return merged.compactMap { (a, b) in
            guard b - a + 1 >= minFrames else { return nil }
            let startS = Double(a) * config.hopSeconds
            let endS = Double(b) * config.hopSeconds + config.frameSeconds
            return Segment(startS: startS, endS: min(endS, buffer.durationS))
        }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter SegmenterTests 2>&1 | tail -8`
Expected: `Executed 5 tests, with 0 failures`. The printed `cat1 segments:` line should list starts near 3.04, 21.82, 36.68, 40.48, 42.70, 60.34, 65.44, 69.72, 70.14, 74.90, 75.18, 75.80.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(audio): energy-based Segmenter with gap bridging

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Python librosa oracle for the sample recording

**Files:**
- Create: `tools/reference/requirements.txt`, `tools/reference/extract.py`
- Create fixture: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/cat1_oracle.json`

**Interfaces:**
- Consumes: `Fixtures/cat1_16k.wav` from Task 2.
- Produces: `cat1_oracle.json` with shape `{"sampleRate": 16000, "segments": [{"startS", "endS", "rmsDb", "spectralCentroidHz", "mfcc": [13 doubles], "f0Mean": double|null, "voicedFrames": int}]}`. Task 6's test decodes exactly these keys.

- [ ] **Step 1: Write requirements and the script**

`tools/reference/requirements.txt`:
```
librosa>=0.10
numpy
soundfile
```

`tools/reference/extract.py`:
```python
#!/usr/bin/env python3
"""Reference (oracle) features for the Swift AnimalVoiceAudio tests, computed with librosa.

Usage: .venv/bin/python tools/reference/extract.py <in.wav> <out.json>
The Swift implementation must match these numbers within the tolerances in FeatureExtractorTests.
"""
import json
import sys

import librosa
import numpy as np
import soundfile as sf

SR = 16000
N_FFT, HOP, N_MELS, N_MFCC = 1024, 320, 26, 13
PITCH_FRAME, PITCH_HOP, FMIN, FMAX = 640, 320, 60, 3000

# Segments produced by the spec's Segmenter on cat1_16k.wav (see Task 2 test output).
SEGMENTS = [
    (3.04, 3.16), (21.82, 21.92), (36.68, 37.06), (40.48, 40.58), (42.70, 42.82), (60.34, 60.80),
    (65.44, 65.56), (69.72, 70.04), (70.14, 70.24), (74.90, 75.04), (75.18, 75.46), (75.80, 75.90),
]


def features(seg: np.ndarray) -> dict:
    S = np.abs(librosa.stft(seg, n_fft=N_FFT, hop_length=HOP, win_length=N_FFT,
                            window="hann", center=True, pad_mode="constant"))
    centroid = float(librosa.feature.spectral_centroid(S=S, sr=SR, n_fft=N_FFT).mean())
    mel = librosa.feature.melspectrogram(S=S ** 2, sr=SR, n_fft=N_FFT, n_mels=N_MELS,
                                         fmin=0.0, fmax=SR / 2, htk=False, norm="slaney")
    logmel = librosa.power_to_db(mel, ref=1.0, amin=1e-10, top_db=80.0)
    mfcc = librosa.feature.mfcc(S=logmel, n_mfcc=N_MFCC, dct_type=2, norm="ortho", lifter=0).mean(axis=1)
    rms_db = float(20 * np.log10(max(float(np.sqrt(np.mean(seg ** 2))), 1e-8)))
    f0, voiced, _ = librosa.pyin(seg, fmin=FMIN, fmax=FMAX, sr=SR,
                                 frame_length=PITCH_FRAME, hop_length=PITCH_HOP)
    n_voiced = int(voiced.sum())
    f0_mean = float(np.nanmean(f0[voiced])) if n_voiced >= 3 else None
    return {
        "rmsDb": rms_db,
        "spectralCentroidHz": centroid,
        "mfcc": [float(v) for v in mfcc],
        "f0Mean": f0_mean,
        "voicedFrames": n_voiced,
    }


def main() -> None:
    wav, out = sys.argv[1], sys.argv[2]
    y, sr = sf.read(wav, dtype="float32")
    if y.ndim > 1:
        y = y.mean(axis=1)
    assert sr == SR, f"expected {SR} Hz, got {sr}"
    segments = []
    for start, end in SEGMENTS:
        seg = y[int(start * SR):int(end * SR)]
        f = features(seg)
        segments.append({"startS": start, "endS": end, **f})
        print(f"{start:6.2f}-{end:6.2f}  rms={f['rmsDb']:6.1f} dB  centroid={f['spectralCentroidHz']:7.1f} Hz  "
              f"f0={f['f0Mean'] if f['f0Mean'] is None else round(f['f0Mean'])}  mfcc0={f['mfcc'][0]:.1f}")
    with open(out, "w") as fh:
        json.dump({"sampleRate": SR, "segments": segments}, fh, indent=1)
    print("wrote", out)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Create the venv and run the oracle**

```bash
/opt/homebrew/bin/python3.13 -m venv .venv
.venv/bin/pip install -q -r tools/reference/requirements.txt
.venv/bin/python tools/reference/extract.py \
  Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/cat1_16k.wav \
  Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/cat1_oracle.json
```
Expected: 12 lines plus `wrote …cat1_oracle.json`. Sanity: rms values between -45 and -5 dB; centroids between 300 and 4000 Hz; at least the segments starting at 36.68 and 60.34 have a non-null f0 in the 300 to 1200 Hz range. If `pip install` fails on numba for Python 3.13, use `/opt/homebrew/bin/python3.11 -m venv .venv` instead and note it in the README.

- [ ] **Step 3: Commit**

```bash
git add tools/reference Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/Fixtures/cat1_oracle.json
git commit -m "test(audio): librosa oracle features for the sample recording

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: PitchTracker (YIN)

**Files:**
- Create: `Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/PitchTracker.swift`
- Create: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/PitchTrackerTests.swift`

**Interfaces:**
- Consumes: nothing beyond Accelerate.
- Produces: `PitchConfig` (frameSeconds 0.04, hopSeconds 0.02, minHz 60, maxHz 3000, threshold 0.3), `PitchFrame(timeS: Double, f0Hz: Double?, aperiodicity: Float)`, `PitchTracker.track(_ samples: [Float], sampleRate: Double, config:) -> [PitchFrame]`.

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/PitchTrackerTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceAudio

final class PitchTrackerTests: XCTestCase {
    private func assertTracks(_ hz: Double, file: StaticString = #filePath, line: UInt = #line) {
        let frames = PitchTracker.track(TestSignals.sine(frequency: hz, seconds: 0.5), sampleRate: 16_000)
        XCTAssertEqual(frames.count, 24, file: file, line: line) // 1 + (8000 - 640) / 320
        let voiced = frames.compactMap(\.f0Hz)
        XCTAssertGreaterThanOrEqual(voiced.count, 22, "most frames voiced at \(hz) Hz", file: file, line: line)
        let mean = voiced.reduce(0, +) / Double(voiced.count)
        XCTAssertEqual(mean, hz, accuracy: hz * 0.02, file: file, line: line)
    }

    func testTracksPureTones() {
        assertTracks(220)
        assertTracks(440)
        assertTracks(880)
    }

    func testSilenceIsUnvoiced() {
        let frames = PitchTracker.track(TestSignals.silence(seconds: 0.5), sampleRate: 16_000)
        XCTAssertEqual(frames.count, 24)
        XCTAssertTrue(frames.allSatisfy { $0.f0Hz == nil })
    }

    func testTooShortInputGivesNoFrames() {
        XCTAssertEqual(PitchTracker.track(TestSignals.sine(frequency: 440, seconds: 0.01), sampleRate: 16_000).count, 0)
    }

    func testFrameTimesAdvanceByHop() {
        let frames = PitchTracker.track(TestSignals.sine(frequency: 440, seconds: 0.2), sampleRate: 16_000)
        XCTAssertEqual(frames[1].timeS - frames[0].timeS, 0.02, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter PitchTrackerTests 2>&1 | tail -5`
Expected: compile error, `PitchTracker` not found.

- [ ] **Step 3: Implement PitchTracker**

`Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/PitchTracker.swift`:
```swift
import Accelerate
import Foundation

public struct PitchConfig: Equatable {
    public var frameSeconds: Double = 0.04
    public var hopSeconds: Double = 0.02
    public var minHz: Double = 60
    public var maxHz: Double = 3000
    /// CMNDF value below which a lag counts as periodic (de Cheveigné & Kawahara 2002 use 0.1; 0.3 is more permissive for noisy phone audio).
    public var threshold: Float = 0.3

    public init() {}
}

public struct PitchFrame: Equatable {
    /// Start time of the frame in seconds.
    public var timeS: Double
    /// Fundamental frequency, nil when the frame is unvoiced.
    public var f0Hz: Double?
    /// Minimum cumulative-mean-normalized difference in the search range (0 = perfectly periodic).
    public var aperiodicity: Float
}

/// YIN pitch estimation: difference function -> cumulative mean normalization -> absolute threshold -> parabolic interpolation.
public enum PitchTracker {
    public static func track(_ samples: [Float], sampleRate: Double, config: PitchConfig = .init()) -> [PitchFrame] {
        let w = Int(config.frameSeconds * sampleRate)
        let hop = Int(config.hopSeconds * sampleRate)
        let tauMin = max(2, Int(sampleRate / config.maxHz))
        let tauMax = Int(sampleRate / config.minHz)
        guard w > 0, hop > 0, tauMax > tauMin, samples.count >= w else { return [] }

        // Pad so every frame can look tauMax samples ahead.
        let padded = samples + [Float](repeating: 0, count: tauMax + 1)
        let frameCount = 1 + (samples.count - w) / hop
        var frames: [PitchFrame] = []
        frames.reserveCapacity(frameCount)
        var scratch = [Float](repeating: 0, count: w)

        padded.withUnsafeBufferPointer { p in
            for i in 0..<frameCount {
                let start = i * hop
                let (lag, aperiodicity) = yin(p, start: start, window: w, tauMin: tauMin, tauMax: tauMax,
                                              threshold: config.threshold, scratch: &scratch)
                frames.append(PitchFrame(timeS: Double(start) / sampleRate,
                                         f0Hz: lag.map { sampleRate / Double($0) },
                                         aperiodicity: aperiodicity))
            }
        }
        return frames
    }

    /// One YIN frame. Returns (refined lag in samples or nil if unvoiced, aperiodicity).
    static func yin(_ p: UnsafeBufferPointer<Float>, start: Int, window w: Int, tauMin: Int, tauMax: Int,
                    threshold: Float, scratch: inout [Float]) -> (Float?, Float) {
        let x = UnsafeBufferPointer(rebasing: p[start..<(start + w)])
        var d = [Float](repeating: 0, count: tauMax + 1)
        for tau in 1...tauMax {
            let y = UnsafeBufferPointer(rebasing: p[(start + tau)..<(start + tau + w)])
            vDSP.subtract(y, from: x, result: &scratch)
            d[tau] = vDSP.sumOfSquares(scratch)
        }

        // Cumulative mean normalized difference function.
        var dp = [Float](repeating: 1, count: tauMax + 1)
        var running: Float = 0
        for tau in 1...tauMax {
            running += d[tau]
            dp[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }

        // First dip below threshold, then slide to its local minimum.
        var tau = tauMin
        var found: Int?
        while tau <= tauMax {
            if dp[tau] < threshold {
                while tau + 1 <= tauMax, dp[tau + 1] < dp[tau] { tau += 1 }
                found = tau
                break
            }
            tau += 1
        }
        guard let t = found else {
            return (nil, dp[tauMin...tauMax].min() ?? 1)
        }

        // Parabolic interpolation around the minimum.
        var refined = Float(t)
        if t > 1, t < tauMax {
            let a = dp[t - 1], b = dp[t], c = dp[t + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 { refined += 0.5 * (a - c) / denom }
        }
        return (refined, dp[t])
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter PitchTrackerTests 2>&1 | tail -6`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(audio): YIN PitchTracker

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: SpectralAnalyzer (FFT, centroid, mel filterbank, MFCC)

**Files:**
- Create: `Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/SpectralAnalyzer.swift`
- Create: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/SpectralAnalyzerTests.swift`

**Interfaces:**
- Produces: `SpectralConfig` (fftSize 1024, hop 320, melBands 26, mfccCount 13, topDb 80), `SpectralAnalyzer(sampleRate:config:)` with `magnitudeSpectrogram(_ samples: [Float]) -> [[Float]]` (frames x 513), `spectralCentroid(_ mag: [[Float]]) -> [Float]` (per frame, Hz), `mfcc(_ mag: [[Float]]) -> [[Float]]` (frames x 13), plus static `hzToMel`, `melToHz`, `melFilterbank(sampleRate:fftSize:melBands:) -> [[Float]]`, `dctII(_:) -> [Float]`.

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/SpectralAnalyzerTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceAudio

final class SpectralAnalyzerTests: XCTestCase {
    let analyzer = SpectralAnalyzer(sampleRate: 16_000)

    func testSpectrogramShape() {
        let mag = analyzer.magnitudeSpectrogram(TestSignals.sine(frequency: 1000, seconds: 1.0))
        XCTAssertEqual(mag.count, 51) // 1 + 16000 / 320 (librosa center=True)
        XCTAssertEqual(mag[0].count, 513)
    }

    func testCentroidOfPureTone() {
        let mag = analyzer.magnitudeSpectrogram(TestSignals.sine(frequency: 1000, seconds: 1.0))
        let c = analyzer.spectralCentroid(mag)
        let middle = c[5..<(c.count - 5)]
        let mean = middle.reduce(0, +) / Float(middle.count)
        XCTAssertEqual(mean, 1000, accuracy: 50)
    }

    func testCentroidOfSilenceIsZero() {
        let mag = analyzer.magnitudeSpectrogram(TestSignals.silence(seconds: 0.5))
        XCTAssertTrue(analyzer.spectralCentroid(mag).allSatisfy { $0 == 0 })
    }

    func testSlaneyMelRoundTrip() {
        for hz: Float in [50, 500, 1000, 2500, 7000] {
            XCTAssertEqual(SpectralAnalyzer.melToHz(SpectralAnalyzer.hzToMel(hz)), hz, accuracy: 0.01)
        }
        XCTAssertEqual(SpectralAnalyzer.hzToMel(1000), 15, accuracy: 1e-4) // 1000 / (200/3)
    }

    func testMelFilterbankShapeAndFirstBand() {
        let fb = SpectralAnalyzer.melFilterbank(sampleRate: 16_000, fftSize: 1024, melBands: 26)
        XCTAssertEqual(fb.count, 26)
        XCTAssertEqual(fb[0].count, 513)
        XCTAssertTrue(fb.allSatisfy { $0.reduce(0, +) > 0 })
        // First band peaks at melToHz(melMax/27) ≈ 111.7 Hz -> bin 7 (bin width 15.625 Hz)
        let peakBin = fb[0].indices.max { fb[0][$0] < fb[0][$1] }!
        XCTAssertEqual(peakBin, 7)
    }

    func testDctIIOrtho() {
        let y = SpectralAnalyzer.dctII([1, 0, 0, 0])
        XCTAssertEqual(y[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(y[1], 0.65328, accuracy: 1e-4) // sqrt(2/4) * cos(pi/8)
    }

    func testMfccShape() {
        let mag = analyzer.magnitudeSpectrogram(TestSignals.sine(frequency: 1000, seconds: 0.5))
        let m = analyzer.mfcc(mag)
        XCTAssertEqual(m.count, mag.count)
        XCTAssertEqual(m[0].count, 13)
        XCTAssertTrue(m.flatMap { $0 }.allSatisfy { $0.isFinite })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter SpectralAnalyzerTests 2>&1 | tail -5`
Expected: compile error, `SpectralAnalyzer` not found.

- [ ] **Step 3: Implement SpectralAnalyzer**

`Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/SpectralAnalyzer.swift`:
```swift
import Accelerate
import Foundation

public struct SpectralConfig: Equatable {
    public var fftSize = 1024
    public var hop = 320
    public var melBands = 26
    public var mfccCount = 13
    public var topDb: Float = 80

    public init() {}
}

/// STFT-based features that mirror librosa defaults so the Python oracle can check them.
public final class SpectralAnalyzer {
    public let sampleRate: Double
    public let config: SpectralConfig
    private let dft: vDSP.DFT<Float>
    private let window: [Float]
    private let melFilters: [[Float]]
    private let binHz: [Float]

    public init(sampleRate: Double, config: SpectralConfig = .init()) {
        self.sampleRate = sampleRate
        self.config = config
        let n = config.fftSize
        dft = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
        // Periodic Hann, same as scipy.signal.get_window("hann", n, fftbins=True).
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
        binHz = (0...(n / 2)).map { Float($0) * Float(sampleRate) / Float(n) }
        melFilters = Self.melFilterbank(sampleRate: sampleRate, fftSize: n, melBands: config.melBands)
    }

    public var binCount: Int { config.fftSize / 2 + 1 }

    /// Magnitude spectrogram (frames x bins). Zero-pads fftSize/2 on both sides like librosa center=True, pad_mode="constant".
    public func magnitudeSpectrogram(_ samples: [Float]) -> [[Float]] {
        let n = config.fftSize
        let pad = n / 2
        let x = [Float](repeating: 0, count: pad) + samples + [Float](repeating: 0, count: pad)
        guard x.count >= n else { return [] }
        let frameCount = 1 + (x.count - n) / config.hop
        let zeros = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        var out: [[Float]] = []
        out.reserveCapacity(frameCount)
        for t in 0..<frameCount {
            let s = t * config.hop
            let frame = vDSP.multiply(Array(x[s..<(s + n)]), window)
            dft.transform(inputReal: frame, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
            var mag = [Float](repeating: 0, count: binCount)
            for k in 0..<binCount { mag[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
            out.append(mag)
        }
        return out
    }

    /// Per-frame spectral centroid in Hz (librosa.feature.spectral_centroid on a magnitude spectrogram).
    public func spectralCentroid(_ mag: [[Float]]) -> [Float] {
        mag.map { m in
            let total = vDSP.sum(m)
            return total > 0 ? vDSP.dot(m, binHz) / total : 0
        }
    }

    /// Per-frame MFCCs: power spectrum -> slaney mel bands -> 10*log10 with top_db clipping -> DCT-II ortho -> first mfccCount.
    public func mfcc(_ mag: [[Float]]) -> [[Float]] {
        guard !mag.isEmpty else { return [] }
        var logMel: [[Float]] = mag.map { m in
            let power = vDSP.multiply(m, m)
            return melFilters.map { f in 10 * log10(max(vDSP.dot(f, power), 1e-10)) }
        }
        let peak = logMel.flatMap { $0 }.max() ?? 0
        let floorDb = peak - config.topDb
        logMel = logMel.map { row in row.map { max($0, floorDb) } }
        return logMel.map { Array(Self.dctII($0).prefix(config.mfccCount)) }
    }

    // MARK: - Slaney mel scale (librosa htk=False)

    private static let fSp: Float = 200.0 / 3
    private static let minLogHz: Float = 1000
    private static let minLogMel: Float = 1000 / (200.0 / 3)
    private static let logStep: Float = Float(log(6.4)) / 27

    static func hzToMel(_ hz: Float) -> Float {
        hz < minLogHz ? hz / fSp : minLogMel + log(hz / minLogHz) / logStep
    }

    static func melToHz(_ mel: Float) -> Float {
        mel < minLogMel ? mel * fSp : minLogHz * exp(logStep * (mel - minLogMel))
    }

    /// librosa.filters.mel(sr, n_fft, n_mels, fmin=0, fmax=sr/2, htk=False, norm="slaney"). Returns bands x bins.
    static func melFilterbank(sampleRate: Double, fftSize: Int, melBands: Int) -> [[Float]] {
        let bins = fftSize / 2 + 1
        let fftHz = (0..<bins).map { Float($0) * Float(sampleRate) / Float(fftSize) }
        let melMin = hzToMel(0)
        let melMax = hzToMel(Float(sampleRate) / 2)
        let melPoints = (0..<(melBands + 2)).map { melToHz(melMin + (melMax - melMin) * Float($0) / Float(melBands + 1)) }
        var filters: [[Float]] = []
        for i in 0..<melBands {
            let lower = melPoints[i], center = melPoints[i + 1], upper = melPoints[i + 2]
            let enorm = 2 / (upper - lower)
            filters.append(fftHz.map { f in
                let up = (f - lower) / (center - lower)
                let down = (upper - f) / (upper - center)
                return max(0, min(up, down)) * enorm
            })
        }
        return filters
    }

    /// scipy.fftpack.dct(x, type=2, norm="ortho")
    static func dctII(_ x: [Float]) -> [Float] {
        let n = x.count
        guard n > 0 else { return [] }
        return (0..<n).map { k in
            var acc: Float = 0
            for i in 0..<n {
                acc += x[i] * cos(Float.pi * Float(k) * (2 * Float(i) + 1) / (2 * Float(n)))
            }
            let scale: Float = k == 0 ? (1 / Float(n)).squareRoot() : (2 / Float(n)).squareRoot()
            return scale * acc
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter SpectralAnalyzerTests 2>&1 | tail -8`
Expected: `Executed 7 tests, with 0 failures`. A deprecation warning on `vDSP.DFT` is acceptable.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(audio): SpectralAnalyzer with librosa-compatible centroid and MFCC

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: VocalFeatures and FeatureExtractor, checked against the oracle

**Files:**
- Create: `Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/VocalFeatures.swift`, `Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/FeatureExtractor.swift`
- Create: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/FeatureExtractorTests.swift`

**Interfaces:**
- Consumes: `AudioBuffer`, `Segment`, `Segmenter`, `PitchTracker`, `SpectralAnalyzer`, `Fixtures/cat1_oracle.json`.
- Produces: `VocalFeatures` (Codable, Equatable) with fields `durationS: Double, f0Mean: Double?, f0Min: Double?, f0Max: Double?, f0Slope: Double?, voicedFraction: Double, rmsDb: Double, spectralCentroidHz: Double, mfcc: [Double]`, `VocalFeatures.vectorColumns: [String]` (21 names), `VocalFeatures.vector: [Double]` (21 values, NaN for nil); `FeatureExtractor.features(_ buffer: AudioBuffer, segment: Segment) -> VocalFeatures`; `FeatureExtractor.analyze(_ buffer: AudioBuffer, segmenter: SegmenterConfig) -> [(segment: Segment, features: VocalFeatures)]`.

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/FeatureExtractorTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceAudio

final class FeatureExtractorTests: XCTestCase {
    /// Linear chirp from f0 to f1 over `seconds`.
    private func chirp(from f0: Double, to f1: Double, seconds: Double, sr: Double = 16_000) -> [Float] {
        let n = Int(seconds * sr)
        var phase = 0.0
        return (0..<n).map { i in
            let f = f0 + (f1 - f0) * Double(i) / Double(n)
            phase += 2 * .pi * f / sr
            return 0.5 * Float(sin(phase))
        }
    }

    func testRisingChirpHasPositiveSlope() {
        let b = AudioBuffer(samples: chirp(from: 300, to: 600, seconds: 0.5), sampleRate: 16_000)
        let f = FeatureExtractor.features(b, segment: Segment(startS: 0, endS: 0.5))
        XCTAssertEqual(f.durationS, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(f.voicedFraction, 0.8)
        XCTAssertEqual(f.f0Mean ?? 0, 450, accuracy: 45)
        XCTAssertGreaterThan(f.f0Slope ?? 0, 300) // Hz per second, nominal 600
        XCTAssertLessThan(f.f0Min ?? 0, f.f0Max ?? 0)
        XCTAssertEqual(f.rmsDb, -9.0, accuracy: 0.5) // amplitude 0.5 sine
        XCTAssertEqual(f.mfcc.count, 13)
    }

    func testSilenceIsUnvoiced() {
        let b = AudioBuffer(samples: TestSignals.silence(seconds: 0.5), sampleRate: 16_000)
        let f = FeatureExtractor.features(b, segment: Segment(startS: 0, endS: 0.5))
        XCTAssertNil(f.f0Mean)
        XCTAssertNil(f.f0Slope)
        XCTAssertEqual(f.voicedFraction, 0)
        XCTAssertEqual(f.spectralCentroidHz, 0)
    }

    func testVectorLayout() {
        let f = VocalFeatures(durationS: 0.3, f0Mean: nil, f0Min: nil, f0Max: nil, f0Slope: nil,
                              voicedFraction: 0, rmsDb: -20, spectralCentroidHz: 1500, mfcc: Array(repeating: 1, count: 13))
        XCTAssertEqual(VocalFeatures.vectorColumns.count, 21)
        XCTAssertEqual(f.vector.count, 21)
        XCTAssertEqual(f.vector[0], 0.3)
        XCTAssertTrue(f.vector[1].isNaN && f.vector[4].isNaN)
        XCTAssertEqual(f.vector[7], 1500)
        XCTAssertEqual(f.vector[8], 1)
        XCTAssertEqual(VocalFeatures.vectorColumns[8], "mfcc0")
    }

    func testAnalyzeSegmentsAndExtracts() throws {
        let b = try AudioLoader.load(TestSignals.fixtureURL("cat1_16k.wav"))
        let results = FeatureExtractor.analyze(b)
        XCTAssertTrue((10...14).contains(results.count))
        XCTAssertTrue(results.allSatisfy { $0.features.mfcc.count == 13 })
    }

    struct Oracle: Decodable {
        struct Seg: Decodable {
            let startS: Double, endS: Double, rmsDb: Double, spectralCentroidHz: Double
            let mfcc: [Double], f0Mean: Double?, voicedFrames: Int
        }
        let sampleRate: Double
        let segments: [Seg]
    }

    func testMatchesLibrosaOracle() throws {
        let data = try Data(contentsOf: TestSignals.fixtureURL("cat1_oracle.json"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: data)
        let buffer = try AudioLoader.load(TestSignals.fixtureURL("cat1_16k.wav"))
        var voicingDisagreements = 0
        for o in oracle.segments {
            let f = FeatureExtractor.features(buffer, segment: Segment(startS: o.startS, endS: o.endS))
            let tag = "segment at \(o.startS)s"
            XCTAssertEqual(f.rmsDb, o.rmsDb, accuracy: 1.0, tag)
            XCTAssertEqual(f.spectralCentroidHz, o.spectralCentroidHz, accuracy: 0.10 * o.spectralCentroidHz, tag)
            XCTAssertEqual(f.mfcc[0], o.mfcc[0], accuracy: 0.10 * abs(o.mfcc[0]) + 1.0, tag)
            for i in 1..<13 {
                XCTAssertEqual(f.mfcc[i], o.mfcc[i], accuracy: 2.5, "\(tag) mfcc\(i)")
            }
            switch (f.f0Mean, o.f0Mean) {
            case let (a?, b?): XCTAssertEqual(a, b, accuracy: 0.15 * b, "\(tag) f0Mean")
            case (nil, nil): break
            default: voicingDisagreements += 1
            }
        }
        XCTAssertLessThanOrEqual(voicingDisagreements, 3, "YIN vs pyin voicing disagreements")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter FeatureExtractorTests 2>&1 | tail -5`
Expected: compile error, `VocalFeatures` not found.

- [ ] **Step 3: Implement VocalFeatures and FeatureExtractor**

`Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/VocalFeatures.swift`:
```swift
import Foundation

/// Acoustic features of one vocalization. Optional f0 fields are nil when fewer than 3 frames were voiced.
public struct VocalFeatures: Codable, Equatable {
    public var durationS: Double
    public var f0Mean: Double?
    public var f0Min: Double?
    public var f0Max: Double?
    /// Linear-fit slope of f0 over time, Hz per second. Positive = rising.
    public var f0Slope: Double?
    /// Fraction of pitch frames that were voiced (0 to 1).
    public var voicedFraction: Double
    public var rmsDb: Double
    public var spectralCentroidHz: Double
    /// 13 mean MFCCs.
    public var mfcc: [Double]

    public init(durationS: Double, f0Mean: Double?, f0Min: Double?, f0Max: Double?, f0Slope: Double?,
                voicedFraction: Double, rmsDb: Double, spectralCentroidHz: Double, mfcc: [Double]) {
        self.durationS = durationS
        self.f0Mean = f0Mean
        self.f0Min = f0Min
        self.f0Max = f0Max
        self.f0Slope = f0Slope
        self.voicedFraction = voicedFraction
        self.rmsDb = rmsDb
        self.spectralCentroidHz = spectralCentroidHz
        self.mfcc = mfcc
    }

    public static let mfccCount = 13

    /// Column names of `vector`, in order.
    public static let vectorColumns: [String] =
        ["durationS", "f0Mean", "f0Min", "f0Max", "f0Slope", "voicedFraction", "rmsDb", "spectralCentroidHz"]
        + (0..<mfccCount).map { "mfcc\($0)" }

    /// Fixed-order numeric vector for the stats package. Missing values are NaN.
    public var vector: [Double] {
        var v: [Double] = [durationS, f0Mean ?? .nan, f0Min ?? .nan, f0Max ?? .nan, f0Slope ?? .nan,
                           voicedFraction, rmsDb, spectralCentroidHz]
        v += (0..<Self.mfccCount).map { $0 < mfcc.count ? mfcc[$0] : .nan }
        return v
    }
}
```

`Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/FeatureExtractor.swift`:
```swift
import Foundation

public enum FeatureExtractor {
    public static let minVoicedFrames = 3

    /// Features for one segment of a buffer.
    public static func features(_ buffer: AudioBuffer, segment: Segment,
                                pitch: PitchConfig = .init(), spectral: SpectralConfig = .init()) -> VocalFeatures {
        let samples = Array(buffer.slice(startS: segment.startS, endS: segment.endS))
        let sr = buffer.sampleRate

        // Pitch statistics.
        let frames = PitchTracker.track(samples, sampleRate: sr, config: pitch)
        let voiced = frames.compactMap { frame in frame.f0Hz.map { (t: frame.timeS, f0: $0) } }
        let voicedFraction = frames.isEmpty ? 0 : Double(voiced.count) / Double(frames.count)
        var f0Mean: Double?, f0Min: Double?, f0Max: Double?, f0Slope: Double?
        if voiced.count >= minVoicedFrames {
            let f0s = voiced.map(\.f0)
            f0Mean = f0s.reduce(0, +) / Double(f0s.count)
            f0Min = f0s.min()
            f0Max = f0s.max()
            f0Slope = linearSlope(x: voiced.map(\.t), y: f0s)
        }

        // Loudness.
        let meanSquare = samples.isEmpty ? 0 : samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let rmsDb = 20 * log10(max(meanSquare.squareRoot(), 1e-8))

        // Spectral shape.
        let analyzer = SpectralAnalyzer(sampleRate: sr, config: spectral)
        let mag = analyzer.magnitudeSpectrogram(samples)
        let centroid = analyzer.spectralCentroid(mag)
        let centroidMean = centroid.isEmpty ? 0 : Double(centroid.reduce(0, +)) / Double(centroid.count)
        let mfccFrames = analyzer.mfcc(mag)
        var mfccMean = [Double](repeating: 0, count: spectral.mfccCount)
        if !mfccFrames.isEmpty {
            for frame in mfccFrames {
                for (i, v) in frame.enumerated() { mfccMean[i] += Double(v) }
            }
            mfccMean = mfccMean.map { $0 / Double(mfccFrames.count) }
        }

        return VocalFeatures(durationS: segment.durationS, f0Mean: f0Mean, f0Min: f0Min, f0Max: f0Max,
                             f0Slope: f0Slope, voicedFraction: voicedFraction, rmsDb: rmsDb,
                             spectralCentroidHz: centroidMean, mfcc: mfccMean)
    }

    /// Segment a whole buffer and extract features for each event.
    public static func analyze(_ buffer: AudioBuffer, segmenter: SegmenterConfig = .init()) -> [(segment: Segment, features: VocalFeatures)] {
        Segmenter.segment(buffer, config: segmenter).map { ($0, features(buffer, segment: $0)) }
    }

    static func linearSlope(x: [Double], y: [Double]) -> Double {
        let n = Double(x.count)
        guard n > 1 else { return 0 }
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<x.count {
            num += (x[i] - mx) * (y[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        return den > 0 ? num / den : 0
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter FeatureExtractorTests 2>&1 | tail -12`
Expected: `Executed 5 tests, with 0 failures`. If `testMatchesLibrosaOracle` fails on MFCCs, check in this order: periodic vs symmetric Hann window, `top_db` clipping applied over the whole spectrogram (not per frame), slaney `enorm`, DCT scaling. Do not loosen a tolerance by more than 2x, and record any loosening in the commit message.

- [ ] **Step 5: Run the whole package and commit**

Run: `scripts/test-packages.sh`
Expected: AnimalVoiceAudio `Executed 25 tests, with 0 failures` (or the running total), AnimalVoiceStats 1 test passing.

```bash
git add -A
git commit -m "feat(audio): FeatureExtractor with VocalFeatures, validated against librosa oracle

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Recorder

**Files:**
- Create: `Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/Recorder.swift`
- Create: `Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/RecorderTests.swift`

**Interfaces:**
- Produces: `@MainActor final class Recorder: NSObject, ObservableObject` with `@Published isRecording: Bool`, `@Published levelDb: Float`, `@Published elapsedS: TimeInterval`, `static func requestPermission() async -> Bool`, `func start() throws -> URL`, `func stop() -> URL?`, `static let settings: [String: Any]`, `RecorderError`.
- Note: the spec says "wraps AVAudioEngine"; this uses `AVAudioRecorder`, which writes m4a and meters natively with far less code. Same external behavior. Record this deviation in the commit message.

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceAudio/Tests/AnimalVoiceAudioTests/RecorderTests.swift`:
```swift
import AVFoundation
import XCTest
@testable import AnimalVoiceAudio

final class RecorderTests: XCTestCase {
    @MainActor
    func testInitialStateAndStopBeforeStart() {
        let r = Recorder()
        XCTAssertFalse(r.isRecording)
        XCTAssertEqual(r.levelDb, -160)
        XCTAssertNil(r.stop())
    }

    func testSettingsAreAacMono() {
        XCTAssertEqual(Recorder.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Recorder.settings[AVNumberOfChannelsKey] as? Int, 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter RecorderTests 2>&1 | tail -5`
Expected: compile error, `Recorder` not found.

- [ ] **Step 3: Implement Recorder**

`Packages/AnimalVoiceAudio/Sources/AnimalVoiceAudio/Recorder.swift`:
```swift
import AVFoundation
import Foundation

public enum RecorderError: Error {
    case alreadyRecording
    case sessionFailed(String)
}

/// Records mono AAC to a temporary .m4a and publishes a live level for the waveform view.
@MainActor
public final class Recorder: NSObject, ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var levelDb: Float = -160
    @Published public private(set) var elapsedS: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    public override init() { super.init() }

    public static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    public static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return true
        #endif
    }

    @discardableResult
    public func start() throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw RecorderError.sessionFailed(error.localizedDescription)
        }
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        let r = try AVAudioRecorder(url: url, settings: Self.settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw RecorderError.sessionFailed("AVAudioRecorder.record() returned false") }
        recorder = r
        fileURL = url
        isRecording = true
        elapsedS = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return url
    }

    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        levelDb = r.averagePower(forChannel: 0)
        elapsedS = r.currentTime
    }

    /// Stops recording and returns the file URL, or nil if nothing was recording.
    public func stop() -> URL? {
        guard isRecording, let r = recorder else { return nil }
        r.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil
        isRecording = false
        levelDb = -160
        return fileURL
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/AnimalVoiceAudio && swift test --filter RecorderTests 2>&1 | tail -5`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(audio): Recorder (AVAudioRecorder, m4a, live level; deviates from spec's AVAudioEngine for simplicity)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Standardizer (NaN-aware z-scoring)

**Files:**
- Create: `Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/Standardizer.swift`
- Create: `Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/StandardizerTests.swift`

**Interfaces:**
- Produces: `Standardizer(means: [Double], stds: [Double])`, `Standardizer.fit(_ rows: [[Double]]) -> Standardizer` (ignores NaN per column, std floor 1), `func transform(_ row: [Double]) -> [Double]` (NaN becomes 0, which is the column mean in z-space).

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/StandardizerTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceStats

final class StandardizerTests: XCTestCase {
    func testFitIgnoresNaNAndTransformsMissingToZero() {
        let s = Standardizer.fit([[1, 10], [3, 30], [.nan, 50]])
        XCTAssertEqual(s.means, [2, 30])
        XCTAssertEqual(s.stds[0], 1, accuracy: 1e-9)
        XCTAssertEqual(s.stds[1], 16.3299, accuracy: 1e-3) // population std of 10, 30, 50
        XCTAssertEqual(s.transform([3, .nan]), [1, 0])
    }

    func testConstantColumnGetsUnitStd() {
        let s = Standardizer.fit([[5, 1], [5, 2]])
        XCTAssertEqual(s.stds[0], 1)
        XCTAssertEqual(s.transform([5, 1.5]), [0, 0])
    }

    func testEmptyFit() {
        let s = Standardizer.fit([])
        XCTAssertEqual(s.means, [])
        XCTAssertEqual(s.transform([1, 2]), [])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceStats && swift test --filter StandardizerTests 2>&1 | tail -5`
Expected: compile error, `Standardizer` not found.

- [ ] **Step 3: Implement**

`Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/Standardizer.swift`:
```swift
import Foundation

/// Column-wise z-scoring. NaN cells are ignored when fitting and map to 0 (the mean) when transforming.
public struct Standardizer: Equatable {
    public let means: [Double]
    public let stds: [Double]

    public init(means: [Double], stds: [Double]) {
        self.means = means
        self.stds = stds
    }

    public static func fit(_ rows: [[Double]]) -> Standardizer {
        guard let width = rows.first?.count else { return Standardizer(means: [], stds: []) }
        var means = [Double](repeating: 0, count: width)
        var stds = [Double](repeating: 1, count: width)
        for j in 0..<width {
            let col = rows.compactMap { $0.count > j && !$0[j].isNaN ? $0[j] : nil }
            guard !col.isEmpty else { continue }
            let m = col.reduce(0, +) / Double(col.count)
            let v = col.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(col.count)
            means[j] = m
            let sd = v.squareRoot()
            stds[j] = sd > 1e-9 ? sd : 1
        }
        return Standardizer(means: means, stds: stds)
    }

    public func transform(_ row: [Double]) -> [Double] {
        (0..<means.count).map { j in
            guard j < row.count, !row[j].isNaN else { return 0 }
            return (row[j] - means[j]) / stds[j]
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/AnimalVoiceStats && swift test --filter StandardizerTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(stats): NaN-aware Standardizer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: KNNClassifier

**Files:**
- Create: `Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/KNNClassifier.swift`
- Create: `Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/KNNClassifierTests.swift`

**Interfaces:**
- Consumes: `LabeledSample`, `Standardizer`.
- Produces: `Prediction(probabilities: [String: Double], neighborIds: [UUID])` with `best: (label: String, probability: Double)?` (deterministic tie-break by label name); `KNNClassifier(k: Int = 5)` with `predict(query: [Double], training: [LabeledSample], standardizer: Standardizer) -> Prediction`.

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/KNNClassifierTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceStats

enum TestData {
    /// Two well-separated clusters in 2-D: "a" around (0, 0), "b" around (10, 10). Deterministic jitter.
    static func clusters(perClass n: Int = 8) -> [LabeledSample] {
        var out: [LabeledSample] = []
        for i in 0..<n {
            let j = Double(i % 4) * 0.25
            out.append(LabeledSample(features: [0 + j, 0 - j], label: "a"))
            out.append(LabeledSample(features: [10 + j, 10 - j], label: "b"))
        }
        return out
    }
}

final class KNNClassifierTests: XCTestCase {
    func testPredictsNearestCluster() {
        let training = TestData.clusters()
        let st = Standardizer.fit(training.map(\.features))
        let p = KNNClassifier(k: 5).predict(query: [0.5, 0.5], training: training, standardizer: st)
        XCTAssertEqual(p.best?.label, "a")
        XCTAssertGreaterThan(p.best?.probability ?? 0, 0.99)
        XCTAssertEqual(p.neighborIds.count, 5)
        let byId = Dictionary(uniqueKeysWithValues: training.map { ($0.id, $0.label) })
        XCTAssertTrue(p.neighborIds.allSatisfy { byId[$0] == "a" })
    }

    func testMidpointIsUncertain() {
        let training = TestData.clusters()
        let st = Standardizer.fit(training.map(\.features))
        let p = KNNClassifier(k: 8).predict(query: [5, 5], training: training, standardizer: st)
        XCTAssertEqual(p.probabilities["a"] ?? 0, 0.5, accuracy: 0.2)
    }

    func testEmptyTraining() {
        let p = KNNClassifier().predict(query: [1, 2], training: [], standardizer: Standardizer(means: [0, 0], stds: [1, 1]))
        XCTAssertTrue(p.probabilities.isEmpty)
        XCTAssertNil(p.best)
    }

    func testKLargerThanTrainingUsesAll() {
        let training = Array(TestData.clusters().prefix(3))
        let st = Standardizer.fit(training.map(\.features))
        let p = KNNClassifier(k: 5).predict(query: [0, 0], training: training, standardizer: st)
        XCTAssertEqual(p.neighborIds.count, 3)
        XCTAssertEqual(p.probabilities.values.reduce(0, +), 1, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceStats && swift test --filter KNNClassifierTests 2>&1 | tail -5`
Expected: compile error, `KNNClassifier` not found.

- [ ] **Step 3: Implement**

`Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/KNNClassifier.swift`:
```swift
import Foundation

public struct Prediction: Equatable {
    /// Probability per label, sums to 1 (empty when there is no training data).
    public var probabilities: [String: Double]
    /// Ids of the nearest training samples, closest first.
    public var neighborIds: [UUID]

    public init(probabilities: [String: Double], neighborIds: [UUID]) {
        self.probabilities = probabilities
        self.neighborIds = neighborIds
    }

    /// Highest-probability label; ties broken alphabetically so results are stable.
    public var best: (label: String, probability: Double)? {
        probabilities.sorted { $0.key < $1.key }.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

/// Distance-weighted k-nearest-neighbors on standardized features.
public struct KNNClassifier {
    public var k: Int

    public init(k: Int = 5) {
        self.k = k
    }

    public func predict(query: [Double], training: [LabeledSample], standardizer: Standardizer) -> Prediction {
        guard !training.isEmpty else { return Prediction(probabilities: [:], neighborIds: []) }
        let q = standardizer.transform(query)
        let scored = training
            .map { sample -> (LabeledSample, Double) in
                let z = standardizer.transform(sample.features)
                let d = zip(q, z).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
                return (sample, d)
            }
            .sorted { $0.1 < $1.1 }
        let nearest = scored.prefix(max(1, k))
        var weights: [String: Double] = [:]
        for (sample, d) in nearest {
            weights[sample.label, default: 0] += 1 / (d + 1e-6)
        }
        let total = weights.values.reduce(0, +)
        return Prediction(probabilities: weights.mapValues { $0 / total }, neighborIds: nearest.map { $0.0.id })
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/AnimalVoiceStats && swift test --filter KNNClassifierTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(stats): distance-weighted KNNClassifier

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: NaiveBayesClassifier and Ensemble

**Files:**
- Create: `Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/NaiveBayesClassifier.swift`, `Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/Ensemble.swift`
- Create: `Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/NaiveBayesClassifierTests.swift`, `Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/EnsembleTests.swift`

**Interfaces:**
- Consumes: `LabeledSample`, `Standardizer`, `KNNClassifier`, `Prediction`, `TestData.clusters` from Task 9's test file.
- Produces: `NaiveBayesClassifier(varianceFloor: Double = 0.01)` with `predict(query:training:standardizer:) -> [String: Double]`; `Ensemble()` with `predict(query: [Double], training: [LabeledSample]) -> Prediction` (fits its own standardizer, averages kNN and Bayes, neighbor ids from kNN).

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/NaiveBayesClassifierTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceStats

final class NaiveBayesClassifierTests: XCTestCase {
    func testSeparableClusters() {
        let training = TestData.clusters()
        let st = Standardizer.fit(training.map(\.features))
        let p = NaiveBayesClassifier().predict(query: [1, 1], training: training, standardizer: st)
        XCTAssertGreaterThan(p["a"] ?? 0, 0.99)
        XCTAssertEqual(p.values.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testSingleClassIsCertain() {
        let training = TestData.clusters().filter { $0.label == "a" }
        let st = Standardizer.fit(training.map(\.features))
        let p = NaiveBayesClassifier().predict(query: [50, 50], training: training, standardizer: st)
        XCTAssertEqual(p["a"] ?? 0, 1, accuracy: 1e-9)
    }

    func testEmptyTraining() {
        XCTAssertTrue(NaiveBayesClassifier().predict(query: [1], training: [], standardizer: Standardizer(means: [0], stds: [1])).isEmpty)
    }
}
```

`Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/EnsembleTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceStats

final class EnsembleTests: XCTestCase {
    func testAveragesAndKeepsNeighbors() {
        let training = TestData.clusters()
        let p = Ensemble().predict(query: [9, 9], training: training)
        XCTAssertEqual(p.best?.label, "b")
        XCTAssertGreaterThan(p.best?.probability ?? 0, 0.95)
        XCTAssertEqual(p.probabilities.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(p.neighborIds.count, 5)
        XCTAssertEqual(Set(p.probabilities.keys), ["a", "b"])
    }

    func testHandlesNaNInQueryAndTraining() {
        var training = TestData.clusters()
        training[0] = LabeledSample(id: training[0].id, features: [.nan, 0], label: "a")
        let p = Ensemble().predict(query: [.nan, 10], training: training)
        XCTAssertEqual(p.best?.label, "b")
        XCTAssertTrue(p.probabilities.values.allSatisfy { $0.isFinite })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceStats && swift test --filter "NaiveBayesClassifierTests|EnsembleTests" 2>&1 | tail -5`
Expected: compile errors, `NaiveBayesClassifier` and `Ensemble` not found.

- [ ] **Step 3: Implement**

`Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/NaiveBayesClassifier.swift`:
```swift
import Foundation

/// Gaussian naive Bayes on standardized features, with a variance floor so tiny classes do not become overconfident.
public struct NaiveBayesClassifier {
    public var varianceFloor: Double

    public init(varianceFloor: Double = 0.01) {
        self.varianceFloor = varianceFloor
    }

    public func predict(query: [Double], training: [LabeledSample], standardizer: Standardizer) -> [String: Double] {
        guard !training.isEmpty else { return [:] }
        let q = standardizer.transform(query)
        let groups = Dictionary(grouping: training, by: \.label)
        let n = Double(training.count)
        var logPosterior: [String: Double] = [:]
        for (label, samples) in groups {
            let z = samples.map { standardizer.transform($0.features) }
            let m = Double(z.count)
            var lp = log(m / n)
            for j in 0..<q.count {
                let col = z.map { $0[j] }
                let mu = col.reduce(0, +) / m
                let variance = max(col.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / m, varianceFloor)
                lp += -0.5 * log(2 * .pi * variance) - (q[j] - mu) * (q[j] - mu) / (2 * variance)
            }
            logPosterior[label] = lp
        }
        let maxLog = logPosterior.values.max() ?? 0
        let unnormalized = logPosterior.mapValues { exp($0 - maxLog) }
        let total = unnormalized.values.reduce(0, +)
        return unnormalized.mapValues { $0 / total }
    }
}
```

`Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/Ensemble.swift`:
```swift
import Foundation

/// Average of kNN and naive Bayes probabilities. Fits the standardizer on the training data each call; n is small.
public struct Ensemble {
    public var knn: KNNClassifier
    public var bayes: NaiveBayesClassifier

    public init(knn: KNNClassifier = KNNClassifier(), bayes: NaiveBayesClassifier = NaiveBayesClassifier()) {
        self.knn = knn
        self.bayes = bayes
    }

    public func predict(query: [Double], training: [LabeledSample]) -> Prediction {
        let standardizer = Standardizer.fit(training.map(\.features))
        let a = knn.predict(query: query, training: training, standardizer: standardizer)
        let b = bayes.predict(query: query, training: training, standardizer: standardizer)
        let labels = Set(a.probabilities.keys).union(b.probabilities.keys)
        var probabilities: [String: Double] = [:]
        for label in labels {
            probabilities[label] = 0.5 * (a.probabilities[label] ?? 0) + 0.5 * (b.probabilities[label] ?? 0)
        }
        return Prediction(probabilities: probabilities, neighborIds: a.neighborIds)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/AnimalVoiceStats && swift test --filter "NaiveBayesClassifierTests|EnsembleTests" 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(stats): Gaussian NaiveBayesClassifier and kNN+Bayes Ensemble

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Evaluator (leave-one-out) and Readiness

**Files:**
- Create: `Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/Evaluator.swift`, `Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/Readiness.swift`
- Create: `Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/EvaluatorTests.swift`, `Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/ReadinessTests.swift`

**Interfaces:**
- Consumes: `Ensemble`, `LabeledSample`.
- Produces: `Evaluation(accuracy: Double, perClassRecall: [String: Double], n: Int)`; `Evaluator.leaveOneOut(_ samples: [LabeledSample], ensemble: Ensemble = Ensemble()) -> Evaluation`; `ReadinessStatus` enum (`.ready(labels: [String])`, `.notReady(message: String, needed: [String: Int])`); `Readiness.minPerLabel = 5`, `Readiness.minLabels = 2`, `Readiness.check(labelCounts: [String: Int]) -> ReadinessStatus`.

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/EvaluatorTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceStats

final class EvaluatorTests: XCTestCase {
    func testSeparableDataScoresHigh() {
        let e = Evaluator.leaveOneOut(TestData.clusters())
        XCTAssertEqual(e.n, 16)
        XCTAssertGreaterThan(e.accuracy, 0.9)
        XCTAssertGreaterThan(e.perClassRecall["a"] ?? 0, 0.9)
        XCTAssertGreaterThan(e.perClassRecall["b"] ?? 0, 0.9)
    }

    func testFewerThanTwoSamplesIsZero() {
        let e = Evaluator.leaveOneOut([LabeledSample(features: [1], label: "a")])
        XCTAssertEqual(e.accuracy, 0)
        XCTAssertEqual(e.n, 1)
    }
}
```

`Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/ReadinessTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceStats

final class ReadinessTests: XCTestCase {
    func testReadyAtBoundary() {
        XCTAssertEqual(Readiness.check(labelCounts: ["hungry": 5, "annoyed": 5, "greeting": 1]), .ready(labels: ["annoyed", "hungry"]))
    }

    func testNotReadyReportsNeeded() {
        let status = Readiness.check(labelCounts: ["hungry": 5, "annoyed": 4])
        guard case let .notReady(message, needed) = status else { return XCTFail("expected notReady") }
        XCTAssertEqual(needed, ["annoyed": 1])
        XCTAssertTrue(message.contains("1 of 2"))
    }

    func testEmpty() {
        guard case let .notReady(message, needed) = Readiness.check(labelCounts: [:]) else { return XCTFail() }
        XCTAssertTrue(needed.isEmpty)
        XCTAssertTrue(message.contains("No labeled sounds yet"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceStats && swift test --filter "EvaluatorTests|ReadinessTests" 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Implement**

`Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/Evaluator.swift`:
```swift
import Foundation

public struct Evaluation: Equatable {
    public var accuracy: Double
    public var perClassRecall: [String: Double]
    public var n: Int

    public init(accuracy: Double, perClassRecall: [String: Double], n: Int) {
        self.accuracy = accuracy
        self.perClassRecall = perClassRecall
        self.n = n
    }
}

public enum Evaluator {
    /// Leave-one-out accuracy of the ensemble on an animal's labeled samples. Cheap for n in the hundreds.
    public static func leaveOneOut(_ samples: [LabeledSample], ensemble: Ensemble = Ensemble()) -> Evaluation {
        guard samples.count >= 2 else { return Evaluation(accuracy: 0, perClassRecall: [:], n: samples.count) }
        var correct = 0
        var totalByClass: [String: Int] = [:]
        var correctByClass: [String: Int] = [:]
        for i in samples.indices {
            var training = samples
            let held = training.remove(at: i)
            let prediction = ensemble.predict(query: held.features, training: training)
            totalByClass[held.label, default: 0] += 1
            if prediction.best?.label == held.label {
                correct += 1
                correctByClass[held.label, default: 0] += 1
            }
        }
        var recall: [String: Double] = [:]
        for (label, total) in totalByClass {
            recall[label] = Double(correctByClass[label] ?? 0) / Double(total)
        }
        return Evaluation(accuracy: Double(correct) / Double(samples.count), perClassRecall: recall, n: samples.count)
    }
}
```

`Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/Readiness.swift`:
```swift
import Foundation

public enum ReadinessStatus: Equatable {
    case ready(labels: [String])
    case notReady(message: String, needed: [String: Int])
}

/// Predictions are offered only when at least `minLabels` meanings each have `minPerLabel` labeled sounds.
public enum Readiness {
    public static let minPerLabel = 5
    public static let minLabels = 2

    public static func check(labelCounts: [String: Int]) -> ReadinessStatus {
        let readyLabels = labelCounts.filter { $0.value >= minPerLabel }.keys.sorted()
        if readyLabels.count >= minLabels {
            return .ready(labels: readyLabels)
        }
        let needed = labelCounts.filter { $0.value < minPerLabel }.mapValues { minPerLabel - $0 }
        let message: String
        if labelCounts.isEmpty {
            message = "No labeled sounds yet. Tag at least \(minPerLabel) sounds for each of \(minLabels) meanings."
        } else {
            message = "Not enough data yet: \(readyLabels.count) of \(minLabels) meanings have \(minPerLabel)+ labeled sounds."
        }
        return .notReady(message: message, needed: needed)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/AnimalVoiceStats && swift test --filter "EvaluatorTests|ReadinessTests" 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(stats): leave-one-out Evaluator and Readiness rule

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: ResearchPrior

**Files:**
- Create: `Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/ResearchPrior.swift`
- Create: `Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/ResearchPriorTests.swift`

**Interfaces:**
- Produces: `ResearchPrior.hint(species: String, durationS: Double, f0Mean: Double?, f0Slope: Double?) -> String?` (nil unless `species` contains "cat", case-insensitive) and `ResearchPrior.attribution: String`. Thresholds (0.6 s, 0.8 s, 500 Hz) are app-chosen cutoffs, not from the literature; the direction of the pattern is from the Meowsic project cited in the spec.

- [ ] **Step 1: Write the failing tests**

`Packages/AnimalVoiceStats/Tests/AnimalVoiceStatsTests/ResearchPriorTests.swift`:
```swift
import XCTest
@testable import AnimalVoiceStats

final class ResearchPriorTests: XCTestCase {
    func testShortHighRising() {
        XCTAssertEqual(ResearchPrior.hint(species: "Cat", durationS: 0.4, f0Mean: 700, f0Slope: 200)?.hasPrefix("Short, high, rising"), true)
    }

    func testLongFalling() {
        XCTAssertEqual(ResearchPrior.hint(species: "domestic cat", durationS: 1.2, f0Mean: 400, f0Slope: -150)?.hasPrefix("Long and falling"), true)
    }

    func testNoPatternOrUnvoiced() {
        XCTAssertNil(ResearchPrior.hint(species: "Cat", durationS: 0.7, f0Mean: 600, f0Slope: 10))
        XCTAssertNil(ResearchPrior.hint(species: "Cat", durationS: 0.4, f0Mean: nil, f0Slope: nil))
    }

    func testOtherSpeciesGetNoHint() {
        XCTAssertNil(ResearchPrior.hint(species: "Dog", durationS: 0.4, f0Mean: 700, f0Slope: 200))
        XCTAssertNil(ResearchPrior.hint(species: "", durationS: 0.4, f0Mean: 700, f0Slope: 200))
    }

    func testAttributionMentionsMeowsic() {
        XCTAssertTrue(ResearchPrior.attribution.contains("Meowsic"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/AnimalVoiceStats && swift test --filter ResearchPriorTests 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Implement**

`Packages/AnimalVoiceStats/Sources/AnimalVoiceStats/ResearchPrior.swift`:
```swift
import Foundation

/// A one-line hint from published cat-vocalization research. Always shown with `attribution`; never presented as a prediction for this animal.
public enum ResearchPrior {
    public static let attribution =
        "General pattern reported by the Lund University Meowsic project (Schötz et al.). Not a prediction for your animal."

    /// The finding is about domestic cats, so any other species gets nil.
    public static func hint(species: String, durationS: Double, f0Mean: Double?, f0Slope: Double?) -> String? {
        guard species.lowercased().contains("cat"), let f0 = f0Mean, let slope = f0Slope else { return nil }
        if durationS < 0.6, slope > 0, f0 > 500 {
            return "Short, high, rising. In published cat studies this pattern is common in requests and greetings."
        }
        if durationS > 0.8, slope < 0 {
            return "Long and falling. In published cat studies this pattern is common in distress or complaint."
        }
        return nil
    }
}
```

- [ ] **Step 4: Run all package tests and commit**

Run: `scripts/test-packages.sh`
Expected: both packages pass with 0 failures.

```bash
git add -A
git commit -m "feat(stats): ResearchPrior hint from Meowsic findings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---


### Task 13: Voice models, tag seed, tag propagation, registration

**Files:**
- Create: `App/Models/VoiceRecording.swift`, `App/Models/Vocalization.swift`, `App/Models/VoiceTag.swift`, `App/Persistence/VoiceTagSeed.swift`, `App/Persistence/TagPropagation.swift`
- Modify: `App/Persistence/PersistenceController.swift` (append three model types), `App/AnimalTrackerApp.swift` (append seed to `Seeds.all`), `App/Persistence/AnimalDeletionPolicy.swift` (add "voice recordings" count)
- Create: `AppTests/VoiceModelTests.swift`, `AppTests/VoiceTagSeedTests.swift`, `AppTests/TagPropagationTests.swift`

**Interfaces:**
- Consumes: `Segment`, `VocalFeatures` (AnimalVoiceAudio); `Animal`, `VoiceStatus`, `VoiceTagKind`, `PersistenceController`, `Seeds`, `AnimalDeletionPolicy`, `TestSupport`.
- Produces: `VoiceRecording(audioFilename:durationS:recordedAt:animal:)` with `status: VoiceStatus`, `sortedVocalizations`; `Vocalization(segment:features:)` with `durationS`, `features: VocalFeatures`, `featureVector: [Double]`; `VoiceTag(kind:name:isBuiltIn:sortOrder:)` with `kind`; `VoiceTagSeed.activities`, `.meanings`, `.unknownMeaning = "Unknown"`, `seedIfNeeded(context:) throws -> Int`, `run(_ context: ModelContext)`; `TagPropagation.apply(to recording: VoiceRecording)`, `differsFromRecording(_:) -> Bool`, `resetOverride(_:)`; `VoiceFixtures.features(duration:f0:slope:) -> VocalFeatures` test helper.

- [ ] **Step 1: Write the failing tests**

`AppTests/VoiceModelTests.swift`:
```swift
import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

enum VoiceFixtures {
    static func features(duration: Double = 0.4, f0: Double? = 600, slope: Double? = 100) -> VocalFeatures {
        VocalFeatures(durationS: duration, f0Mean: f0, f0Min: f0.map { $0 - 50 }, f0Max: f0.map { $0 + 50 }, f0Slope: slope,
                      voicedFraction: f0 == nil ? 0 : 0.9, rmsDb: -20, spectralCentroidHz: 1500, mfcc: Array(repeating: 0, count: 13))
    }
}

@MainActor
final class VoiceModelTests: XCTestCase {
    func testRoundTripWithRelationships() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Miso", species: "cat")
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "abc-audio.m4a", durationS: 1.5, animal: animal)
        context.insert(recording)
        let v = Vocalization(segment: Segment(startS: 0.1, endS: 0.5), features: VoiceFixtures.features())
        v.recording = recording
        context.insert(v)
        try context.save()

        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>())
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].animal?.name, "Miso")
        XCTAssertEqual(recordings[0].sortedVocalizations.count, 1)
        XCTAssertEqual(v.durationS, 0.4, accuracy: 1e-9)
        XCTAssertEqual(v.features.mfcc.count, 13)
        XCTAssertEqual(v.featureVector.count, 21)
        XCTAssertEqual(v.featureVector[1], 600)
        XCTAssertEqual(recording.status, .recorded)
        recording.status = .analyzed
        XCTAssertEqual(recording.statusRaw, "analyzed")
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: animal, context: context)["voice recordings"], 1)
        XCTAssertFalse(try AnimalDeletionPolicy.canDelete(animal, context: context))
    }

    func testDeletingRecordingCascadesVocalizations() throws {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "x-audio.m4a", durationS: 1)
        context.insert(recording)
        let v = Vocalization(segment: Segment(startS: 0, endS: 0.2), features: VoiceFixtures.features())
        v.recording = recording
        context.insert(v)
        try context.save()
        context.delete(recording)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vocalization>()).count, 0)
    }
}
```

`AppTests/VoiceTagSeedTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class VoiceTagSeedTests: XCTestCase {
    func testSeedsOnceAndOnlyMissingNames() throws {
        let context = try TestSupport.container().mainContext
        context.insert(VoiceTag(kind: .meaning, name: "Hungry", isBuiltIn: true, sortOrder: 0))
        try context.save()
        let first = try VoiceTagSeed.seedIfNeeded(context: context)
        XCTAssertEqual(first, VoiceTagSeed.activities.count + VoiceTagSeed.meanings.count - 1)
        XCTAssertEqual(try VoiceTagSeed.seedIfNeeded(context: context), 0)
        let tags = try context.fetch(FetchDescriptor<VoiceTag>())
        XCTAssertEqual(tags.filter { $0.kind == .meaning }.count, VoiceTagSeed.meanings.count)
        XCTAssertTrue(VoiceTagSeed.meanings.contains(VoiceTagSeed.unknownMeaning))
        XCTAssertTrue(Seeds.all.count >= 1)
    }
}
```

`AppTests/TagPropagationTests.swift`:
```swift
import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class TagPropagationTests: XCTestCase {
    func testAppliesToNonOverriddenOnlyAndResets() throws {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 2)
        context.insert(recording)
        let a = Vocalization(segment: Segment(startS: 0, endS: 0.3), features: VoiceFixtures.features())
        let b = Vocalization(segment: Segment(startS: 1, endS: 1.3), features: VoiceFixtures.features())
        a.recording = recording
        b.recording = recording
        b.overridden = true
        b.meaningTag = "Annoyed"
        context.insert(a)
        context.insert(b)
        recording.activityTag = "Eating"
        recording.meaningTag = "Hungry"
        recording.userConfidence = 3

        TagPropagation.apply(to: recording)
        XCTAssertEqual(a.activityTag, "Eating")
        XCTAssertEqual(a.meaningTag, "Hungry")
        XCTAssertEqual(a.userConfidence, 3)
        XCTAssertEqual(b.meaningTag, "Annoyed")
        XCTAssertNil(b.activityTag)
        XCTAssertFalse(TagPropagation.differsFromRecording(a))
        XCTAssertTrue(TagPropagation.differsFromRecording(b))

        TagPropagation.resetOverride(b)
        XCTAssertFalse(b.overridden)
        XCTAssertEqual(b.meaningTag, "Hungry")
        XCTAssertEqual(b.activityTag, "Eating")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `VoiceRecording`, `VoiceTag`, `VoiceTagSeed`, `TagPropagation` not found.

- [ ] **Step 3: Implement the models**

`App/Models/VoiceRecording.swift`:
```swift
import Foundation
import SwiftData

@Model
final class VoiceRecording {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var recordedAt: Date = Date()
    var durationS: Double = 0
    /// "<uuid>-audio.m4a", relative to Documents/Media/.
    var audioFilename: String = ""
    var statusRaw: String = VoiceStatus.recorded.rawValue
    var errorMessage: String?
    var note: String = ""
    var activityTag: String?
    var meaningTag: String?
    /// 1 guess, 2 fairly sure, 3 certain
    var userConfidence: Int?
    var editedAt: Date?
    var animal: Animal?
    @Relationship(deleteRule: .cascade, inverse: \Vocalization.recording) var vocalizations: [Vocalization]?

    init(audioFilename: String, durationS: Double, recordedAt: Date = Date(), animal: Animal? = nil) {
        self.audioFilename = audioFilename
        self.durationS = durationS
        self.recordedAt = recordedAt
        self.animal = animal
    }

    var status: VoiceStatus {
        get { VoiceStatus(rawValue: statusRaw) ?? .recorded }
        set { statusRaw = newValue.rawValue }
    }

    var sortedVocalizations: [Vocalization] {
        (vocalizations ?? []).sorted { $0.startS < $1.startS }
    }
}
```

`App/Models/Vocalization.swift`:
```swift
import AnimalVoiceAudio
import Foundation
import SwiftData

@Model
final class Vocalization {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var startS: Double = 0
    var endS: Double = 0
    var f0Mean: Double?
    var f0Min: Double?
    var f0Max: Double?
    var f0Slope: Double?
    var voicedFraction: Double = 0
    var rmsDb: Double = -160
    var spectralCentroidHz: Double = 0
    var mfcc: [Double] = []
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?
    /// True once the user edited this sound's tags directly; recording-level tags then leave it alone.
    var overridden: Bool = false
    var recording: VoiceRecording?

    init(segment: Segment, features: VocalFeatures) {
        startS = segment.startS
        endS = segment.endS
        f0Mean = features.f0Mean
        f0Min = features.f0Min
        f0Max = features.f0Max
        f0Slope = features.f0Slope
        voicedFraction = features.voicedFraction
        rmsDb = features.rmsDb
        spectralCentroidHz = features.spectralCentroidHz
        mfcc = features.mfcc
    }

    var durationS: Double { endS - startS }

    var features: VocalFeatures {
        VocalFeatures(durationS: durationS, f0Mean: f0Mean, f0Min: f0Min, f0Max: f0Max, f0Slope: f0Slope,
                      voicedFraction: voicedFraction, rmsDb: rmsDb, spectralCentroidHz: spectralCentroidHz, mfcc: mfcc)
    }

    var featureVector: [Double] { features.vector }
}
```

`App/Models/VoiceTag.swift`:
```swift
import Foundation
import SwiftData

@Model
final class VoiceTag {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var kindRaw: String = VoiceTagKind.activity.rawValue
    var name: String = ""
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0

    init(kind: VoiceTagKind, name: String, isBuiltIn: Bool = false, sortOrder: Int = 0) {
        self.kindRaw = kind.rawValue
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }

    var kind: VoiceTagKind {
        get { VoiceTagKind(rawValue: kindRaw) ?? .activity }
        set { kindRaw = newValue.rawValue }
    }
}
```

- [ ] **Step 4: Seed, propagation, registration**

`App/Persistence/VoiceTagSeed.swift`:
```swift
import Foundation
import SwiftData

enum VoiceTagSeed {
    static let activities = ["Eating", "Waiting at door", "Being petted", "Playing", "Alone",
                             "Greeting a person", "Looking out window", "At the vet", "On a walk", "Other"]
    static let meanings = ["Hungry", "Wants attention", "Wants out or in", "Greeting", "Annoyed",
                           "In pain or distress", "Content", "Alert or warning", "Unknown"]
    static let unknownMeaning = "Unknown"
    static let seededKey = "hasSeededVoiceTags"

    /// Inserts any built-in tag whose name is missing. Returns how many were added.
    @discardableResult
    static func seedIfNeeded(context: ModelContext) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<VoiceTag>())
        var added = 0
        func seed(_ names: [String], kind: VoiceTagKind) {
            let present = Set(existing.filter { $0.kind == kind }.map(\.name))
            for (i, name) in names.enumerated() where !present.contains(name) {
                context.insert(VoiceTag(kind: kind, name: name, isBuiltIn: true, sortOrder: i))
                added += 1
            }
        }
        seed(activities, kind: .activity)
        seed(meanings, kind: .meaning)
        if added > 0 { try context.save() }
        return added
    }

    /// App-launch entry: runs once per install, guarded by UserDefaults.
    static func run(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        do {
            try seedIfNeeded(context: context)
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            NSLog("Voice tag seeding failed: %@", String(describing: error))
        }
    }
}
```

`App/Persistence/TagPropagation.swift`:
```swift
import Foundation

enum TagPropagation {
    /// Copies the recording's tags onto every vocalization the user has not overridden.
    static func apply(to recording: VoiceRecording) {
        for v in recording.vocalizations ?? [] where !v.overridden {
            v.activityTag = recording.activityTag
            v.meaningTag = recording.meaningTag
            v.userConfidence = recording.userConfidence
        }
    }

    /// True when any of the sound's tags differ from its recording's tags.
    static func differsFromRecording(_ v: Vocalization) -> Bool {
        guard let r = v.recording else { return false }
        return v.activityTag != r.activityTag || v.meaningTag != r.meaningTag || v.userConfidence != r.userConfidence
    }

    /// Drops a per-sound override and re-applies the recording's tags.
    static func resetOverride(_ v: Vocalization) {
        v.overridden = false
        guard let r = v.recording else { return }
        v.activityTag = r.activityTag
        v.meaningTag = r.meaningTag
        v.userConfidence = r.userConfidence
    }
}
```

Modify `App/Persistence/PersistenceController.swift`: in `modelTypes`, after `Animal.self,` add:
```swift
        VoiceRecording.self,
        Vocalization.self,
        VoiceTag.self,
```

Modify `App/AnimalTrackerApp.swift`: change `static let all: [(ModelContext) -> Void] = []` to
```swift
    static let all: [(ModelContext) -> Void] = [
        VoiceTagSeed.run,
    ]
```
(If another plan already added entries, append `VoiceTagSeed.run,` to the existing list.)

Modify `App/Persistence/AnimalDeletionPolicy.swift`: replace the body of `recordCounts` with
```swift
        var counts: [String: Int] = [:]
        let animalID = animal.id
        counts["voice recordings"] = try context.fetchCount(
            FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animal?.id == animalID }))
        return counts
```
(If other domains already added entries, keep them and add only the voice line.)

- [ ] **Step 5: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: all previous tests still pass plus 4 new tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(voice): VoiceRecording, Vocalization, VoiceTag models, tag seed and propagation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: AnalysisService and AudioPlayer on the media store

**Files:**
- Create: `App/Voice/AnalysisService.swift`, `App/Voice/AudioPlayer.swift`
- Create: `AppTests/TestAudioFile.swift`, `AppTests/AnalysisServiceTests.swift`

**Interfaces:**
- Consumes: `AudioLoader`, `FeatureExtractor`, `SegmenterConfig`, `Segment`, `VocalFeatures` (AnimalVoiceAudio); `VoiceRecording`, `Vocalization`, `TagPropagation`, `MediaStore`, `InMemoryMediaStore`.
- Produces: `AnalysisService.Result(durationS:events:)`, `AnalysisService.analyzeFile(at:segmenter:) throws -> Result` (nonisolated, CPU only), `AnalysisService.apply(_:to:context:) throws` (main actor), `AnalysisService.analyze(recording:mediaStore:context:segmenter:) async` (main actor); `AudioPlayer` (`ObservableObject`) with `play(url: URL, id: UUID, startS: Double? = nil, endS: Double? = nil)`, `stop()`, `isPlaying`, `playingID`; test helper `TestAudioFile.toneBurstM4A() throws -> URL` (0.3 s silence, 0.4 s 600 Hz tone, 0.3 s silence, AAC in an m4a container).

- [ ] **Step 1: Write the failing tests**

`AppTests/TestAudioFile.swift`:
```swift
import AVFoundation
import Foundation

enum TestAudioFile {
    /// 0.3 s silence, 0.4 s 600 Hz tone, 0.3 s silence, encoded as mono AAC at 16 kHz in an .m4a.
    static func toneBurstM4A() throws -> URL {
        let sr = 16_000.0
        var samples = [Float](repeating: 0, count: 4_800)
        samples += (0..<6_400).map { 0.5 * Float(sin(2 * Double.pi * 600 * Double($0) / sr)) }
        samples += [Float](repeating: 0, count: 4_800)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try write(samples, sampleRate: sr, to: url)
        return url
    }

    private static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        // `file` closes when this function returns.
    }
}
```

`AppTests/AnalysisServiceTests.swift`:
```swift
import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class AnalysisServiceTests: XCTestCase {
    func testAnalyzeCreatesVocalizationsAndPropagatesTags() async throws {
        let context = try TestSupport.container().mainContext
        let store = InMemoryMediaStore()
        let filename = try store.saveAudio(from: TestAudioFile.toneBurstM4A())
        let recording = VoiceRecording(audioFilename: filename, durationS: 1.0)
        recording.meaningTag = "Hungry"
        context.insert(recording)

        await AnalysisService.analyze(recording: recording, mediaStore: store, context: context)

        XCTAssertEqual(recording.status, .analyzed, recording.errorMessage ?? "")
        XCTAssertEqual(recording.vocalizations?.count, 1)
        let v = try XCTUnwrap(recording.sortedVocalizations.first)
        XCTAssertEqual(v.startS, 0.3, accuracy: 0.1)
        XCTAssertEqual(v.durationS, 0.4, accuracy: 0.1)
        XCTAssertEqual(v.f0Mean ?? 0, 600, accuracy: 18)
        XCTAssertEqual(v.meaningTag, "Hungry")
        XCTAssertEqual(recording.durationS, 1.0, accuracy: 0.1)
    }

    func testNothingAboveFloorIsNoSounds() async throws {
        let context = try TestSupport.container().mainContext
        let store = InMemoryMediaStore()
        var config = SegmenterConfig()
        config.absoluteFloorDbfs = 10 // nothing can pass the floor
        let recording = VoiceRecording(audioFilename: try store.saveAudio(from: TestAudioFile.toneBurstM4A()), durationS: 1.0)
        context.insert(recording)
        await AnalysisService.analyze(recording: recording, mediaStore: store, context: context, segmenter: config)
        XCTAssertEqual(recording.status, .noSounds)
        XCTAssertEqual(recording.vocalizations?.count ?? 0, 0)
    }

    func testMissingAudioFails() async throws {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "missing-audio.m4a", durationS: 0)
        context.insert(recording)
        await AnalysisService.analyze(recording: recording, mediaStore: InMemoryMediaStore(), context: context)
        XCTAssertEqual(recording.status, .failed)
        XCTAssertNotNil(recording.errorMessage)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `AnalysisService` not found.

- [ ] **Step 3: Implement**

`App/Voice/AnalysisService.swift`:
```swift
import AnimalVoiceAudio
import Foundation
import SwiftData

enum AnalysisService {
    struct Result {
        var durationS: Double
        var events: [(segment: Segment, features: VocalFeatures)]
    }

    enum AnalysisError: Error, LocalizedError {
        case missingAudio(String)
        var errorDescription: String? {
            switch self { case .missingAudio(let name): return "Audio file missing: \(name)" }
        }
    }

    /// CPU-only decode, segment, and feature extraction. Safe to call off the main actor.
    nonisolated static func analyzeFile(at url: URL, segmenter: SegmenterConfig = .init()) throws -> Result {
        let buffer = try AudioLoader.load(url)
        return Result(durationS: buffer.durationS, events: FeatureExtractor.analyze(buffer, segmenter: segmenter))
    }

    /// Replaces the recording's vocalizations with the result and re-applies recording-level tags.
    @MainActor
    static func apply(_ result: Result, to recording: VoiceRecording, context: ModelContext) throws {
        for old in recording.vocalizations ?? [] { context.delete(old) }
        for event in result.events {
            let v = Vocalization(segment: event.segment, features: event.features)
            v.recording = recording
            context.insert(v)
        }
        recording.durationS = result.durationS
        recording.status = result.events.isEmpty ? .noSounds : .analyzed
        recording.errorMessage = nil
        TagPropagation.apply(to: recording)
        try context.save()
    }

    /// Full pipeline for a stored recording: analyze its file off the main actor, then apply on it.
    @MainActor
    static func analyze(recording: VoiceRecording, mediaStore: MediaStore, context: ModelContext,
                        segmenter: SegmenterConfig = .init()) async {
        let filename = recording.audioFilename
        guard mediaStore.exists(filename) else {
            recording.status = .failed
            recording.errorMessage = AnalysisError.missingAudio(filename).localizedDescription
            try? context.save()
            return
        }
        let url = mediaStore.url(for: filename)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try analyzeFile(at: url, segmenter: segmenter)
            }.value
            try apply(result, to: recording, context: context)
        } catch {
            recording.status = .failed
            recording.errorMessage = error.localizedDescription
            try? context.save()
        }
    }
}
```

`App/Voice/AudioPlayer.swift`:
```swift
import AVFoundation
import Foundation

/// Plays a recording, or a time range within it, from a file URL.
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var playingID: UUID?

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?

    func play(url: URL, id: UUID, startS: Double? = nil, endS: Double? = nil) {
        stop()
        do {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            if let startS { p.currentTime = startS }
            p.play()
            player = p
            isPlaying = true
            playingID = id
            if let endS {
                let seconds = max(0.05, endS - (startS ?? 0))
                stopTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.stop() }
                }
            }
        } catch {
            isPlaying = false
            playingID = nil
        }
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 3 new tests pass, 0 failures. If the AAC test's start time is off by more than 0.1 s, the encoder priming was not trimmed on read: switch `TestAudioFile` to Apple Lossless (`kAudioFormatAppleLossless`, `AVEncoderBitDepthHintKey: 16`) which also lives in `.m4a`, and note it in the commit message.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(voice): AnalysisService over the media store and file-based AudioPlayer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: Voice tab root, Record screen, waveform, tagging sheet

**Files:**
- Create: `App/Views/Voice/VoiceTabView.swift`, `App/Views/Voice/RecordView.swift`, `App/Views/Voice/WaveformView.swift`, `App/Views/Voice/TagSheet.swift`
- Modify: `App/RootTabView.swift` (Voice tab line)

**Interfaces:**
- Consumes: `Recorder` (AnimalVoiceAudio), `AnalysisService`, `MediaStore` (`\.mediaStore`), `\.selectedAnimal`, `VoiceRecording`, `VoiceTag`, `VoiceTagSeed`, `TagPropagation`, `Animal`.
- Produces: `VoiceTabView` (segmented Record / History / Ask / Insights; History, Ask, Insights are `Text` placeholders until Tasks 16 to 18); `RecordView`; `WaveformView(levelDb:isActive:)`; `TagSheet(recording:)`; `ConfidencePicker(value:)`; `VoiceTagNames.names(_:kind:) -> [String]`; `RecordView.maxSeconds = 300`.

- [ ] **Step 1: Write the views**

`App/Views/Voice/VoiceTabView.swift`:
```swift
import SwiftUI

enum VoiceSection: String, CaseIterable, Identifiable {
    case record = "Record", history = "History", ask = "Ask", insights = "Insights"
    var id: String { rawValue }
}

struct VoiceTabView: View {
    @Environment(\.selectedAnimal) private var animal
    @State private var section: VoiceSection = .record

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(VoiceSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            if animal == nil {
                ContentUnavailableView("No animal selected", systemImage: "pawprint",
                                       description: Text("Add or select an animal from the top-left menu."))
            } else {
                switch section {
                case .record: RecordView()
                case .history: Text("History")
                case .ask: Text("Ask")
                case .insights: Text("Insights")
                }
            }
        }
    }
}
```

`App/Views/Voice/WaveformView.swift`:
```swift
import SwiftUI

/// Scrolling bar meter fed by the recorder's level in dBFS.
struct WaveformView: View {
    var levelDb: Float
    var isActive: Bool
    @State private var history: [Float] = Array(repeating: 0, count: 60)

    var body: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(history.count)
            HStack(alignment: .center, spacing: slot * 0.3) {
                ForEach(history.indices, id: \.self) { i in
                    Capsule()
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: slot * 0.7, height: max(4, CGFloat(history[i]) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: levelDb) { _, db in
            let normalized = max(0, min(1, (db + 60) / 60)) // -60 dBFS .. 0 dBFS
            history.removeFirst()
            history.append(isActive ? normalized : 0)
        }
    }
}
```

`App/Views/Voice/TagSheet.swift`:
```swift
import SwiftData
import SwiftUI

/// Tags a recording with animal, activity, meaning, confidence, and note, then propagates to its sounds.
struct TagSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var recording: VoiceRecording
    @Query(sort: \Animal.sortOrder) private var animals: [Animal]
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]
    @State private var newActivity = ""
    @State private var newMeaning = ""

    var body: some View {
        Form {
            Section("Which animal") {
                Picker("Animal", selection: Binding(
                    get: { recording.animal?.id },
                    set: { id in recording.animal = animals.first { $0.id == id } }
                )) {
                    Text("Choose an animal").tag(UUID?.none)
                    ForEach(animals.filter { !$0.isArchived }) { Text("\($0.name) (\($0.species))").tag(Optional($0.id)) }
                }
            }
            Section("What was the animal doing") {
                tagPicker(selection: $recording.activityTag, options: VoiceTagNames.names(tags, kind: .activity), newText: $newActivity, kind: .activity)
            }
            Section("What do you think it meant") {
                tagPicker(selection: $recording.meaningTag, options: VoiceTagNames.names(tags, kind: .meaning), newText: $newMeaning, kind: .meaning)
            }
            Section("How sure are you") {
                ConfidencePicker(value: Binding(get: { recording.userConfidence ?? 2 }, set: { recording.userConfidence = $0 }))
            }
            Section("Note") {
                TextField("Anything else", text: $recording.note, axis: .vertical)
            }
            Section { statusSummary }
        }
        .navigationTitle("Tag recording")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(recording.animal == nil) }
            ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        switch recording.status {
        case .analyzed:
            Text("\(recording.vocalizations?.count ?? 0) sounds detected. These tags apply to all of them; edit individual sounds in History.")
                .font(.footnote).foregroundStyle(.secondary)
        case .noSounds:
            Text("No sounds detected. You can re-analyze with a lower threshold in History.").font(.footnote).foregroundStyle(.secondary)
        case .failed:
            Text("Analysis failed: \(recording.errorMessage ?? "unknown error")").font(.footnote).foregroundStyle(.red)
        case .recorded:
            Text("Not analyzed yet.").font(.footnote)
        }
    }

    @ViewBuilder
    private func tagPicker(selection: Binding<String?>, options: [String], newText: Binding<String>, kind: VoiceTagKind) -> some View {
        Picker("Tag", selection: selection) {
            Text("None").tag(String?.none)
            ForEach(options, id: \.self) { Text($0).tag(Optional($0)) }
        }
        HStack {
            TextField("Add a new tag", text: newText)
            Button("Add") {
                addTag(newText.wrappedValue, kind: kind, selection: selection)
                newText.wrappedValue = ""
            }
            .disabled(newText.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addTag(_ raw: String, kind: VoiceTagKind, selection: Binding<String?>) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !tags.contains(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            context.insert(VoiceTag(kind: kind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
        }
        selection.wrappedValue = name
    }

    private func save() {
        recording.editedAt = Date()
        TagPropagation.apply(to: recording)
        try? context.save()
        dismiss()
    }
}

struct ConfidencePicker: View {
    @Binding var value: Int

    var body: some View {
        Picker("Confidence", selection: $value) {
            Text("Guess").tag(1)
            Text("Fairly sure").tag(2)
            Text("Certain").tag(3)
        }
        .pickerStyle(.segmented)
    }
}

enum VoiceTagNames {
    /// Distinct tag names of a kind in sort order.
    static func names(_ tags: [VoiceTag], kind: VoiceTagKind) -> [String] {
        var seen = Set<String>()
        return tags.filter { $0.kind == kind }.map(\.name).filter { seen.insert($0).inserted }
    }
}
```

`App/Views/Voice/RecordView.swift`:
```swift
import AnimalVoiceAudio
import SwiftData
import SwiftUI

struct RecordView: View {
    static let maxSeconds: TimeInterval = 300

    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.selectedAnimal) private var animal
    @StateObject private var recorder = Recorder()
    @State private var permissionDenied = false
    @State private var isAnalyzing = false
    @State private var pendingRecording: VoiceRecording?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            WaveformView(levelDb: recorder.levelDb, isActive: recorder.isRecording)
                .frame(height: 120)
                .padding(.horizontal)
            Text(timeString(recorder.elapsedS))
                .font(.system(size: 44, weight: .light, design: .monospaced))
            if isAnalyzing { ProgressView("Analyzing…") }
            Spacer()
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 96, height: 96)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40)).foregroundStyle(.white)
                }
            }
            .disabled(isAnalyzing || animal == nil)
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
            if let animal {
                Text("Recording \(animal.name) (\(animal.species)). Up to 5 minutes.").font(.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
            Spacer().frame(height: 24)
        }
        .onChange(of: recorder.elapsedS) { _, t in
            if recorder.isRecording, t >= Self.maxSeconds { finish() }
        }
        .alert("Microphone access needed", isPresented: $permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access in Settings to record your animal.")
        }
        .sheet(item: $pendingRecording) { recording in
            NavigationStack { TagSheet(recording: recording) }
        }
    }

    private func toggle() {
        if recorder.isRecording { finish() } else { Task { await begin() } }
    }

    private func begin() async {
        errorMessage = nil
        guard await Recorder.requestPermission() else {
            permissionDenied = true
            return
        }
        do { try recorder.start() } catch { errorMessage = "Could not start recording: \(error)" }
    }

    /// Moves the temp file into the media store, inserts the recording for the selected animal, analyzes, then opens tagging.
    private func finish() {
        let elapsed = recorder.elapsedS
        let animal = animal
        guard let url = recorder.stop() else { return }
        isAnalyzing = true
        Task {
            defer { isAnalyzing = false }
            do {
                let filename = try mediaStore.saveAudio(from: url)
                let recording = VoiceRecording(audioFilename: filename, durationS: elapsed, animal: animal)
                context.insert(recording)
                try context.save()
                await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context)
                pendingRecording = recording
            } catch {
                errorMessage = "Could not save the recording: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d.%d", Int(t) / 60, Int(t) % 60, Int(t * 10) % 10)
    }
}
```

Modify `App/RootTabView.swift`: replace `tab("Voice", "waveform") { Text("Voice") }` with `tab("Voice", "waveform") { VoiceTabView() }`.

- [ ] **Step 2: Build, run, verify, commit**

Run: `scripts/test-app.sh` (all pass) then `scripts/run-sim.sh`. The screenshot shows whatever tab is first; the reviewer checks the code paths. Confirm the build has no warnings in files created by this task: `scripts/build-app.sh 2>&1 | grep -c "Voice/.*warning"` prints 0.

```bash
git add -A
git commit -m "feat(voice): Voice tab with Record screen, live meter, and tagging sheet

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: Voice history, recording detail with playback, per-sound overrides, re-analysis

**Files:**
- Create: `App/Views/Voice/VoiceHistoryView.swift`, `App/Views/Voice/RecordingDetailView.swift`, `App/Views/Voice/VocalizationEditView.swift`
- Modify: `App/Views/Voice/VoiceTabView.swift` (replace `Text("History")` with `VoiceHistoryView()`)

**Interfaces:**
- Consumes: `VoiceRecording`, `Vocalization`, `TagSheet`, `ConfidencePicker`, `VoiceTagNames`, `TagPropagation`, `AnalysisService`, `AudioPlayer`, `MediaStore`, `SegmenterConfig`, `\.selectedAnimal`.
- Produces: `VoiceHistoryView`; `RecordingDetailView(recording:)`; `VocalizationEditView(vocalization:)`; `VocalizationPlayButton(vocalization:player:)`; `VocalizationRow(vocalization:player:)`.

- [ ] **Step 1: Write the views**

`App/Views/Voice/VoiceHistoryView.swift`:
```swift
import SwiftData
import SwiftUI

struct VoiceHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.selectedAnimal) private var animal
    @Query(sort: \VoiceRecording.recordedAt, order: .reverse) private var allRecordings: [VoiceRecording]
    @State private var activityFilter: String?
    @State private var meaningFilter: String?

    private var recordings: [VoiceRecording] { allRecordings.filter { $0.animal?.id == animal?.id } }

    private var activities: [String] { Array(Set(recordings.compactMap(\.activityTag))).sorted() }
    private var meanings: [String] {
        let all = recordings.flatMap { r in (r.vocalizations ?? []).compactMap(\.meaningTag) + [r.meaningTag].compactMap { $0 } }
        return Array(Set(all)).sorted()
    }

    private var filtered: [VoiceRecording] {
        recordings.filter { r in
            let activityOK = activityFilter == nil || r.activityTag == activityFilter
            let meaningOK = meaningFilter == nil || r.meaningTag == meaningFilter
                || (r.vocalizations ?? []).contains { $0.meaningTag == meaningFilter }
            return activityOK && meaningOK
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Activity", selection: $activityFilter) {
                    Text("Any activity").tag(String?.none)
                    ForEach(activities, id: \.self) { Text($0).tag(Optional($0)) }
                }
                Picker("Meaning", selection: $meaningFilter) {
                    Text("Any meaning").tag(String?.none)
                    ForEach(meanings, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Section {
                ForEach(filtered) { recording in
                    NavigationLink { RecordingDetailView(recording: recording) } label: { RecordingRow(recording: recording) }
                }
                .onDelete { offsets in
                    for r in offsets.map({ filtered[$0] }) {
                        mediaStore.delete(r.audioFilename)
                        context.delete(r)
                    }
                    try? context.save()
                }
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "waveform", description: Text("Record from the Record section."))
            }
        }
    }
}

struct RecordingRow: View {
    let recording: VoiceRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.recordedAt, format: .dateTime.month().day().hour().minute()).font(.headline)
                Spacer()
                Text(String(format: "%.0f s", recording.durationS)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Label("\(recording.vocalizations?.count ?? 0)", systemImage: "waveform")
                if let meaning = recording.meaningTag {
                    Text(meaning).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15)).clipShape(Capsule())
                }
                if let activity = recording.activityTag { Text(activity).foregroundStyle(.secondary) }
                if recording.status == .noSounds { Text("no sounds").foregroundStyle(.secondary) }
                if recording.status == .failed { Text("failed").foregroundStyle(.red) }
            }
            .font(.caption)
        }
    }
}
```

`App/Views/Voice/RecordingDetailView.swift`:
```swift
import AnimalVoiceAudio
import SwiftData
import SwiftUI

struct RecordingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.dismiss) private var dismiss
    @Bindable var recording: VoiceRecording
    @StateObject private var player = AudioPlayer()
    @State private var showTagSheet = false
    @State private var thresholdDb: Double = 20
    @State private var reanalyzing = false
    @State private var confirmDelete = false

    private var isPlayingWhole: Bool { player.playingID == recording.id }

    var body: some View {
        List {
            Section {
                HStack {
                    Button {
                        if isPlayingWhole {
                            player.stop()
                        } else if mediaStore.exists(recording.audioFilename) {
                            player.play(url: mediaStore.url(for: recording.audioFilename), id: recording.id)
                        }
                    } label: {
                        Label(isPlayingWhole ? "Stop" : "Play recording", systemImage: isPlayingWhole ? "stop.fill" : "play.fill")
                    }
                    .disabled(!mediaStore.exists(recording.audioFilename))
                    Spacer()
                    Text(String(format: "%.1f s", recording.durationS)).foregroundStyle(.secondary)
                }
                if !mediaStore.exists(recording.audioFilename) {
                    Label("Audio file missing", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                LabeledContent("Animal", value: recording.animal?.name ?? "Not set")
                LabeledContent("Activity", value: recording.activityTag ?? "Not set")
                LabeledContent("Meaning", value: recording.meaningTag ?? "Not set")
                if !recording.note.isEmpty { Text(recording.note).font(.footnote) }
                Button("Edit tags") { showTagSheet = true }
            }
            Section("Sounds (\(recording.sortedVocalizations.count))") {
                if recording.status == .failed {
                    Text(recording.errorMessage ?? "Analysis failed").foregroundStyle(.red)
                }
                if recording.status == .noSounds {
                    Text("No sounds detected. Lower the threshold below and re-analyze.").foregroundStyle(.secondary)
                }
                ForEach(recording.sortedVocalizations) { v in
                    NavigationLink { VocalizationEditView(vocalization: v) } label: { VocalizationRow(vocalization: v, player: player) }
                }
            }
            Section("Re-analyze") {
                VStack(alignment: .leading) {
                    Text("Detect sounds down to \(Int(thresholdDb)) dB below the loudest one").font(.footnote)
                    Slider(value: $thresholdDb, in: 10...40, step: 1)
                }
                Button(reanalyzing ? "Analyzing…" : "Re-analyze", action: reanalyze).disabled(reanalyzing)
                Text("Replaces the detected sounds and re-applies the recording tags. Per-sound edits are lost.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete recording", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
        .sheet(isPresented: $showTagSheet) { NavigationStack { TagSheet(recording: recording) } }
        .confirmationDialog("Delete this recording and its audio file?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player.stop()
                mediaStore.delete(recording.audioFilename)
                context.delete(recording)
                try? context.save()
                dismiss()
            }
        }
        .onDisappear { player.stop() }
    }

    private func reanalyze() {
        reanalyzing = true
        var config = SegmenterConfig()
        config.relativeThresholdDb = Float(thresholdDb)
        Task {
            await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context, segmenter: config)
            reanalyzing = false
        }
    }
}

struct VocalizationPlayButton: View {
    let vocalization: Vocalization
    @ObservedObject var player: AudioPlayer
    @Environment(\.mediaStore) private var mediaStore

    var body: some View {
        Button {
            if player.playingID == vocalization.id {
                player.stop()
            } else if let recording = vocalization.recording, mediaStore.exists(recording.audioFilename) {
                player.play(url: mediaStore.url(for: recording.audioFilename), id: vocalization.id,
                            startS: vocalization.startS, endS: vocalization.endS)
            }
        } label: {
            Image(systemName: player.playingID == vocalization.id ? "stop.circle" : "play.circle").font(.title2)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Play sound")
    }
}

struct VocalizationRow: View {
    let vocalization: Vocalization
    @ObservedObject var player: AudioPlayer

    var body: some View {
        HStack {
            VocalizationPlayButton(vocalization: vocalization, player: player)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "at %.1f s, %.2f s long", vocalization.startS, vocalization.durationS)).font(.subheadline)
                Text(vocalization.f0Mean.map { String(format: "pitch %.0f Hz", $0) } ?? "unvoiced").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(vocalization.meaningTag ?? "untagged").font(.caption)
                if vocalization.overridden { Text("edited").font(.caption2).foregroundStyle(.orange) }
            }
        }
    }
}
```

`App/Views/Voice/VocalizationEditView.swift`:
```swift
import SwiftData
import SwiftUI

struct VocalizationEditView: View {
    @Environment(\.modelContext) private var context
    @Bindable var vocalization: Vocalization
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]

    var body: some View {
        Form {
            Section("Measured") {
                LabeledContent("Start", value: String(format: "%.2f s", vocalization.startS))
                LabeledContent("Duration", value: String(format: "%.2f s", vocalization.durationS))
                LabeledContent("Pitch mean", value: vocalization.f0Mean.map { String(format: "%.0f Hz", $0) } ?? "unvoiced")
                LabeledContent("Pitch slope", value: vocalization.f0Slope.map { String(format: "%+.0f Hz/s", $0) } ?? "n/a")
                LabeledContent("Loudness", value: String(format: "%.0f dBFS", vocalization.rmsDb))
                LabeledContent("Spectral centroid", value: String(format: "%.0f Hz", vocalization.spectralCentroidHz))
            }
            Section("Activity") {
                Picker("Activity", selection: $vocalization.activityTag) {
                    Text("None").tag(String?.none)
                    ForEach(VoiceTagNames.names(tags, kind: .activity), id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Section("Meaning") {
                Picker("Meaning", selection: $vocalization.meaningTag) {
                    Text("None").tag(String?.none)
                    ForEach(VoiceTagNames.names(tags, kind: .meaning), id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Section("Confidence") {
                ConfidencePicker(value: Binding(get: { vocalization.userConfidence ?? 2 }, set: { vocalization.userConfidence = $0 }))
            }
            Section {
                if vocalization.overridden {
                    Button("Reset to recording tags") {
                        TagPropagation.resetOverride(vocalization)
                        try? context.save()
                    }
                } else {
                    Text("Changing tags here overrides the recording-level tags for this sound only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sound")
        .onChange(of: vocalization.activityTag) { _, _ in markOverriddenIfChanged() }
        .onChange(of: vocalization.meaningTag) { _, _ in markOverriddenIfChanged() }
        .onChange(of: vocalization.userConfidence) { _, _ in markOverriddenIfChanged() }
    }

    private func markOverriddenIfChanged() {
        if TagPropagation.differsFromRecording(vocalization) { vocalization.overridden = true }
        try? context.save()
    }
}
```

Modify `App/Views/Voice/VoiceTabView.swift`: replace `case .history: Text("History")` with `case .history: VoiceHistoryView()`.

- [ ] **Step 2: Build, run, commit**

Run: `scripts/test-app.sh` and `scripts/run-sim.sh`. Expected: tests pass, build succeeds.

```bash
git add -A
git commit -m "feat(voice): history, recording detail with playback, per-sound overrides, re-analysis

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: PredictionService and Ask screen

**Files:**
- Create: `App/Voice/PredictionService.swift`, `App/Views/Voice/AskView.swift`
- Create: `AppTests/PredictionServiceTests.swift`
- Modify: `App/Views/Voice/VoiceTabView.swift` (replace `Text("Ask")` with `AskView()`)

**Interfaces:**
- Consumes: `Ensemble`, `Evaluator`, `Readiness`, `ResearchPrior`, `LabeledSample`, `Prediction`, `Evaluation`, `ReadinessStatus` (AnimalVoiceStats); `VocalFeatures`; `Animal`, `VoiceRecording`, `Vocalization`, `Recorder`, `AnalysisService`, `AudioPlayer`, `VocalizationPlayButton`, `VoiceTagNames`, `VoiceTagSeed.unknownMeaning`, `MediaStore`.
- Produces: `AskResult(readiness:prediction:evaluation:neighbors:researchHint:)`; `PredictionService.labeledSamples(for animal: Animal, context: ModelContext) throws -> [(sample: LabeledSample, vocalization: Vocalization)]`; `PredictionService.predict(features: VocalFeatures, for animal: Animal, context: ModelContext) throws -> AskResult`; `AskView`; `AskResultView`.

- [ ] **Step 1: Write the failing tests**

`AppTests/PredictionServiceTests.swift`:
```swift
import AnimalVoiceAudio
import AnimalVoiceStats
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PredictionServiceTests: XCTestCase {
    private func makeAnimal(context: ModelContext, hungry: Int, annoyed: Int, species: String = "cat") throws -> Animal {
        let animal = Animal(name: "Miso", species: species)
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 30, animal: animal)
        context.insert(recording)
        var t = 0.0
        for i in 0..<hungry {
            let v = Vocalization(segment: Segment(startS: t, endS: t + 0.3), features: VoiceFixtures.features(duration: 0.3, f0: 800 + Double(i) * 10, slope: 200))
            v.meaningTag = "Hungry"; v.recording = recording; context.insert(v); t += 1
        }
        for i in 0..<annoyed {
            let v = Vocalization(segment: Segment(startS: t, endS: t + 1.2), features: VoiceFixtures.features(duration: 1.2, f0: 400 + Double(i) * 10, slope: -100))
            v.meaningTag = "Annoyed"; v.recording = recording; context.insert(v); t += 2
        }
        let unknown = Vocalization(segment: Segment(startS: t, endS: t + 0.5), features: VoiceFixtures.features())
        unknown.meaningTag = VoiceTagSeed.unknownMeaning; unknown.recording = recording; context.insert(unknown)
        let untagged = Vocalization(segment: Segment(startS: t + 1, endS: t + 1.5), features: VoiceFixtures.features())
        untagged.recording = recording; context.insert(untagged)
        try context.save()
        return animal
    }

    func testReadyAnimalPredictsNearestMeaning() throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 6, annoyed: 6)
        XCTAssertEqual(try PredictionService.labeledSamples(for: animal, context: context).count, 12, "Unknown and untagged sounds are excluded")

        let result = try PredictionService.predict(features: VoiceFixtures.features(duration: 0.35, f0: 780, slope: 150), for: animal, context: context)
        guard case .ready = result.readiness else { return XCTFail("expected ready, got \(result.readiness)") }
        XCTAssertEqual(result.prediction?.best?.label, "Hungry")
        XCTAssertGreaterThan(result.prediction?.best?.probability ?? 0, 0.8)
        XCTAssertEqual(result.neighbors.count, 5)
        XCTAssertTrue(result.neighbors.allSatisfy { $0.meaningTag == "Hungry" })
        XCTAssertGreaterThan(result.evaluation?.accuracy ?? 0, 0.9)
        XCTAssertNotNil(result.researchHint, "cats get the Meowsic hint")
    }

    func testDogGetsNoResearchHint() throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 6, annoyed: 6, species: "dog")
        let result = try PredictionService.predict(features: VoiceFixtures.features(duration: 0.35, f0: 780, slope: 150), for: animal, context: context)
        XCTAssertEqual(result.prediction?.best?.label, "Hungry")
        XCTAssertNil(result.researchHint)
    }

    func testNotReadyAnimal() throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 5, annoyed: 3)
        let result = try PredictionService.predict(features: VoiceFixtures.features(), for: animal, context: context)
        guard case let .notReady(_, needed) = result.readiness else { return XCTFail("expected notReady") }
        XCTAssertEqual(needed, ["Annoyed": 2])
        XCTAssertNil(result.prediction)
        XCTAssertTrue(result.neighbors.isEmpty)
    }

    func testOtherAnimalsDataIsNotUsed() throws {
        let context = try TestSupport.container().mainContext
        _ = try makeAnimal(context: context, hungry: 6, annoyed: 6)
        let empty = Animal(name: "Rex", species: "dog")
        context.insert(empty)
        try context.save()
        XCTAssertEqual(try PredictionService.labeledSamples(for: empty, context: context).count, 0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `PredictionService` not found.

- [ ] **Step 3: Implement**

`App/Voice/PredictionService.swift`:
```swift
import AnimalVoiceAudio
import AnimalVoiceStats
import Foundation
import SwiftData

struct AskResult {
    var readiness: ReadinessStatus
    var prediction: Prediction?
    var evaluation: Evaluation?
    var neighbors: [Vocalization]
    var researchHint: String?
}

enum PredictionService {
    /// The animal's sounds that carry a real meaning label (not empty, not "Unknown").
    @MainActor
    static func labeledSamples(for animal: Animal, context: ModelContext) throws -> [(sample: LabeledSample, vocalization: Vocalization)] {
        let animalID = animal.id
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animal?.id == animalID }))
        return recordings
            .flatMap { $0.vocalizations ?? [] }
            .compactMap { v in
                guard let label = v.meaningTag, !label.isEmpty, label != VoiceTagSeed.unknownMeaning else { return nil }
                return (LabeledSample(id: v.id, features: v.featureVector, label: label), v)
            }
    }

    @MainActor
    static func predict(features: VocalFeatures, for animal: Animal, context: ModelContext) throws -> AskResult {
        let labeled = try labeledSamples(for: animal, context: context)
        var counts: [String: Int] = [:]
        for item in labeled { counts[item.sample.label, default: 0] += 1 }
        let readiness = Readiness.check(labelCounts: counts)
        let hint = ResearchPrior.hint(species: animal.species, durationS: features.durationS, f0Mean: features.f0Mean, f0Slope: features.f0Slope)
        guard case .ready = readiness else {
            return AskResult(readiness: readiness, prediction: nil, evaluation: nil, neighbors: [], researchHint: hint)
        }
        let samples = labeled.map(\.sample)
        let prediction = Ensemble().predict(query: features.vector, training: samples)
        let evaluation = Evaluator.leaveOneOut(samples)
        let byID = Dictionary(labeled.map { ($0.vocalization.id, $0.vocalization) }, uniquingKeysWith: { first, _ in first })
        let neighbors = prediction.neighborIds.compactMap { byID[$0] }
        return AskResult(readiness: readiness, prediction: prediction, evaluation: evaluation, neighbors: neighbors, researchHint: hint)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 4 new tests pass, 0 failures.

- [ ] **Step 5: Write the Ask screen**

`App/Views/Voice/AskView.swift`:
```swift
import AnimalVoiceAudio
import AnimalVoiceStats
import SwiftData
import SwiftUI

struct AskView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.selectedAnimal) private var animal
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]
    @StateObject private var recorder = Recorder()
    @StateObject private var player = AudioPlayer()
    @State private var isAnalyzing = false
    @State private var recording: VoiceRecording?
    @State private var results: [(vocalization: Vocalization, result: AskResult)] = []
    @State private var errorMessage: String?
    @State private var permissionDenied = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Button(action: toggle) {
                        Label(recorder.isRecording ? "Stop" : "Record a sound", systemImage: recorder.isRecording ? "stop.fill" : "mic.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.isRecording ? .red : .accentColor)
                    .disabled(isAnalyzing || animal == nil)
                    Spacer()
                }
                if recorder.isRecording {
                    Text(String(format: "%.1f s", recorder.elapsedS)).monospacedDigit().frame(maxWidth: .infinity, alignment: .center)
                }
                if isAnalyzing { ProgressView("Analyzing…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
                if let animal {
                    Text("Asks what a new sound from \(animal.name) means, using only \(animal.name)'s labeled sounds.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let recording, results.isEmpty, recording.status == .noSounds {
                Section { Text("No sounds detected in that recording.") }
            }
            ForEach(Array(results.enumerated()), id: \.offset) { index, item in
                Section("Sound \(index + 1) at \(String(format: "%.1f", item.vocalization.startS)) s") {
                    AskResultView(vocalization: item.vocalization, result: item.result,
                                  meanings: VoiceTagNames.names(tags, kind: .meaning), player: player) { correct in
                        item.vocalization.meaningTag = correct
                        item.vocalization.overridden = true
                        try? context.save()
                    }
                }
            }
        }
        .onChange(of: recorder.elapsedS) { _, t in
            if recorder.isRecording, t >= RecordView.maxSeconds { finish() }
        }
        .alert("Microphone access needed", isPresented: $permissionDenied) { Button("OK") {} }
        .onDisappear { player.stop() }
    }

    private func toggle() {
        if recorder.isRecording { finish() } else { Task { await begin() } }
    }

    private func begin() async {
        errorMessage = nil
        results = []
        guard await Recorder.requestPermission() else { permissionDenied = true; return }
        do { try recorder.start() } catch { errorMessage = "Could not start recording: \(error)" }
    }

    /// Saves the new recording (so corrections become training data) and predicts each detected sound.
    private func finish() {
        let elapsed = recorder.elapsedS
        guard let url = recorder.stop(), let animal else { return }
        isAnalyzing = true
        Task {
            defer { isAnalyzing = false }
            do {
                let filename = try mediaStore.saveAudio(from: url)
                let newRecording = VoiceRecording(audioFilename: filename, durationS: elapsed, animal: animal)
                context.insert(newRecording)
                try context.save()
                await AnalysisService.analyze(recording: newRecording, mediaStore: mediaStore, context: context)
                recording = newRecording
                results = try newRecording.sortedVocalizations.map {
                    ($0, try PredictionService.predict(features: $0.features, for: animal, context: context))
                }
            } catch {
                errorMessage = "Could not process the recording: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct AskResultView: View {
    let vocalization: Vocalization
    let result: AskResult
    let meanings: [String]
    @ObservedObject var player: AudioPlayer
    var onCorrect: (String) -> Void
    @State private var correction: String?

    var body: some View {
        HStack {
            VocalizationPlayButton(vocalization: vocalization, player: player)
            Text(String(format: "%.2f s long", vocalization.durationS)).font(.caption).foregroundStyle(.secondary)
            Text(vocalization.f0Mean.map { String(format: "pitch %.0f Hz", $0) } ?? "unvoiced").font(.caption).foregroundStyle(.secondary)
        }
        if let prediction = result.prediction, let best = prediction.best {
            VStack(alignment: .leading, spacing: 4) {
                Text(best.label).font(.title3.bold())
                Text("\(Int(best.probability * 100))% likely, from \(result.evaluation?.n ?? 0) labeled sounds").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(prediction.probabilities.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { label, p in
                HStack {
                    Text(label).font(.caption).frame(width: 130, alignment: .leading)
                    ProgressView(value: p)
                    Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            if let e = result.evaluation {
                Text("Tested on this animal's own past sounds, the model was right \(Int(e.accuracy * 100))% of the time (leave-one-out, n = \(e.n)).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !result.neighbors.isEmpty {
                Text("Closest past sounds").font(.caption.bold())
                ForEach(result.neighbors) { neighbor in
                    HStack {
                        VocalizationPlayButton(vocalization: neighbor, player: player)
                        Text(neighbor.meaningTag ?? "?").font(.caption)
                        Spacer()
                        Text(neighbor.recording?.recordedAt.formatted(date: .abbreviated, time: .omitted) ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } else if case let .notReady(message, needed) = result.readiness {
            Text(message).font(.subheadline)
            ForEach(needed.sorted { $0.key < $1.key }, id: \.key) { label, n in
                Text("\(label): \(n) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let hint = result.researchHint {
            VStack(alignment: .leading, spacing: 2) {
                Text(hint).font(.footnote)
                Text(ResearchPrior.attribution).font(.caption2).foregroundStyle(.secondary)
            }
        }
        Picker("This was actually", selection: $correction) {
            Text("Choose").tag(String?.none)
            ForEach(meanings, id: \.self) { Text($0).tag(Optional($0)) }
        }
        .onChange(of: correction) { _, value in
            if let value { onCorrect(value) }
        }
    }
}
```

Modify `App/Views/Voice/VoiceTabView.swift`: replace `case .ask: Text("Ask")` with `case .ask: AskView()`.

- [ ] **Step 6: Build, run, commit**

Run: `scripts/test-app.sh` and `scripts/run-sim.sh`. Expected: tests pass, build succeeds.

```bash
git add -A
git commit -m "feat(voice): PredictionService and Ask screen with honest confidence and nearest examples

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 18: Insights and Manage Voice Tags

**Files:**
- Create: `App/Voice/InsightsModel.swift`, `App/Views/Voice/InsightsView.swift`, `App/Views/Voice/ManageVoiceTagsView.swift`
- Create: `AppTests/InsightsModelTests.swift`
- Modify: `App/Views/Voice/VoiceTabView.swift` (replace `Text("Insights")` with `InsightsView()`), `App/Views/Settings/SettingsView.swift` (replace `SettingsPlaceholderRow(title: "Voice tags")` with `NavigationLink("Voice tags") { ManageVoiceTagsView() }`)

**Interfaces:**
- Consumes: `Readiness`, `Evaluator`, `LabeledSample`, `Evaluation`, `ReadinessStatus`, `VocalFeatures`, `Animal`, `VoiceRecording`, `VoiceTag`, `VoiceTagSeed.unknownMeaning`.
- Produces: `InsightsSummary` (`labeledCount`, `unlabeledCount`, `labelCounts`, `readiness`, `evaluation`, `points: [Point]`, `legendOrder`), `InsightsModel.Item(id:features:meaning:)`, `InsightsModel.summarize(_ items: [Item]) -> InsightsSummary`, `InsightsModel.summarize(animal:context:) throws`, `InsightsModel.maxSeries = 6`, `InsightsModel.otherLabel = "Other"`; `InsightsView`; `SeriesPalette` (six validated hues plus gray, light and dark variants); `ManageVoiceTagsView`.
- Chart rules: one y-axis, fixed categorical order by count then name (never cycled), at most six hues plus gray "Other", identity also carried by symbol shape and a legend, a count table under the chart. The palette was validated with the dataviz validator in light and dark modes on 2026-09-15.

- [ ] **Step 1: Write the failing tests**

`AppTests/InsightsModelTests.swift`:
```swift
import AnimalVoiceAudio
import AnimalVoiceStats
import XCTest
@testable import AnimalTracker

final class InsightsModelTests: XCTestCase {
    private func item(_ meaning: String?, f0: Double? = 500) -> InsightsModel.Item {
        InsightsModel.Item(id: UUID(), features: VoiceFixtures.features(f0: f0), meaning: meaning)
    }

    func testCountsOrderAndPoints() {
        let items = [item("Hungry"), item("Hungry"), item("Annoyed"), item("Annoyed", f0: nil), item(nil), item(VoiceTagSeed.unknownMeaning), item("")]
        let s = InsightsModel.summarize(items)
        XCTAssertEqual(s.labeledCount, 4)
        XCTAssertEqual(s.unlabeledCount, 3)
        XCTAssertEqual(s.labelCounts, ["Hungry": 2, "Annoyed": 2])
        XCTAssertEqual(s.legendOrder, ["Annoyed", "Hungry"]) // tie on count, alphabetical
        XCTAssertEqual(s.points.count, 3, "unvoiced sounds have no pitch to plot")
        guard case .notReady = s.readiness else { return XCTFail("expected notReady") }
        XCTAssertNil(s.evaluation)
    }

    func testMoreThanSixMeaningsFoldIntoOther() {
        var items: [InsightsModel.Item] = []
        for (i, name) in ["A", "B", "C", "D", "E", "F", "G", "H"].enumerated() {
            for _ in 0...(8 - i) { items.append(item(name)) } // A has 9, H has 2
        }
        let s = InsightsModel.summarize(items)
        XCTAssertEqual(s.legendOrder, ["A", "B", "C", "D", "E", "F", InsightsModel.otherLabel])
        XCTAssertEqual(s.points.filter { $0.meaning == InsightsModel.otherLabel }.count, 3 + 2)
        guard case .ready = s.readiness else { return XCTFail("expected ready") }
        XCTAssertNotNil(s.evaluation)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `InsightsModel` not found.

- [ ] **Step 3: Implement the model**

`App/Voice/InsightsModel.swift`:
```swift
import AnimalVoiceAudio
import AnimalVoiceStats
import Foundation
import SwiftData

struct InsightsSummary: Equatable {
    struct Point: Identifiable, Equatable {
        let id: UUID
        let durationS: Double
        let f0Mean: Double
        let meaning: String
    }

    var labeledCount: Int
    var unlabeledCount: Int
    var labelCounts: [String: Int]
    var readiness: ReadinessStatus
    var evaluation: Evaluation?
    var points: [Point]
    /// Meanings in fixed display order (count descending, then name), with "Other" last when folded.
    var legendOrder: [String]
}

enum InsightsModel {
    static let maxSeries = 6
    static let otherLabel = "Other"

    struct Item {
        let id: UUID
        let features: VocalFeatures
        let meaning: String?
    }

    static func summarize(_ items: [Item]) -> InsightsSummary {
        let labeled = items.compactMap { item -> (Item, String)? in
            guard let m = item.meaning, !m.isEmpty, m != VoiceTagSeed.unknownMeaning else { return nil }
            return (item, m)
        }
        var counts: [String: Int] = [:]
        for (_, meaning) in labeled { counts[meaning, default: 0] += 1 }
        let ordered = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let top = Array(ordered.prefix(maxSeries))
        let legend = ordered.count > maxSeries ? top + [otherLabel] : top

        let readiness = Readiness.check(labelCounts: counts)
        var evaluation: Evaluation?
        if case .ready = readiness {
            evaluation = Evaluator.leaveOneOut(labeled.map { LabeledSample(id: $0.0.id, features: $0.0.features.vector, label: $0.1) })
        }
        let points = labeled.compactMap { item, meaning -> InsightsSummary.Point? in
            guard let f0 = item.features.f0Mean else { return nil }
            return InsightsSummary.Point(id: item.id, durationS: item.features.durationS, f0Mean: f0,
                                         meaning: top.contains(meaning) ? meaning : otherLabel)
        }
        return InsightsSummary(labeledCount: labeled.count, unlabeledCount: items.count - labeled.count, labelCounts: counts,
                               readiness: readiness, evaluation: evaluation, points: points, legendOrder: legend)
    }

    @MainActor
    static func summarize(animal: Animal, context: ModelContext) throws -> InsightsSummary {
        let animalID = animal.id
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animal?.id == animalID }))
        let items = recordings.flatMap { $0.vocalizations ?? [] }
            .map { Item(id: $0.id, features: $0.features, meaning: $0.meaningTag) }
        return summarize(items)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 2 new tests pass, 0 failures.

- [ ] **Step 5: Write the views**

`App/Views/Voice/InsightsView.swift`:
```swift
import Charts
import AnimalVoiceStats
import SwiftData
import SwiftUI

struct InsightsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.selectedAnimal) private var animal
    @Query private var recordings: [VoiceRecording]   // observed so the view refreshes when data changes

    private var summary: InsightsSummary? {
        guard let animal else { return nil }
        return try? InsightsModel.summarize(animal: animal, context: context)
    }

    var body: some View {
        List {
            if let animal, let summary {
                Section("Readiness for \(animal.name)") {
                    switch summary.readiness {
                    case .ready(let labels):
                        Label("Ready to predict across \(labels.count) meanings", systemImage: "checkmark.circle")
                    case .notReady(let message, _):
                        Label(message, systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                    if let e = summary.evaluation {
                        LabeledContent("Leave-one-out accuracy", value: "\(Int(e.accuracy * 100))% (n = \(e.n))")
                    }
                    LabeledContent("Labeled sounds", value: "\(summary.labeledCount)")
                    LabeledContent("Unlabeled sounds", value: "\(summary.unlabeledCount)")
                }
                Section("Duration and pitch by meaning") {
                    if summary.points.isEmpty {
                        Text("Tag some voiced sounds to see them here.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Chart(summary.points) { p in
                            PointMark(x: .value("Duration (s)", p.durationS), y: .value("Pitch (Hz)", p.f0Mean))
                                .foregroundStyle(by: .value("Meaning", p.meaning))
                                .symbol(by: .value("Meaning", p.meaning))
                                .symbolSize(60)
                        }
                        .chartForegroundStyleScale(domain: summary.legendOrder, range: SeriesPalette.colors(for: summary.legendOrder))
                        .chartXAxisLabel("Duration (s)")
                        .chartYAxisLabel("Pitch (Hz)")
                        .chartLegend(position: .bottom)
                        .frame(height: 260)
                    }
                }
                Section("Labeled sounds per meaning") {
                    ForEach(summary.labelCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { label, n in
                        LabeledContent(label, value: "\(n)")
                    }
                }
            } else {
                Text("Select an animal to see insights.").foregroundStyle(.secondary)
            }
        }
    }
}

/// Six categorical hues validated for colorblind separation on light and dark surfaces, in fixed order; "Other" is gray.
enum SeriesPalette {
    static let slots: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5),
        dynamic(light: 0xEB6834, dark: 0xD95926),
        dynamic(light: 0x1BAF7A, dark: 0x199E70),
        dynamic(light: 0xEDA100, dark: 0xC98500),
        dynamic(light: 0xE87BA4, dark: 0xD55181),
        dynamic(light: 0x008300, dark: 0x008300),
    ]
    static let other = Color.gray

    static func colors(for legend: [String]) -> [Color] {
        legend.enumerated().map { index, name in
            name == InsightsModel.otherLabel ? other : slots[min(index, slots.count - 1)]
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
```

`App/Views/Voice/ManageVoiceTagsView.swift`:
```swift
import SwiftData
import SwiftUI

/// Rename or add activity and meaning tags. Built-in tags can be renamed but not deleted; custom tags delete freely
/// (labels on existing sounds keep the old name, which is why rename is the safer edit).
struct ManageVoiceTagsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]
    @State private var newName = ""
    @State private var newKind: VoiceTagKind = .meaning

    var body: some View {
        List {
            Section("Add") {
                Picker("Kind", selection: $newKind) {
                    Text("Meaning").tag(VoiceTagKind.meaning)
                    Text("Activity").tag(VoiceTagKind.activity)
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("New tag", text: $newName)
                    Button("Add") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !tags.contains(where: { $0.kind == newKind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
                        context.insert(VoiceTag(kind: newKind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
                        try? context.save()
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            section("Meanings", kind: .meaning)
            section("Activities", kind: .activity)
        }
        .navigationTitle("Voice tags")
    }

    private func section(_ title: String, kind: VoiceTagKind) -> some View {
        Section(title) {
            ForEach(tags.filter { $0.kind == kind }) { tag in
                HStack {
                    TextField("Name", text: Binding(get: { tag.name }, set: { tag.name = $0; try? context.save() }))
                    if tag.isBuiltIn { Text("built-in").font(.caption2).foregroundStyle(.secondary) }
                }
                .swipeActions {
                    if !tag.isBuiltIn {
                        Button("Delete", role: .destructive) { context.delete(tag); try? context.save() }
                    }
                }
            }
        }
    }
}
```

Modify `App/Views/Voice/VoiceTabView.swift`: replace `case .insights: Text("Insights")` with `case .insights: InsightsView()`.

Modify `App/Views/Settings/SettingsView.swift`: replace `SettingsPlaceholderRow(title: "Voice tags")` with `NavigationLink("Voice tags") { ManageVoiceTagsView() }`.

- [ ] **Step 6: Build, run, commit**

Run: `scripts/test-packages.sh`, `scripts/test-app.sh`, `scripts/run-sim.sh`. Expected: all pass, build succeeds.

```bash
git add -A
git commit -m "feat(voice): Insights with readiness, accuracy, duration-pitch scatter; manage voice tags in Settings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
