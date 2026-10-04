#!/usr/bin/env python3
"""The C reference core against libsidplayfp's 6510 on the portable exercisers.

  check_portable.py <psidref> <sidtrace> portable_*.sid

Both run the tune's init routine; the SID writes (register, value) and the
cycles between consecutive writes must be the same, except that libsidplayfp's
machine stops the processor now and then (VIC bad lines, about 42 cycles, and
the driver's interrupt, 96): some gaps are longer there, none shorter. Absolute cycles differ: libsidplayfp runs its PSID driver first.
"""
import os
import subprocess
import sys


def trace(cmd, path):
    subprocess.run(cmd, check=True, capture_output=True)
    return [tuple(int(x) for x in line.split()) for line in open(path)
            if line.strip() and line[0] not in "#e"]


def main():
    psidref, sidtrace = sys.argv[1:3]
    ok = True
    for tune in sys.argv[3:]:
        base = os.path.splitext(tune)[0]
        ref = trace([psidref, "-t", "2", tune, base + ".ref.trace"], base + ".ref.trace")
        real = trace([sidtrace, "-t", "2", "-o", base + ".lsfp.trace", tune], base + ".lsfp.trace")
        # libsidplayfp's driver writes the volume before init runs: align on the tune's first write
        first = next(i for i, w in enumerate(real) if w[1:] == ref[0][1:] and
                     [x[1:] for x in real[i:i + 8]] == [x[1:] for x in ref[:8]])
        real = real[first:]
        # Values must be equal. The cycles between consecutive writes too, except where
        # libsidplayfp's machine interrupts the routine (its raster/CIA interrupts run
        # during init): there its gap is longer, never shorter.
        va, vb = [w[1:] for w in ref], [w[1:] for w in real]
        da = [y[0] - x[0] for x, y in zip(ref, ref[1:])]
        db = [y[0] - x[0] for x, y in zip(real, real[1:])]
        name = os.path.basename(tune)
        if va != vb:
            k = next((i for i, (x, y) in enumerate(zip(va, vb)) if x != y), min(len(va), len(vb)))
            print(f"{name}: FAIL: write {k} of {len(va)}/{len(vb)}: reference {ref[k] if k < len(ref) else None}, "
                  f"libsidplayfp {real[k] if k < len(real) else None}")
            ok = False
            continue
        longer = sum(1 for x, y in zip(da, db) if y > x)
        if any(y < x for x, y in zip(da, db)) or longer > len(da) // 10:
            k = next(i for i, (x, y) in enumerate(zip(da, db)) if y != x)
            print(f"{name}: FAIL: cycle spacing differs at write {k + 1} ({da[k]} against {db[k]}; {longer} longer gaps)")
            ok = False
            continue
        extra = sorted({y - x for x, y in zip(da, db) if y != x})
        print(f"{name}: {len(va)} writes identical; cycle spacing identical"
              + (f" but for {longer} gaps longer in libsidplayfp's machine (by {extra} cycles)" if longer else ""))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
