"""Reproducible Genesis click packs.

Run: python3 design/build_sounds.py   (needs numpy and scipy)

Each pack is a key click and a shorter dial detent, synthesized from the
parts of a real switch: a broadband contact transient, a few decaying
resonances for the housing, and (for Crunch) a burst of micro-impacts.
Output is 16-bit mono 44.1 kHz WAV, normalized just below full scale so the
in-app volume control has the whole range to work with. The seed is fixed,
so a rebuild produces identical files.
"""
from pathlib import Path
import wave

import numpy as np
from scipy.signal import butter, sosfilt

RATE = 44100
ROOT = Path(__file__).resolve().parent
RESOURCES = ROOT.parent / "ios" / "Resources"
rng = np.random.default_rng(20261116)


def canvas(ms):
    return np.zeros(int(RATE * ms / 1000))


def band(signal, low=None, high=None):
    if low and high:
        sos = butter(2, [low, high], btype="bandpass", fs=RATE, output="sos")
    elif low:
        sos = butter(2, low, btype="highpass", fs=RATE, output="sos")
    else:
        sos = butter(2, high, btype="lowpass", fs=RATE, output="sos")
    return sosfilt(sos, signal)


def add(out, at_ms, part, amp=1.0):
    start = int(RATE * at_ms / 1000)
    end = min(len(out), start + len(part))
    out[start:end] += part[: end - start] * amp


def burst(decay_ms, low=None, high=None, ms=None):
    """Filtered noise with a fast exponential decay: the contact itself."""
    n = int(RATE * (ms or decay_ms * 8) / 1000)
    t = np.arange(n) / RATE
    noise = rng.standard_normal(n)
    if low or high:
        noise = band(noise, low, high)
    part = noise * np.exp(-t / (decay_ms / 1000))
    return part / (np.abs(part).max() + 1e-9)


def ring(freq, decay_ms, ms=None, phase=0.0):
    """One housing resonance."""
    n = int(RATE * (ms or decay_ms * 7) / 1000)
    t = np.arange(n) / RATE
    return np.sin(2 * np.pi * freq * t + phase) * np.exp(-t / (decay_ms / 1000))


def finish(out, drive):
    """Saturate for density, trim the tail to silence, and normalize."""
    out = np.tanh(out / (np.abs(out).max() + 1e-9) * drive)
    fade = int(RATE * 0.003)
    out[-fade:] *= np.linspace(1, 0, fade)
    attack = int(RATE * 0.0002)
    out[:attack] *= np.linspace(0, 1, attack)
    return out / np.abs(out).max() * 0.97


def crunch_key():
    out = canvas(125)
    add(out, 0, burst(1.3, low=900), 1.0)
    for freq, decay, amp in ((1900, 5.0, .42), (2700, 4.2, .38), (3400, 4.0, .46), (5200, 2.6, .30), (7800, 1.5, .16), (330, 16, .55), (660, 9, .30)):
        add(out, 0, ring(freq, decay), amp)
    # The crunch: a ratchet of smaller impacts as the click bar settles.
    for at, amp in ((2.1, .62), (3.9, .50), (5.2, .44), (7.3, .30), (9.6, .22), (12.4, .13)):
        add(out, at, burst(0.65, low=1700, high=9000), amp)
        add(out, at, ring(4100 + rng.uniform(-600, 900), 1.6), amp * .35)
    # Upstroke.
    add(out, 64, burst(0.9, low=2000), .36)
    add(out, 64, ring(4300, 3.0), .20)
    add(out, 66.2, burst(0.6, low=2600, high=9000), .18)
    return finish(out, 2.4)


def crunch_dial():
    out = canvas(38)
    add(out, 0, burst(0.8, low=1800), 1.0)
    for freq, decay, amp in ((4000, 2.0, .42), (2600, 3.0, .30), (420, 6, .34)):
        add(out, 0, ring(freq, decay), amp)
    for at, amp in ((1.5, .45), (3.0, .26)):
        add(out, at, burst(0.5, low=2600, high=9000), amp)
    return finish(out, 2.2)


def thock_key():
    out = canvas(130)
    add(out, 0, burst(2.4, high=2600), .55)
    for freq, decay, amp in ((290, 26, 1.0), (430, 17, .55), (720, 8, .26), (1150, 4, .12)):
        add(out, 0, ring(freq, decay), amp)
    add(out, 70, burst(1.6, high=3000), .16)
    add(out, 70, ring(520, 9), .16)
    return finish(out, 1.8)


def thock_dial():
    out = canvas(48)
    add(out, 0, burst(1.5, high=3000), .5)
    for freq, decay, amp in ((380, 10, 1.0), (640, 6, .4)):
        add(out, 0, ring(freq, decay), amp)
    return finish(out, 1.7)


def clack_key():
    out = canvas(125)
    add(out, 0, burst(0.9, low=2000), 1.0)
    for freq, decay, amp in ((2300, 9, .50), (3650, 7, .40), (6100, 4, .25), (360, 10, .36)):
        add(out, 0, ring(freq, decay), amp)
    add(out, 72, burst(0.7, low=2200), .30)
    add(out, 72, ring(3900, 4), .18)
    return finish(out, 2.0)


def clack_dial():
    out = canvas(40)
    add(out, 0, burst(0.7, low=2200), 1.0)
    for freq, decay, amp in ((3000, 4, .45), (5100, 2.5, .25)):
        add(out, 0, ring(freq, decay), amp)
    return finish(out, 1.9)


def arcade_key():
    out = canvas(70)
    for at, amp in ((0, 1.0), (9.0, .74)):
        add(out, at, burst(0.5, low=1200), amp)
        add(out, at, ring(2900, 2.2), amp * .55)
        add(out, at, ring(1450, 3.0), amp * .40)
        add(out, at, ring(520, 4.0), amp * .30)
    return finish(out, 2.6)


def arcade_dial():
    out = canvas(30)
    add(out, 0, burst(0.45, low=1400), 1.0)
    add(out, 0, ring(3100, 1.8), .5)
    add(out, 0, ring(1500, 2.4), .3)
    return finish(out, 2.3)


def save(name, samples):
    data = (np.clip(samples, -1, 1) * 32767).astype("<i2")
    with wave.open(str(RESOURCES / f"{name}.wav"), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(data.tobytes())
    rms = float(np.sqrt(np.mean(samples ** 2)))
    print(f"{name}.wav  {len(samples) / RATE * 1000:.0f} ms  peak {np.abs(samples).max():.2f}  rms {rms:.3f}")


if __name__ == "__main__":
    for name, build in (("ClickCrunchKey", crunch_key), ("ClickCrunchDial", crunch_dial),
                        ("ClickThockKey", thock_key), ("ClickThockDial", thock_dial),
                        ("ClickClackKey", clack_key), ("ClickClackDial", clack_dial),
                        ("ClickArcadeKey", arcade_key), ("ClickArcadeDial", arcade_dial)):
        save(name, build())
