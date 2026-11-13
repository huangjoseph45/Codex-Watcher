"""Generate short, quiet notification cues using only the Python standard library."""
import math
from pathlib import Path
import struct
import wave

RATE = 44100
OUTPUT = Path(__file__).resolve().parents[1] / "Sources/SessionScout/Resources"


def bell(t, frequency, duration):
    if t < 0 or t >= duration:
        return 0.0
    attack = min(t / 0.012, 1.0)
    release = min((duration - t) / 0.045, 1.0)
    envelope = math.sin(attack * math.pi / 2) ** 2 * release ** 2 * math.exp(-t / 0.085)
    return envelope * (0.20 * math.sin(2 * math.pi * frequency * t)
                       + 0.025 * math.sin(2 * math.pi * frequency * 2 * t))


def save(name, duration, notes):
    samples = []
    for index in range(round(duration * RATE)):
        t = index / RATE
        sample = sum(bell(t - start, frequency, length) for start, frequency, length in notes)
        samples.append(struct.pack("<h", round(max(-1, min(1, sample)) * 32767)))
    with wave.open(str(OUTPUT / name), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(b"".join(samples))


save("action-required.wav", 0.24, [(0, 659.25, 0.24)])
save("turn-finished.wav", 0.36, [(0, 392.00, 0.24), (0.12, 523.25, 0.24)])
