#!/usr/bin/env python3
"""Builds Zen's notification sounds and sound effects from scratch.

Every sound is synthesised here (additive tones, filtered noise, a short
synthetic room), so the files are Zen's own and can be rebuilt at any time:

    python3 tool/sounds/generate_sounds.py          (from the project root)

Needs numpy and scipy; ffmpeg (with libvorbis) for the Android .ogg files
and the Apple .caf files (IMA4). Writes:

    assets/sounds/<name>.wav                 Flutter assets (in-app playback)
    android/app/src/main/res/raw/<name>.ogg  notification channel sounds
    ios/Runner/Sounds/<name>.caf             notification sounds (bundle)
    macos/Runner/Sounds/<name>.caf

The output is deterministic (fixed noise seeds).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import wave

import numpy as np
from scipy import signal

RATE = 22050
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

# Sounds a notification can carry (Android channels, Apple bundle).
NOTIFICATION_SOUNDS = (
    'zen_message',
    'zen_social',
    'zen_knock',
    'zen_ringtone',
    'zen_alarm',
)


# --- building blocks --------------------------------------------------------


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(round(seconds * RATE)))


def times(seconds: float) -> np.ndarray:
    return np.arange(int(round(seconds * RATE))) / RATE


def hz(name: str) -> float:
    """Frequency of a note name such as 'A4' (equal temperament)."""
    names = {'C': -9, 'D': -7, 'E': -5, 'F': -4, 'G': -2, 'A': 0, 'B': 2}
    step = names[name[0]]
    rest = name[1:]
    if rest.startswith('#'):
        step += 1
        rest = rest[1:]
    elif rest.startswith('b'):
        step -= 1
        rest = rest[1:]
    octave = int(rest)
    return 440.0 * 2 ** ((step + (octave - 4) * 12) / 12)


def envelope(n: int, attack: float, decay: float) -> np.ndarray:
    """A soft attack (raised cosine) and an exponential decay."""
    t = np.arange(n) / RATE
    env = np.exp(-t / decay)
    a = max(1, int(attack * RATE))
    a = min(a, n)
    env[:a] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    return env


def bell(freq: float, seconds: float, decay: float = 0.45,
         partials=((1.0, 1.0, 1.0), (2.0, 0.22, 0.55), (3.01, 0.07, 0.35),
                   (4.2, 0.03, 0.25)),
         attack: float = 0.006) -> np.ndarray:
    """A warm bell / chime: a few partials, upper ones fading faster."""
    t = times(seconds)
    out = np.zeros_like(t)
    for ratio, amp, decay_scale in partials:
        f = freq * ratio
        if f >= RATE / 2 * 0.9:
            continue
        out += amp * np.sin(2 * np.pi * f * t) * envelope(
            len(t), attack, decay * decay_scale)
    # Ends at silence, so a note cut short never clicks.
    return fade(out, 0.0, min(0.06, seconds / 3))


def kalimba(freq: float, seconds: float, decay: float = 0.55) -> np.ndarray:
    """A plucked tine: strong fundamental, inharmonic overtone, quick click."""
    return bell(
        freq,
        seconds,
        decay=decay,
        partials=((1.0, 1.0, 1.0), (5.4, 0.12, 0.12), (2.0, 0.10, 0.5),
                  (8.9, 0.03, 0.05)),
        attack=0.003,
    )


def marimba(freq: float, seconds: float, decay: float = 0.3) -> np.ndarray:
    return bell(
        freq,
        seconds,
        decay=decay,
        partials=((1.0, 1.0, 1.0), (4.0, 0.18, 0.2), (9.9, 0.04, 0.08)),
        attack=0.004,
    )


def place(buffer: np.ndarray, sound: np.ndarray, at: float,
          gain: float = 1.0) -> None:
    start = int(round(at * RATE))
    end = min(len(buffer), start + len(sound))
    buffer[start:end] += gain * sound[: end - start]


def place_circular(buffer: np.ndarray, sound: np.ndarray, at: float,
                   gain: float = 1.0) -> None:
    """Like [place], but a tail past the end wraps to the start (loops)."""
    start = int(round(at * RATE))
    index = (start + np.arange(len(sound))) % len(buffer)
    np.add.at(buffer, index, gain * sound)


def lowpass(x: np.ndarray, cutoff: float, order: int = 2) -> np.ndarray:
    sos = signal.butter(order, cutoff, 'low', fs=RATE, output='sos')
    return signal.sosfilt(sos, x)


def bandpass(x: np.ndarray, low: float, high: float,
             order: int = 2) -> np.ndarray:
    sos = signal.butter(order, [low, high], 'band', fs=RATE, output='sos')
    return signal.sosfilt(sos, x)


def room(x: np.ndarray, seconds: float = 0.35, mix: float = 0.12,
         seed: int = 7, circular: bool = False) -> np.ndarray:
    """A small, soft room: decaying filtered noise as the impulse response."""
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    ir = rng.standard_normal(n) * np.exp(-np.arange(n) / RATE / (seconds / 5))
    ir = lowpass(ir, 3500)
    ir /= np.sqrt(np.sum(ir ** 2))
    if circular:
        wet = np.real(np.fft.ifft(np.fft.fft(x) * np.fft.fft(ir, len(x))))
    else:
        wet = signal.fftconvolve(x, ir)[: len(x)]
    return x + mix * wet


def fade(x: np.ndarray, fade_in: float = 0.002,
         fade_out: float = 0.03) -> np.ndarray:
    y = x.copy()
    a = int(fade_in * RATE)
    b = int(fade_out * RATE)
    if a:
        y[:a] *= np.linspace(0, 1, a)
    if b:
        y[-b:] *= np.linspace(1, 0, b)
    return y


def normalize(x: np.ndarray, peak: float) -> np.ndarray:
    return x * (peak / np.max(np.abs(x)))


def trim_tail(x: np.ndarray, threshold: float = 0.0015) -> np.ndarray:
    """Cuts the inaudible end (keeps 20 ms after the last audible sample)."""
    loud = np.nonzero(np.abs(x) > threshold * np.max(np.abs(x)))[0]
    end = min(len(x), loud[-1] + int(0.02 * RATE)) if len(loud) else len(x)
    return x[:end]


# --- the sounds -------------------------------------------------------------


def message_received() -> np.ndarray:
    """A soft two-note chime, rising a fourth (E5 then A5)."""
    out = silence(0.9)
    place(out, bell(hz('E5'), 0.8, decay=0.3), 0.0, 0.85)
    place(out, bell(hz('A5'), 0.79, decay=0.33), 0.11, 1.0)
    out = lowpass(out, 6000)
    out = room(out, mix=0.10, seed=11)
    return normalize(fade(trim_tail(out, 0.004), fade_out=0.08), 0.80)


def message_sent() -> np.ndarray:
    """A very small, quick 'bloop' with a breath of air (in-app only)."""
    t = times(0.14)
    freq = 520 + 380 * (1 - np.exp(-t / 0.025))
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    tone = np.sin(phase) * envelope(len(t), 0.004, 0.035)
    rng = np.random.default_rng(3)
    air = bandpass(rng.standard_normal(len(t)), 1800, 5200)
    air *= envelope(len(t), 0.01, 0.025) * 0.18
    out = lowpass(tone + air, 5000)
    return normalize(fade(out, fade_out=0.02), 0.32)


def social() -> np.ndarray:
    """One soft, round marimba-like tone (G5): quieter than a message."""
    out = silence(0.8)
    place(out, marimba(hz('G5'), 0.8, decay=0.28), 0.0)
    out = lowpass(out, 5000)
    out = room(out, mix=0.12, seed=5)
    return normalize(fade(trim_tail(out)), 0.60)


def knock_once(seed: int) -> np.ndarray:
    """One knuckle on a wooden door: a body thump, a woody ring, a tap."""
    t = times(0.16)
    body_freq = 150 + 60 * np.exp(-t / 0.012)
    body = np.sin(2 * np.pi * np.cumsum(body_freq) / RATE)
    body *= envelope(len(t), 0.001, 0.035)
    wood = (np.sin(2 * np.pi * 410 * t) * 0.5 +
            np.sin(2 * np.pi * 690 * t) * 0.25) * envelope(len(t), 0.001,
                                                            0.022)
    rng = np.random.default_rng(seed)
    tap = bandpass(rng.standard_normal(len(t)), 700, 2600)
    tap *= envelope(len(t), 0.0005, 0.006) * 0.9
    return fade(lowpass(body * 1.0 + wood * 0.7 + tap, 3800), 0.0, 0.04)


def knock() -> np.ndarray:
    """Two soft knocks at the door."""
    out = silence(0.65)
    place(out, knock_once(21), 0.0, 1.0)
    place(out, knock_once(22), 0.19, 0.85)
    out = room(out, seconds=0.25, mix=0.18, seed=9)
    return normalize(fade(trim_tail(out)), 0.85)


def ringtone() -> np.ndarray:
    """A gentle, seamless looping kalimba melody (C major pentatonic)."""
    beat = 0.19
    melody = [
        ('E5', 0), ('G5', 1), ('A5', 2), ('C6', 3),
        ('A5', 4.5), ('G5', 5.5),
        ('E5', 8), ('G5', 9), ('A5', 10), ('D6', 11),
        ('C6', 12.5), ('A5', 13.5),
    ]
    loop_beats = 16
    out = np.zeros(int(round(loop_beats * beat * RATE)))
    for name, at in melody:
        gain = 1.0 if at in (0, 8) else 0.82
        place_circular(out, kalimba(hz(name), 1.2, decay=0.4), at * beat, gain)
    # A soft low fifth under each phrase gives it warmth.
    for root, at in (('C4', 0), ('G3', 8)):
        place_circular(out, bell(hz(root), 1.5, decay=0.5), at * beat, 0.3)
    # Filtered over two copies, so the end flows into the start (no click).
    out = lowpass(np.tile(out, 2), 5500)[len(out):]
    out = room(out, mix=0.14, seed=13, circular=True)
    return normalize(out, 0.85)


def alarm() -> np.ndarray:
    """Loud, urgent and unlike anything else in Zen: three rising whoops,
    then a fast high-low warble. Loops seamlessly."""

    def square(freq: np.ndarray) -> np.ndarray:
        phase = 2 * np.pi * np.cumsum(freq) / RATE
        out = np.zeros_like(freq)
        for k in (1, 3, 5, 7, 9):
            amp = 1.0 / k
            # Band-limited: an overtone over 9 kHz is dropped sample-wise.
            out += amp * np.sin(k * phase) * (k * freq < 9000)
        return out

    parts = []
    for _ in range(3):
        t = times(0.24)
        sweep = 650 * (1500 / 650) ** (t / t[-1])
        whoop = square(sweep) * envelope(len(t), 0.004, 10.0)
        parts.append(fade(whoop, 0.004, 0.012))
        parts.append(silence(0.035))
    for _ in range(3):
        for f in (1480.0, 1100.0):
            t = times(0.11)
            tone = square(np.full(len(t), f))
            parts.append(fade(tone, 0.003, 0.008))
        parts.append(silence(0.02))
    parts.append(silence(0.06))
    out = np.concatenate(parts)
    out = lowpass(out, 7000)
    # Soft saturation: louder without harsh clipping.
    out = np.tanh(2.2 * out / np.max(np.abs(out)))
    return normalize(out, 0.98)


def call_connected() -> np.ndarray:
    """Two quick, quiet rising notes: the call is on."""
    out = silence(0.5)
    place(out, marimba(hz('C5'), 0.4, decay=0.12), 0.0, 0.8)
    place(out, marimba(hz('G5'), 0.45, decay=0.16), 0.09, 1.0)
    out = room(lowpass(out, 5000), mix=0.10, seed=17)
    return normalize(fade(trim_tail(out)), 0.38)


def call_ended() -> np.ndarray:
    """The same two notes falling: the call is over."""
    out = silence(0.55)
    place(out, marimba(hz('G4'), 0.4, decay=0.12), 0.0, 1.0)
    place(out, marimba(hz('C4'), 0.5, decay=0.18), 0.11, 0.9)
    out = room(lowpass(out, 4500), mix=0.10, seed=19)
    return normalize(fade(trim_tail(out)), 0.38)


SOUNDS = {
    'zen_message': message_received,
    'zen_sent': message_sent,
    'zen_social': social,
    'zen_knock': knock,
    'zen_ringtone': ringtone,
    'zen_alarm': alarm,
    'zen_call_connected': call_connected,
    'zen_call_ended': call_ended,
}


# --- writing ----------------------------------------------------------------


def write_wav(path: str, samples: np.ndarray) -> None:
    pcm = np.clip(np.round(samples * 32767), -32768, 32767).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


def ffmpeg(*args: str) -> None:
    subprocess.run(
        # Bit-exact output (no random stream serials, no encoder tag), so
        # every run writes the same files.
        ['ffmpeg', '-nostdin', '-loglevel', 'error', '-y', *args[:-1],
         '-fflags', '+bitexact', '-flags:a', '+bitexact', args[-1]],
        check=True,
    )


def main() -> int:
    assets = os.path.join(ROOT, 'assets', 'sounds')
    raw = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res', 'raw')
    apple = [
        os.path.join(ROOT, 'ios', 'Runner', 'Sounds'),
        os.path.join(ROOT, 'macos', 'Runner', 'Sounds'),
    ]
    for d in (assets, raw, *apple):
        os.makedirs(d, exist_ok=True)
    have_ffmpeg = shutil.which('ffmpeg') is not None
    if not have_ffmpeg:
        print('ffmpeg not found: only the .wav assets are written.')
    with tempfile.TemporaryDirectory() as tmp:
        for name, build in SOUNDS.items():
            samples = build()
            wav = os.path.join(assets, name + '.wav')
            write_wav(wav, samples)
            print(f'{name}: {len(samples) / RATE:.2f} s, '
                  f'{os.path.getsize(wav) // 1024} KB wav')
            if not have_ffmpeg or name not in NOTIFICATION_SOUNDS:
                continue
            ffmpeg('-i', wav, '-c:a', 'libvorbis', '-q:a', '3',
                   '-map_metadata', '-1', os.path.join(raw, name + '.ogg'))
            caf = os.path.join(tmp, name + '.caf')
            ffmpeg('-i', wav, '-c:a', 'adpcm_ima_qt', '-map_metadata', '-1',
                   caf)
            for d in apple:
                shutil.copyfile(caf, os.path.join(d, name + '.caf'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
