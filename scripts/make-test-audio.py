#!/usr/bin/env python3 -I
"""Builds synthetic replay fixtures for the recorder's --replay mode.

    scripts/make-test-audio.py OUTDIR

Writes OUTDIR/system.wav (two far-end voices taking turns) and OUTDIR/mic.wav
(a local voice in the gaps, plus a delayed, attenuated loudspeaker echo of the
far end), 16 kHz mono 16-bit, and OUTDIR/script.txt with the spoken lines.

Synthetic speech is for smoke tests only: it misleads diarization and
vocabulary conclusions in both directions. Use real recordings to judge
accuracy.
"""
import os
import random
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 16000
# (track, voice, line). Voices: check `say -v ?`. Samantha survives Siri being on.
SCRIPT = [
    ("system", "Samantha", "Good morning everyone. Today we need to decide whether to move the billing service to the new cluster."),
    ("system", "Daniel", "I looked at the numbers yesterday. The new cluster is cheaper, but the migration needs two weeks of testing."),
    ("mic", "Karen", "Two weeks is fine if we start on Monday. I can write the rollback plan."),
    ("system", "Samantha", "Great. Who will talk to the finance team about the invoices?"),
    ("mic", "Karen", "Yeah."),
    ("system", "Daniel", "I can do that. I will send them the schedule this afternoon."),
    ("mic", "Karen", "Perfect. Then we review everything again on Friday before the cutover."),
    ("system", "Samantha", "Agreed. Thanks everyone, see you on Friday."),
]


def synth(voice, text, path):
    aiff = path + ".aiff"
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", aiff, path], check=True)
    os.remove(aiff)
    with wave.open(path) as w:
        n = w.getnframes()
        samples = list(struct.unpack(f"<{n}h", w.readframes(n)))
    if len(samples) < RATE // 10:
        sys.exit(f"`say -v {voice}` produced an empty clip ({len(samples)} samples) — try another voice")
    return samples


def write(path, samples):
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(struct.pack(f"<{len(samples)}h", *[max(-32768, min(32767, int(s))) for s in samples]))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "fixtures"
    os.makedirs(out, exist_ok=True)
    random.seed(7)
    system, mic = [], []
    lines = []
    with tempfile.TemporaryDirectory() as tmp:
        t = int(0.5 * RATE)
        for i, (track, voice, text) in enumerate(SCRIPT):
            s = synth(voice, text, os.path.join(tmp, f"{i}.wav"))
            target = system if track == "system" else mic
            need = t + len(s)
            for buf in (system, mic):
                buf.extend([0] * (need - len(buf)))
            for k, v in enumerate(s):
                target[t + k] += v
            lines.append(f"[{t / RATE:6.2f}] {'Them' if track == 'system' else 'Me'} ({voice}): {text}")
            t = need + int(0.7 * RATE)
        total = t + RATE
        for buf in (system, mic):
            buf.extend([0] * (total - len(buf)))
    # Loudspeaker echo into the mic: 45 ms late, -9 dB, a little room smear,
    # plus faint room noise so the mic is never exact zeros.
    d = int(0.045 * RATE)
    echo = [0.0] * total
    for i in range(d, total):
        echo[i] = 0.35 * system[i - d] + (0.12 * system[i - d - 40] if i - d - 40 >= 0 else 0)
    mic = [mic[i] + echo[i] + random.gauss(0, 12) for i in range(total)]
    write(os.path.join(out, "system.wav"), system)
    write(os.path.join(out, "mic.wav"), mic)
    with open(os.path.join(out, "script.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{out}: {total / RATE:.1f}s, {len(SCRIPT)} lines")


if __name__ == "__main__":
    main()
