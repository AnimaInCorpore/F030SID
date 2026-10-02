#!/usr/bin/env python3
"""Check sidtrace's output for the hand-assembled test tunes.

  check_traces.py <lsfp build dir> <ref build dir>

The tunes (tools/trace/make_test_sid.py) have a known write pattern: nine
init writes, then two writes (freq hi counting up from $11, pw hi counting
up from 1) per 50 Hz play call, about 19,656 cycles apart. The 2SID tune also
writes three registers to its second chip at init. The traces must then run
through the reSID oracle and the reference model identically.
"""

import os
import subprocess
import sys


def parse(path):
    w, end = [], None
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("end"):
            end = int(line.split()[1])
            continue
        c, r, v = (int(x) for x in line.split())
        w.append((c, r, v))
    return w, end


def exe(d, name):
    return os.path.join(d, name + (".exe" if os.name == "nt" else ""))


def check(cond, msg):
    if not cond:
        sys.exit(f"FAIL: {msg}")
    print(f"ok: {msg}")


def check_chip1(path):
    w, end = parse(path)
    # init's last write is pulse + gate; everything after it is the play routine
    regs = [(r, v) for _, r, v in w]
    check((5, 0) in regs and (6, 0xF0) in regs and (1, 0x1C) in regs and (3, 8) in regs,
          "init wrote AD, SR, freq hi and pw hi")
    start = regs.index((4, 0x41)) + 1
    plays = w[start:]
    check(len(plays) % 2 == 0 and len(plays) >= 40, f"{len(plays)} play writes")
    freq = [v for _, r, v in plays if r == 1]
    pw = [v for _, r, v in plays if r == 3]
    check(freq[:5] == [0x11, 0x12, 0x13, 0x14, 0x15], f"freq hi counts up {freq[:5]}")
    check(pw[:5] == [1, 2, 3, 4, 5], f"pw hi counts up {pw[:5]}")
    gaps = [plays[i][0] - plays[i - 2][0] for i in range(2, len(plays), 2)]
    check(all(19640 <= g <= 19670 for g in gaps),
          f"play interval {min(gaps)}..{max(gaps)} cycles (50 Hz PAL frame = 19656)")
    check(end is not None and end >= plays[-1][0], "end marker after the last write")


def main():
    lsfp, ref = sys.argv[1], sys.argv[2]
    check_chip1(os.path.join(lsfp, "test_pulse.trace"))
    check_chip1(os.path.join(lsfp, "test_2sid.trace"))
    w2, _ = parse(os.path.join(lsfp, "test_2sid.2.trace"))
    check([(r, v) for _, r, v in w2] == [(24, 15), (1, 10), (4, 33)],
          "second SID received its three init writes: " + str([(r, v) for _, r, v in w2]))
    out = os.path.join(ref, "out")
    os.makedirs(out, exist_ok=True)
    resid = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "third_party", "resid")
    for name in ("test_pulse", "test_2sid"):
        tr = os.path.join(lsfp, name + ".trace")
        for model in ("6581", "8580"):
            a, b = os.path.join(out, f"{name}.{model}.ref.tsv"), os.path.join(out, f"{name}.{model}.ora.tsv")
            subprocess.run([exe(ref, "ref_run"), model, tr, resid, a, os.path.join(out, "x.bl")], check=True)
            subprocess.run([exe(ref, "oracle_resid"), "frames", model, tr, b], check=True)
            check(open(a).read() == open(b).read(), f"{name} {model}: reference == reSID on the traced writes")
    print("PASS")


if __name__ == "__main__":
    main()
