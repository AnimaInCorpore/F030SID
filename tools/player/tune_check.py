#!/usr/bin/env python3
"""Real tunes: the reference 6510 core against libsidplayfp.

  tune_check.py <psidref> <sidtrace> [--seconds S] tunes.sid ...

Both play each tune for S seconds; the SID writes (register, value) must be the
same sequence. libsidplayfp's driver writes the volume before init runs, so the
streams are aligned on the tune's first eight writes. The cycle stamps are not
compared write by write (libsidplayfp's machine has bad lines and its driver's
interrupt); the difference in elapsed cycles over the common writes is printed,
and stays below a frame when the call schedule agrees. A tune that needs what
the player does not have (RSID, interrupts: tools/player/README.md) differs
within the first writes. `make tune-check` runs it on music/*.sid.
"""
import argparse
import os
import struct
import subprocess
import sys

CLOCK = 985248


def writes(path):
    out = []
    for line in open(path, encoding="latin-1"):
        f = line.split()
        if f and f[0][0] not in "#e" and int(f[1], 0) < 25:
            out.append((int(f[0], 0), int(f[1], 0), int(f[2], 0)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("psidref")
    ap.add_argument("sidtrace")
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--out", default="build/music")
    ap.add_argument("tunes", nargs="+")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    ok = True
    for tune in args.tunes:
        name = os.path.splitext(os.path.basename(tune))[0]
        head = open(tune, "rb").read(0x7c)
        magic, version = head[:4].decode("latin-1"), struct.unpack(">H", head[4:6])[0]
        play = struct.unpack(">H", head[12:14])[0]
        flags = struct.unpack(">H", head[0x76:0x78])[0] if version >= 2 else 0
        what = f"{magic} play ${play:04x} {'8580' if (flags >> 4) & 3 == 2 else '6581'}"
        real_path = os.path.join(args.out, name + ".lsfp.trace")
        ref_path = os.path.join(args.out, name + ".ref.trace")
        subprocess.run([args.sidtrace, "-t", str(args.seconds), "-o", real_path, tune], capture_output=True, check=True)
        subprocess.run([args.psidref, "-t", str(args.seconds), tune, ref_path], capture_output=True, check=True)
        real, ref = writes(real_path), writes(ref_path)
        va, vb = [w[1:] for w in real], [w[1:] for w in ref]
        first = next((i for i in range(min(len(va), 400)) if vb and va[i:i + 8] == vb[:8]), None)
        if first is None:
            print(f"{name:<24}{what:<22}FAIL: the tune's first writes are not in libsidplayfp's stream")
            ok = False
            continue
        real, va = real[first:], va[first:]
        n = min(len(va), len(vb))
        k = next((i for i in range(n) if va[i] != vb[i]), n)
        if k < n:
            print(f"{name:<24}{what:<22}FAIL: {k} writes equal, then at {ref[k][0] / CLOCK:.2f} s "
                  f"libsidplayfp {va[k]}, reference {vb[k]}")
            ok = False
            continue
        drift = (real[n - 1][0] - real[0][0]) - (ref[n - 1][0] - ref[0][0])
        print(f"{name:<24}{what:<22}{n} writes equal ({ref[n - 1][0] / CLOCK:.1f} s); elapsed cycles differ by {drift}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
