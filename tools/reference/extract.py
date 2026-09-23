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
