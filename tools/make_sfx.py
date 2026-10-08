#!/usr/bin/env python3
"""Synthesizes the GDTris sound effects into assets/sfx/.

    python3 tools/make_sfx.py            # writes assets/sfx/
    python3 tools/make_sfx.py --preview  # also /tmp/gdtris-sfx-preview.wav (each sound in turn)
                                         # and /tmp/gdtris-sfx-demo.wav (a game's worth, layered)

Everything is made here, with no samples: detuned synth plucks, FM glass, cinematic impacts and
filtered-noise whooshes, in a stereo hall. The random seed is fixed, so every run gives the same files.

The input sounds (move, rotate, soft drop, lock, hard drop) are short mono WAV, which plays with no
decode delay. The rest are stereo Ogg Vorbis, because their reverb tails would be large as WAV.

Levels: each sound is set to its target in TARGETS, in LUFS (ITU-R BS.1770 K-weighting, the loudest
400 ms), so the game plays every file at 0 dB and the whole balance is set in that one table.
"""

import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
from scipy import signal

SR = 44100
OUT = Path(__file__).resolve().parent.parent / "assets" / "sfx"
rng = np.random.default_rng(11)

# Short sounds that play on every input: mono WAV
MONO = {"move", "rotate", "softdrop", "lock", "harddrop"}

# Loudness of each sound in LUFS (the loudest 400 ms). Combos are louder than the clear they play
# over, so the climb is heard; inputs are quiet because they play many times a second.
TARGETS = {
    "move": -36, "rotate": -34, "softdrop": -38, "lock": -31, "harddrop": -26,
    "hold": -28, "spin": -25,
    "clear_1": -21, "clear_2": -20, "clear_3": -19, "clear_quad": -16, "clear_spin": -16,
    "btb": -21, "btb_break": -20, "combo_break": -22,
    "allclear": -14.5, "topout": -17, "start": -22,
    "garbage_rise": -18, "block": -20, "warning": -24, "alert": -19, "garbage_alarm": -15,
    "garbage_in_small": -20, "garbage_in_medium": -18, "garbage_in_large": -16,
    "garbage_out_small": -20, "garbage_out_medium": -18, "garbage_out_large": -16,
    "thunder_1": -17, "thunder_2": -15, "thunder_3": -13,
}
COMBOS = 16
for i in range(1, COMBOS + 1):
    TARGETS[f"combo_{i}"] = -19.5 + (i - 1) / (COMBOS - 1)

NOTE_INDEX = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3, "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}


def hz(name):
    """'A4' -> 440.0"""
    return 440.0 * 2 ** ((NOTE_INDEX[name[:-1]] + 12 * (int(name[-1]) - 4)) / 12)


def times(seconds):
    return np.arange(int(round(SR * seconds))) / SR


def noise(seconds):
    return rng.uniform(-1, 1, int(round(SR * seconds)))


# ---- Stereo: every mixed signal is (samples, 2); mono arrays are placed with pan() -------------

def pan(x, position=0.0):
    """Constant-power pan of a mono signal, -1 left to 1 right. Stereo input is returned as is."""
    if x.ndim == 2:
        return x
    angle = (position + 1) * np.pi / 4
    return np.stack([x * np.cos(angle), x * np.sin(angle)], axis=1)


def wide_noise(seconds):
    return np.stack([noise(seconds), noise(seconds)], axis=1) * 0.7071


def fade(x, fade_in=0.001, fade_out=0.01):
    x = x.copy()
    a, b = min(int(SR * fade_in), len(x) // 2), min(int(SR * fade_out), len(x) // 2)
    ramp_shape = (slice(None),) + (None,) * (x.ndim - 1)
    if a:
        x[:a] *= np.linspace(0, 1, a)[ramp_shape]
    if b:
        x[-b:] *= np.linspace(1, 0, b)[ramp_shape]
    return x


def place(length, *parts):
    """Mix (start in seconds, signal, gain) parts. The buffer grows to fit every part, and each part
    fades out over its last 10 ms: cutting a ringing note short would click."""
    end = max([int(SR * length)] + [int(SR * start) + len(x) for start, x, _ in parts])
    out = np.zeros((end, 2))
    for start, x, gain in parts:
        i = int(SR * start)
        out[i:i + len(x)] += gain * fade(pan(x), 0, 0.01)
    return out


def env(seconds, attack, decay):
    t = times(seconds)
    return (1 - np.exp(-t / max(attack, 1e-4))) * np.exp(-t / decay)


def scale_env(x, e):
    return x * (e[:, None] if x.ndim == 2 else e)


# ---- Filters -----------------------------------------------------------------------------------

def lowpass(x, cutoff, order=2):
    b, a = signal.butter(order, min(cutoff / (SR / 2), 0.99))
    return signal.lfilter(b, a, x, axis=0)


def highpass(x, cutoff, order=2):
    b, a = signal.butter(order, cutoff / (SR / 2), btype="high")
    return signal.lfilter(b, a, x, axis=0)


def bandpass(x, lo, hi, order=2):
    b, a = signal.butter(order, [lo / (SR / 2), min(hi / (SR / 2), 0.99)], btype="band")
    return signal.lfilter(b, a, x, axis=0)


def sweep(x, f_start, f_end, kind="low", tau=None, q=1.0, block=64):
    """Second-order filter whose cutoff glides from f_start to f_end: exponentially over the whole
    signal, or settling with time constant tau. Done in short blocks, carrying the filter state."""
    n = len(x)
    out = np.zeros_like(x)
    zi = None
    for i in range(0, n, block):
        if tau is None:
            fc = f_start * (f_end / f_start) ** (i / max(n - 1, 1))
        else:
            fc = f_end + (f_start - f_end) * np.exp(-i / SR / tau)
        fc = float(np.clip(fc, 30, SR * 0.45))
        if kind == "low":
            b, a = signal.butter(2, fc / (SR / 2))
        else:
            half = 1 + 1 / (2 * q)
            b, a = signal.butter(1, [fc / half / (SR / 2), min(fc * half / (SR / 2), 0.99)], btype="band")
        if zi is None:
            zi = np.zeros((2,) + x.shape[1:])
        out[i:i + block], zi = signal.lfilter(b, a, x[i:i + block], axis=0, zi=zi)
    return out


# ---- Oscillators -------------------------------------------------------------------------------

def phase_of(freq, n):
    """Phase in cycles for a constant or per-sample frequency."""
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,))
    return np.cumsum(f / SR) + rng.random(), f / SR


def saw(freq, seconds):
    """PolyBLEP sawtooth: the jump each cycle is smoothed, so it does not alias."""
    n = int(round(SR * seconds))
    p, dt = phase_of(freq, n)
    p %= 1.0
    y = 2 * p - 1
    lo = p < dt
    x = p[lo] / dt[lo]
    y[lo] -= x + x - x * x - 1
    hi = p > 1 - dt
    x = (p[hi] - 1) / dt[hi]
    y[hi] -= x * x + x + x + 1
    return y


def sine(freq, seconds):
    n = int(round(SR * seconds))
    p, _ = phase_of(freq, n)
    return np.sin(2 * np.pi * p)


def glide(f_start, f_end, seconds, tau=None):
    """Per-sample frequency: exponential from f_start to f_end, or settling with time constant tau."""
    t = times(seconds)
    if tau is None:
        return f_start * (f_end / f_start) ** (t / seconds)
    return f_end + (f_start - f_end) * np.exp(-t / tau)


def supersaw(freq, seconds, voices=7, detune_cents=16, spread=0.85):
    """Detuned saws spread across the stereo field: the wide synth body."""
    out = np.zeros((int(round(SR * seconds)), 2))
    for k, o in enumerate(np.linspace(-1, 1, voices)):
        v = saw(np.asarray(freq) * 2 ** (o * detune_cents / 1200), seconds)
        out += pan(v, o * spread) * (1.0 if k == voices // 2 else 0.8)
    return out / voices


# ---- Instruments -------------------------------------------------------------------------------

def pluck(freq, seconds=1.4, bright=1.0, decay=0.4, voices=7):
    """Synth pluck: a supersaw through a low pass that closes fast after the attack."""
    body = supersaw(freq, seconds, voices)
    body = sweep(body, min(15000, freq * 14 * bright), freq * 1.8, "low", tau=0.08 * bright)
    sub = pan(sine(freq / 2, seconds), 0) * 0.3
    return fade(scale_env(body + sub, env(seconds, 0.002, decay)), 0.001, 0.03)


def glass(freq, seconds=1.8, decay=0.7, index=2.6, ratio=3.5):
    """FM glass: an inharmonic modulator whose depth falls after the strike. Left and right are
    detuned by a few cents and the right is 7 ms late, which makes it wide."""
    t = times(seconds)
    depth = index * np.exp(-t / 0.12) + 0.25
    chans = []
    for det in (1.0, 1.0025):
        ph = 2 * np.pi * freq * det * t + rng.random() * 6.28
        chans.append(np.sin(ph + depth * np.sin(ratio * ph)) * np.exp(-t / decay))
    right = np.concatenate([np.zeros(int(SR * 0.007)), chans[1]])[:len(t)]
    return fade(np.stack([chans[0], right], axis=1) * 0.7, 0.0015, 0.03)


def note(name, bright=1.0, seconds=1.4):
    """The combo voice: a pluck with glass an octave up."""
    f = hz(name)
    return place(seconds, (0, pluck(f, seconds, bright), 1.0), (0, glass(2 * f, seconds, 0.6), 0.45 * bright))


def chord(names, strum=0.01, bright=1.0, seconds=1.6, decay=0.45):
    gain = 1 / np.sqrt(len(names))
    return place(seconds, *[(i * strum, pluck(hz(n), seconds, bright, decay), gain) for i, n in enumerate(names)])


def pad(names, seconds=2.4, attack=0.12, hold=0.5, release=0.9, cutoff=3200):
    """A held supersaw chord with a soft attack, for the perfect clear."""
    t = times(seconds)
    shape = np.minimum(1, t / attack) * np.where(t < hold, 1.0, np.exp(-(t - hold) / release))
    body = sum(supersaw(hz(n), seconds, 5, 20) for n in names) / np.sqrt(len(names))
    return fade(scale_env(lowpass(body, cutoff), shape), 0.002, 0.05)


def kick(f_start, f_end, seconds, pitch_tau, amp_tau, drive=1.6):
    """Thud: a sine falling quickly in pitch, slightly saturated, easing to zero at the end."""
    t = times(seconds)
    y = sine(glide(f_start, f_end, seconds, tau=pitch_tau), seconds) * np.exp(-t / amp_tau)
    tail = np.clip((seconds - t) / (0.3 * seconds), 0, 1)
    return np.tanh(drive * y) / np.tanh(drive) * (0.5 - 0.5 * np.cos(np.pi * tail))


def crack(seconds=0.05, lo=900, hi=9000, tau=0.01):
    return bandpass(noise(seconds), lo, hi) * np.exp(-times(seconds) / tau)


def metal(f0, seconds, size=1.0):
    """Struck metal: inharmonic partials, each panned a little differently."""
    t = times(seconds)
    out = np.zeros((len(t), 2))
    for k, (r, d) in enumerate([(1, 1.2), (1.47, 0.9), (2.09, 0.7), (2.56, 0.5), (3.37, 0.35), (4.18, 0.25)]):
        out += pan(np.sin(2 * np.pi * f0 * r * t + rng.random() * 6.28) * np.exp(-t / (d * size)) / (k + 1), rng.uniform(-0.5, 0.5))
    return fade(out, 0.001, 0.05)


def impact(size=1.0, seconds=2.2, ring_hz=310):
    """Cinematic hit: sub boom, punch, crack, a burst of air and a metallic ring."""
    t = times(seconds)
    sub = sine(glide(64, 30, seconds, tau=0.3), seconds) * np.exp(-t / (0.5 * size))
    body = lowpass(wide_noise(seconds), 1600) * np.exp(-t / (0.12 * size))[:, None]
    return place(seconds,
                 (0, sub, 0.9), (0, kick(180, 48, 0.45, 0.02, 0.08), 0.8),
                 (0, pan(crack(), -0.25), 0.45), (0.002, pan(crack(), 0.25), 0.45),
                 (0, body, 0.4), (0, metal(ring_hz, seconds, size), 0.12))


def whoosh(seconds, f_start, f_end, pan_from=0.0, pan_to=0.0, q=1.2):
    """Noise through a band pass gliding from f_start to f_end, swelling then fading, panned across."""
    x = sweep(noise(seconds), f_start, f_end, "band", q=q)
    x = x / (np.max(np.abs(x)) + 1e-9) * np.sin(np.pi * np.linspace(0, 1, len(x))) ** 1.5
    angle = (np.linspace(pan_from, pan_to, len(x)) + 1) * np.pi / 4
    return np.stack([x * np.cos(angle), x * np.sin(angle)], axis=1)


def riser(seconds, f_start=400, f_end=9000):
    """Rising air and tone that build to the end, for a sound that leads into a hit."""
    t = times(seconds)
    build = (t / seconds) ** 2
    air = sweep(wide_noise(seconds), f_start, f_end, "band", q=1.0) * build[:, None]
    tone = pan(sine(glide(f_start / 2, f_end / 8, seconds), seconds) * build * 0.3, 0)
    return air / (np.max(np.abs(air)) + 1e-9) + tone


def downer(f_start, f_end, seconds, cutoff_start=6000, cutoff_end=250):
    """A supersaw falling in pitch while its filter closes: losing power."""
    body = supersaw(glide(f_start, f_end, seconds), seconds, 5, 22)
    body = sweep(body, cutoff_start, cutoff_end, "low")
    t = times(seconds)
    return fade(scale_env(body, np.minimum(1, t / 0.01) * np.exp(-t / (seconds * 0.6))), 0.001, 0.05)


def shimmer(names, step=0.026, gain=1.0):
    return place(len(names) * step + 1.5, *[(i * step, glass(hz(n), 1.5, 0.45), gain * 0.88 ** i) for i, n in enumerate(names)])


HALLS = {}


def hall(x, wet=0.3, seconds=2.4, tone=6500, predelay=0.022):
    """Stereo hall: left and right are separate decaying noises (so the tail is wide), bright early
    and darker as they fade, after a short pre-delay and a few early reflections."""
    key = (seconds, tone, predelay)
    if key not in HALLS:
        t = times(seconds)
        irs = []
        for side in range(2):
            n = noise(seconds)
            tail = lowpass(n, tone) * np.exp(-6.9 * t / (seconds * 0.55)) + lowpass(n, tone / 4) * np.exp(-6.9 * t / seconds)
            early = np.zeros(len(t))
            for d, g in [(0.009, 0.6), (0.014, 0.45), (0.021, 0.35), (0.029, 0.3), (0.037, 0.22)]:
                early[int(SR * (d + 0.003 * side))] = g * (1 if (side + int(d * 1000)) % 2 else -1)
            ir = np.concatenate([np.zeros(int(SR * predelay)), early + 0.5 * tail * (t > 0.01)])
            irs.append(ir / np.sqrt(np.sum(ir ** 2)))
        HALLS[key] = irs
    x = pan(x)
    mono = x.mean(axis=1)
    pad_len = len(HALLS[key][0])
    dry = np.concatenate([x, np.zeros((pad_len, 2))])
    wet_lr = np.stack([np.pad(signal.fftconvolve(mono, ir), (0, 1))[:len(dry)] for ir in HALLS[key]], axis=1)
    return fade(dry + wet * 2.5 * wet_lr, 0, 0.08)


def room(x, wet=0.12, seconds=0.35):
    """A small, dark room for the short sounds (mono in, mono out)."""
    y = hall(x, wet, seconds, tone=3500, predelay=0.004)
    return y.mean(axis=1)


# ---- The sounds --------------------------------------------------------------------------------

SCALE = ["G4", "A4", "B4", "C5", "D5", "E5", "F#5", "G5", "A5", "B5", "C6", "D6", "E6", "F#6", "G6", "A6"]
SPARKLE = ["D6", "E6", "G6", "A6", "B6", "D7", "E7", "G7"]


def make():
    s = {}

    # Inputs: short and dry, they play many times a second
    t = times(0.02)
    s["move"] = fade(crack(0.02, 2500, 7500, 0.0028) + 0.45 * np.sin(2 * np.pi * 3000 * t) * np.exp(-t / 0.004), 0.0003, 0.005)
    t = times(0.07)
    ph = 2 * np.pi * 1500 * t
    tick = np.sin(ph + 1.8 * np.exp(-t / 0.01) * np.sin(2.5 * ph)) * np.exp(-t / 0.02)
    s["rotate"] = fade(tick + 0.35 * np.pad(crack(0.003, 2500, 9000, 0.0007), (0, len(t) - int(round(SR * 0.003)))), 0.0005, 0.01)
    t = times(0.045)
    s["softdrop"] = fade(sine(glide(240, 150, 0.045), 0.045) * np.exp(-t / 0.013) + 0.2 * lowpass(noise(0.045), 1500) * np.exp(-t / 0.003), 0.0005, 0.01)
    s["lock"] = room(place(0.2, (0, kick(200, 80, 0.18, 0.014, 0.05), 1.0), (0, crack(0.004, 1500, 8000, 0.001), 0.3)).mean(axis=1), 0.1, 0.25)
    s["harddrop"] = room(place(0.45, (0, kick(190, 42, 0.45, 0.018, 0.09, drive=2.0), 1.0),
                               (0, sine(glide(80, 38, 0.45, tau=0.06), 0.45) * np.exp(-times(0.45) / 0.14), 0.6),
                               (0, crack(0.03, 1200, 9000, 0.004), 0.55)).mean(axis=1), 0.14, 0.35)

    # Spin: a snap and a breath of air, then a quick glass strum up E6-B6-E7. It rises in steps, not
    # in a glide (a gliding tone sounds like a slide whistle), and it starts on the key press.
    air = highpass(wide_noise(0.12), 5000) * np.exp(-times(0.12) / 0.03)[:, None]
    s["spin"] = hall(place(0.8, (0, pan(crack(0.012, 3000, 14000, 0.0025), 0), 0.5), (0, air, 0.2),
                           (0, glass(hz("E6"), 0.9, 0.22, 1.6), 0.45), (0.022, glass(hz("B6"), 0.9, 0.2, 1.6), 0.45),
                           (0.044, glass(hz("E7"), 0.9, 0.18, 1.4), 0.4)), 0.22, 1.2)
    # Hold: a swoosh across the field
    s["hold"] = hall(place(0.6, (0, whoosh(0.2, 450, 3500, 0.6, -0.6), 0.7), (0.06, glass(hz("B5"), 0.8, 0.25), 0.25)), 0.22, 1.0)

    # Line clears: air falling across the field, a struck synth chord, glass on top; more lines, more notes
    voicings = {1: ["G3", "D4", "G4", "B4"], 2: ["G3", "D4", "G4", "B4", "D5"], 3: ["G3", "D4", "A4", "B4", "D5", "F#5"]}
    tops = {1: ["D6"], 2: ["G6"], 3: ["B6", "D7"]}
    for lines in (1, 2, 3):
        parts = [(0, whoosh(0.4, 7500, 700, -0.5, 0.5), 0.45),
                 (0, chord(voicings[lines], 0.009, 0.9 + 0.12 * lines), 1.0)]
        parts += [(0.025 + 0.03 * k, glass(hz(n), 1.6, 0.6), 0.32) for k, n in enumerate(tops[lines])]
        if lines == 3:
            parts.append((0, impact(0.6, 1.6), 0.45))
        s[f"clear_{lines}"] = hall(place(1.6, *parts), 0.32, 2.2)

    # Quad: a full cinematic hit under a wide Gmaj9 stab, a glass arpeggio and shimmer
    s["clear_quad"] = hall(place(2.6,
                                 (0, impact(1.25, 2.6), 0.9),
                                 (0, whoosh(0.5, 9000, 500, 0.6, -0.6), 0.35),
                                 (0.004, chord(["G2", "G3", "D4", "A4", "B4", "F#5"], 0.006, 1.35, 1.8, 0.6), 1.0),
                                 (0.06, place(0.6, *[(i * 0.045, glass(hz(n), 1.6, 0.55), 0.4) for i, n in enumerate(["G5", "B5", "D6", "F#6", "A6"])]), 1.0),
                                 (0.3, shimmer(["D7", "B6", "G6", "D7"], 0.05), 0.25)), 0.4, 3.0)

    # T-spin clear: an FM zap rising into a hit, with a minor ninth chord
    t = times(0.32)
    zap_ph = 2 * np.pi * np.cumsum(glide(300, 1500, 0.32)) / SR
    zap = np.sin(zap_ph + (4 * np.exp(-t / 0.1) + 0.8) * np.sin(1.5 * zap_ph)) * env(0.32, 0.003, 0.15)
    s["clear_spin"] = hall(place(2.4,
                                 (0, pan(zap, 0), 0.5), (0, whoosh(0.25, 900, 8000, -0.6, 0.6), 0.35),
                                 (0.02, impact(0.95, 2.2, 260), 0.75),
                                 (0.03, chord(["E3", "B3", "D4", "F#4", "G4", "B4"], 0.008, 1.2, 1.8, 0.55), 0.95),
                                 (0.08, glass(hz("E6"), 1.6, 0.6), 0.35), (0.12, glass(hz("B6"), 1.6, 0.5), 0.3)), 0.4, 3.0)

    # Back-to-back: a rising shimmer laid over the clear; losing it, a falling, closing saw
    s["btb"] = hall(place(1.6, (0, shimmer(SPARKLE[:7], 0.024), 1.0), (0, riser(0.35, 2000, 12000), 0.12)), 0.5, 2.6)
    s["btb_break"] = hall(place(1.4, (0, downer(hz("G4"), hz("G2"), 0.7), 0.9), (0, kick(120, 40, 0.5, 0.05, 0.18), 0.6),
                                (0, whoosh(0.5, 5000, 400, 0.4, -0.4), 0.3)), 0.32, 1.8)

    # Combo: up the G major scale, a pluck with glass; it brightens as it climbs
    for i, n in enumerate(SCALE, start=1):
        bright = 0.85 + 0.03 * i
        s[f"combo_{i}"] = hall(note(n, bright), 0.28 + 0.006 * i, 1.6)
    s["combo_break"] = hall(place(1.0, (0, note("E4", 0.6, 0.9), 0.85), (0.065, note("B3", 0.5, 1.0), 1.0),
                                  (0, kick(140, 60, 0.14, 0.02, 0.045), 0.35), (0, whoosh(0.3, 3000, 400, 0, 0), 0.2)), 0.25, 1.4)

    # Perfect clear: a big hit, a fanfare up two octaves, a held Gmaj9 swell and shimmer
    run = ["G4", "B4", "D5", "F#5", "A5", "B5", "D6", "G6"]
    s["allclear"] = hall(place(3.6,
                               (0, impact(1.45, 3.0), 0.85),
                               (0, place(0.8, *[(i * 0.05, note(n, 1.15, 1.6), 0.42) for i, n in enumerate(run)]), 1.0),
                               (0.4, pad(["G3", "D4", "F#4", "A4", "B4", "D5"], 2.6), 0.55),
                               (0.45, shimmer(SPARKLE, 0.032), 0.4)), 0.45, 3.5)

    # Top out: a hit, then a long fall in pitch and brightness over a rumble
    s["topout"] = hall(place(2.2,
                             (0, impact(1.1, 2.0, 180), 0.7),
                             (0, downer(hz("G4"), hz("G1"), 1.7, 5000, 180), 1.0),
                             (0, lowpass(wide_noise(1.8), 220) * np.exp(-times(1.8) / 0.7)[:, None], 1.6)), 0.35, 3.0)

    # New game: air rising into a glass fifth
    s["start"] = hall(place(1.6, (0, riser(0.32, 400, 8000), 0.35),
                            (0.3, note("D5", 0.8, 1.2), 0.6), (0.3, glass(hz("A5"), 1.6, 0.7), 0.5)), 0.38, 2.5)

    # Survival, with the roles of TETR.IO's garbage and danger sounds. Small speakers cannot play the
    # low part of a hit, and these sounds must be heard on them: the hits are driven hard, so their
    # overtones carry them, and their lows are cut so that the crunch and clank above take most of
    # the loudness. Each loses about 5 dB through a 300 Hz high pass (a laptop speaker), as the clear
    # sounds do.
    def hit(f0, seconds, drive, crunch_tau):
        t = times(seconds)
        crunch = bandpass(wide_noise(seconds), 500, 3500) * np.exp(-t / crunch_tau)[:, None]
        thud = highpass(kick(f0, f0 * 0.45, seconds, 0.02, seconds * 0.25, drive), 200)
        return place(seconds, (0, thud, 1.0), (0, crunch, 1.0))

    def drone(names, seconds):
        body = lowpass(sum(supersaw(hz(n), seconds, 5, 18) for n in names) / len(names), 1500)
        return fade(scale_env(body, env(seconds, 0.02, seconds * 0.35)), 0.001, 0.05)

    # Garbage rising into the board: stone grinding up (middle-band noise, broken into grains) over
    # a hard, dull thud and a clank
    t = times(0.45)
    grains = 0.6 + 0.4 * np.tanh(4 * np.sin(2 * np.pi * 38 * t))
    grind = bandpass(wide_noise(0.45), 400, 2800) * (grains * np.minimum(1, t / 0.02) * np.exp(-t / 0.12))[:, None]
    s["garbage_rise"] = hall(place(0.7, (0, highpass(kick(200, 80, 0.4, 0.02, 0.1, 4.5), 220), 0.9), (0, grind, 1.3),
                                   (0.01, metal(190, 0.6, 0.3), 0.35), (0, pan(crack(0.012, 1500, 9000, 0.003), 0), 0.5)), 0.16, 1.2)
    # Blocking it: a hard, bright strike, like a shield taking a hit, with glass a fifth apart
    s["block"] = hall(place(0.8, (0, pan(crack(0.01, 2000, 12000, 0.002), 0), 0.6), (0, metal(780, 0.5, 0.25), 0.3),
                            (0, glass(hz("D6"), 0.8, 0.25, 2.0), 0.45), (0.006, glass(hz("A6"), 0.8, 0.2, 1.8), 0.35)), 0.22, 1.2)

    # An attack coming in (it joins the queue): air falling in onto a hard, dull hit; the bigger the
    # attack, the heavier the hit, and a large one brings a clang and a dark drone with it
    # Each hit lands with a crack and the clang of a block of metal, so it cuts through
    def clang(f0, size):
        return place(0.8, (0, pan(crack(0.012, 1500, 9000, 0.003), 0), 0.6), (0, metal(f0, 0.8, size), 0.55))
    s["garbage_in_small"] = hall(place(0.7, (0, whoosh(0.14, 5000, 900, 0.3, -0.1), 0.4),
                                       (0.09, hit(260, 0.3, 4.0, 0.03), 0.8), (0.09, clang(520, 0.25), 0.7)), 0.18, 1.0)
    s["garbage_in_medium"] = hall(place(1.0, (0, whoosh(0.22, 6000, 700, 0.5, -0.2), 0.45),
                                        (0.14, hit(220, 0.45, 4.5, 0.05), 1.0), (0.14, clang(410, 0.35), 0.8)), 0.22, 1.4)
    s["garbage_in_large"] = hall(place(1.6, (0, whoosh(0.3, 7000, 500, 0.6, -0.3), 0.5),
                                       (0.2, hit(190, 0.7, 5.0, 0.08), 1.0), (0.2, highpass(impact(1.0, 1.6, 220), 200), 0.6),
                                       (0.2, clang(330, 0.5), 0.8), (0.2, drone(["A2", "E3", "A3"], 1.2), 0.5)), 0.28, 2.0)

    # A big attack coming (10 lines or more waiting): an alarm horn, two harsh blasts a tritone wide,
    # on a hit
    def blast(names, seconds=0.2):
        t = times(seconds)
        body = bandpass(sum(saw(hz(n), seconds) for n in names) / len(names), 250, 3500)
        shape = np.minimum(1, t / 0.008) * np.where(t < seconds * 0.7, 1.0, np.exp(-(t - seconds * 0.7) / 0.03))
        return fade(np.tanh(2.5 * body / (np.max(np.abs(body)) + 1e-9)) * shape, 0.001, 0.01)
    horn = ["E4", "A#4", "E5"]
    s["garbage_alarm"] = hall(place(1.0, (0, blast(horn), 0.8), (0.27, blast(horn), 0.8),
                                    (0, highpass(impact(1.0, 1.2, 300), 150), 0.5), (0, clang(330, 0.4), 0.5)), 0.2, 1.4)

    # The stack is near the top (a warning): two soft struck notes falling a semitone, each on a
    # muted knock
    knock = kick(170, 80, 0.15, 0.02, 0.04, 3.0)
    s["warning"] = hall(place(1.0, (0, note("E4", 0.55, 0.8), 0.7), (0.22, note("D#4", 0.5, 0.9), 0.7),
                              (0, knock, 0.3), (0.22, knock, 0.3)), 0.22, 1.5)

    # About to die (the X's): a sharp alarm, three fast beeps high-low-high, on a hard hit
    def beep(name, seconds=0.075):
        f = hz(name)
        t = times(seconds)
        tone = lowpass(saw(f, seconds), 4000) * 0.6 + sine(2 * f, seconds) * 0.25
        return fade(tone * np.minimum(1, t / 0.003) * np.exp(-t / 0.08), 0.001, 0.01)
    s["alert"] = hall(place(0.6, (0, beep("E6"), 0.8), (0.1, beep("B5"), 0.8), (0.2, beep("E6"), 0.8),
                            (0, kick(220, 90, 0.25, 0.015, 0.06, 4.0), 0.5)), 0.15, 0.9)

    # An attack going out, like a shot: a crack, a bright metallic zing (FM at one pitch, its
    # brightness falling fast; no slide), a driven punch and air rushing away. A medium one adds a
    # glass fifth, a large one a hit and a short glass shimmer. The game plays it 60 ms after the
    # clear sound, so the two are heard apart.
    def zing(f, seconds=0.35, index=6.0):
        t = times(seconds)
        ph = 2 * np.pi * f * t
        tone = np.sin(ph + index * np.exp(-t / 0.04) * np.sin(1.41 * ph)) * np.exp(-t / 0.09)
        return fade(tone, 0.001, 0.02)
    def shot(f, punch):
        return place(0.5, (0, pan(crack(0.012, 2500, 12000, 0.0025), 0), 0.6), (0, pan(zing(f), 0), 0.55),
                     (0, highpass(kick(320, 150, 0.2, 0.012, 0.04, 4.0), 200), punch))
    s["garbage_out_small"] = hall(place(0.6, (0, shot(1320, 0.4), 1.0), (0, whoosh(0.16, 900, 8000, -0.2, 0.4), 0.5)), 0.18, 1.0)
    s["garbage_out_medium"] = hall(place(0.9, (0, shot(1175, 0.6), 1.0), (0, whoosh(0.24, 700, 9000, -0.3, 0.6), 0.6),
                                         (0.03, glass(hz("G6"), 0.8, 0.2, 1.6), 0.3), (0.04, glass(hz("D7"), 0.8, 0.16, 1.4), 0.25)), 0.22, 1.3)
    s["garbage_out_large"] = hall(place(1.4, (0, shot(1050, 0.8), 1.0), (0, whoosh(0.34, 500, 10000, -0.4, 0.7), 0.7),
                                        (0, highpass(impact(0.8, 1.4, 330), 150), 0.5),
                                        (0.05, shimmer(["G6", "B6", "D7", "G7"], 0.028), 0.35)), 0.3, 1.9)

    # A big spike (the attack in one burst passes 10, 18 or 26 lines): thunder, as TETR.IO plays it.
    # Lightning cracks (more strokes for a bigger strike), a boom, and a long roll that swells and
    # fades as it rolls on; the biggest has a low brass swell under it. The roll is driven a little,
    # so its overtones carry it on small speakers.
    def strike(seconds, tau):
        return highpass(wide_noise(seconds), 1200) * np.exp(-times(seconds) / tau)[:, None]

    def thunder(size, seconds):
        t = times(seconds)
        swells = np.zeros(len(t))
        for _ in range(4 + 2 * size):
            centre = rng.uniform(0.05, seconds * 0.75)
            width = rng.uniform(0.12, 0.45)
            swells += rng.uniform(0.4, 1.0) * np.exp(-((t - centre) / width) ** 2) * np.exp(-centre / (seconds * 0.45))
        shape = np.minimum(1, t / 0.03) * swells / swells.max()
        roll = bandpass(wide_noise(seconds), 60, 900) * shape[:, None]
        roll = np.tanh(2.0 * roll / (np.abs(roll).max() + 1e-9))
        low = lowpass(wide_noise(seconds), 150) * (np.minimum(1, t / 0.03) * np.exp(-t / (0.6 + 0.3 * size)))[:, None]
        parts = [(0, roll, 0.8), (0, low / (np.abs(low).max() + 1e-9), 0.6), (0, strike(0.25, 0.035), 0.9),
                 (0, kick(95, 32, 1.2, 0.08, 0.35 + 0.1 * size, 2.5), 0.9)]
        for k in range(size):
            parts.append((0.07 + 0.06 * k + rng.uniform(0, 0.03), strike(0.2, 0.025), 0.6))
        return place(seconds, *parts)

    def braam(names, seconds):
        t = times(seconds)
        body = sum(supersaw(hz(n), seconds, 7, 12) for n in names) / len(names)
        body = sweep(body, 250, 1600, "low", tau=0.25)
        shape = np.minimum(1, t / 0.12) * np.where(t < 0.8, 1.0, np.exp(-(t - 0.8) / 0.9))
        body = scale_env(body, shape)
        return fade(np.tanh(2.5 * body / (np.abs(body).max() + 1e-9)), 0.002, 0.1)

    s["thunder_1"] = hall(thunder(1, 2.4), 0.35, 3.0)
    s["thunder_2"] = hall(thunder(2, 3.2), 0.4, 3.5)
    s["thunder_3"] = hall(place(4.5, (0, thunder(3, 4.0), 1.0), (0.05, braam(["D2", "A2", "D3", "F3"], 3.0), 0.5)), 0.42, 4.0)
    return s


# ---- Levels and files --------------------------------------------------------------------------

def _k_weighting():
    """The BS.1770 pre-filter (high shelf about +4 dB above 1.7 kHz, high pass at 38 Hz) for this rate."""
    def shelf(G, Q, fc):
        A = 10 ** (G / 40)
        w0 = 2 * np.pi * fc / SR
        al, c, sA = np.sin(w0) / (2 * Q), np.cos(w0), np.sqrt(A)
        b = [A * ((A + 1) + (A - 1) * c + 2 * sA * al), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - 2 * sA * al)]
        a = [(A + 1) - (A - 1) * c + 2 * sA * al, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - 2 * sA * al]
        return np.array(b) / a[0], np.array(a) / a[0]

    def high_pass(Q, fc):
        w0 = 2 * np.pi * fc / SR
        al, c = np.sin(w0) / (2 * Q), np.cos(w0)
        b, a = [(1 + c) / 2, -(1 + c), (1 + c) / 2], [1 + al, -2 * c, 1 - al]
        return np.array(b) / a[0], np.array(a) / a[0]
    return shelf(3.99984385397, 0.7071752369554193, 1681.9744509555319), high_pass(0.5003270373253953, 38.13547087613982)


K_WEIGHTING = _k_weighting()


def lufs(x):
    """Loudest momentary loudness (400 ms window), BS.1770, in LUFS. Mono counts as one channel."""
    x = x[:, None] if x.ndim == 1 else x
    (b1, a1), (b2, a2) = K_WEIGHTING
    win = int(0.4 * SR)
    y = signal.lfilter(b2, a2, signal.lfilter(b1, a1, x, axis=0), axis=0)
    y = np.concatenate([y, np.zeros((win, y.shape[1]))])
    # Mean square over every 400 ms window, from a running sum
    run = np.concatenate([np.zeros((1, y.shape[1])), np.cumsum(y ** 2, axis=0)])
    power = ((run[win:] - run[:-win]) / win).sum(axis=1)
    return -0.691 + 10 * np.log10(np.max(power) + 1e-15)


def limit(x, ceiling_db=-1.0):
    """Leave everything under 70 % of the ceiling alone and round the peaks off above it."""
    ceiling = 10 ** (ceiling_db / 20)
    knee = 0.7 * ceiling
    mag = np.abs(x)
    over = mag > knee
    out = x.copy()
    out[over] = np.sign(x[over]) * (knee + (ceiling - knee) * np.tanh((mag[over] - knee) / (ceiling - knee)))
    return out


def trim_silence(x, floor_db=-60):
    level = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
    keep = np.nonzero(level > np.max(level) * 10 ** (floor_db / 20))[0]
    return fade(x[:keep[-1] + 1], 0, 0.01) if len(keep) else x


def set_level(x, target):
    x = trim_silence(x - x.mean(axis=0))
    for _ in range(4):  # limiting the peaks lowers the loudness a little, so settle it in a few steps
        x = limit(x * 10 ** ((target - lufs(x)) / 20))
    return x


def write_wav(path, x):
    x = x[:, None] if x.ndim == 1 else x
    data = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(x.shape[1])
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def write_ogg(path, x):
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        write_wav(tmp.name, x)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", tmp.name, "-c:a", "libvorbis", "-q:a", "6", str(path)], check=True)


def demo(sounds):
    """A game's worth of sounds, layered as the game layers them."""
    events, t = [], 0.6

    def at(dt, *names):
        nonlocal t
        t += dt
        events.extend((t, n) for n in names)
    at(0, "start")
    for _ in range(3):
        at(0.9, "move"); at(0.07, "move"); at(0.12, "rotate"); at(0.2, "harddrop")
    at(0.4, "hold"); at(0.3, "rotate"); at(0.1, "softdrop"); at(0.06, "softdrop"); at(0.06, "softdrop"); at(0.55, "lock")
    at(0.7, "harddrop", "clear_1")
    for c in range(1, 7):
        at(0.5, "harddrop", "clear_1", f"combo_{c}")
    at(0.5, "harddrop", "combo_break")
    at(1.0, "rotate"); at(0.15, "spin"); at(0.4, "harddrop", "clear_spin")
    at(1.6, "harddrop", "clear_quad", "btb")
    at(1.8, "harddrop", "clear_2", "btb_break")
    at(1.6, "harddrop", "clear_3")
    at(1.4, "harddrop", "clear_quad", "allclear")
    at(3.8, "topout")
    out = np.zeros((max(int(SR * when) + len(sounds[n]) for when, n in events), 2))
    for when, n in events:
        x = pan(sounds[n])
        i = int(SR * when)
        out[i:i + len(x)] += x
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sounds = {}
    for name, x in make().items():
        y = set_level(x, TARGETS[name])
        if name in MONO:
            y = y if y.ndim == 1 else y.mean(axis=1)
            write_wav(OUT / f"{name}.wav", y)
        else:
            write_ogg(OUT / f"{name}.ogg", pan(y))
        sounds[name] = y
        print(f"{name:18} {'wav' if name in MONO else 'ogg'} {len(y) / SR:5.2f} s  {lufs(y):6.1f} LUFS (target {TARGETS[name]:6.1f})  "
              f"peak {20 * np.log10(np.max(np.abs(y))):5.1f} dBFS")
    if "--preview" in sys.argv:
        gap = np.zeros((int(SR * 0.4), 2))
        write_wav("/tmp/gdtris-sfx-preview.wav", np.concatenate([np.concatenate([pan(y), gap]) for y in sounds.values()]))
        mix = demo(sounds)
        peak = np.max(np.abs(mix))
        write_wav("/tmp/gdtris-sfx-demo.wav", limit(mix, -0.5))
        print(f"preview: /tmp/gdtris-sfx-preview.wav ({', '.join(sounds)})")
        print(f"demo:    /tmp/gdtris-sfx-demo.wav  (layered peak before the limiter {20 * np.log10(peak):.1f} dBFS)")


if __name__ == "__main__":
    main()
