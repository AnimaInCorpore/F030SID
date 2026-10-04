#!/usr/bin/env python3
"""Gate the 68030 filter coefficient routine against the C one.

src/m68k/coeftest.s computes the eight coefficient words for every
third fc and every res on both chip models under Hatari; they must equal what
sid_filter_coeffs() in src/ref/sid_ref.c gives (printed by `coefref`).

  coef_gate.py --vasm V --vlink L --hatari H --tos ROM --coefref C
"""
import argparse
import os
import struct
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=os.path.join(ROOT, "build"))
    ap.add_argument("--coefref", default=os.path.join(ROOT, "build", "ref", "coefref"))
    ap.add_argument("--vasm", required=True)
    ap.add_argument("--vlink", required=True)
    ap.add_argument("--hatari", required=True)
    ap.add_argument("--tos", required=True)
    args = ap.parse_args()
    for k in ("build", "coefref", "vasm", "vlink", "hatari", "tos"):
        setattr(args, k, os.path.abspath(getattr(args, k)))
    gate = os.path.join(args.build, "coef")
    os.makedirs(gate, exist_ok=True)
    want = [int(x) for x in subprocess.run([args.coefref, "3"], check=True, capture_output=True, text=True).stdout.split()]
    obj = os.path.join(gate, "coeftest.o")
    subprocess.run([args.vasm, os.path.join(ROOT, "src", "m68k", "coeftest.s"), "-quiet", "-Felf", "-m68030",
                    "-I" + os.path.join(ROOT, "src", "m68k"), "-I" + os.path.join(args.build, "generated"), "-o", obj], check=True)
    subprocess.run([args.vlink, obj, "-b", "ataritos", "-s", "-e", "start", "-o", os.path.join(gate, "coeftest.tos")], check=True)
    out = os.path.join(gate, "COEFOUT.BIN")
    if os.path.exists(out):
        os.remove(out)
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    with open(os.path.join(gate, "hatari.out"), "w") as f:
        subprocess.run([args.hatari, "--machine", "falcon", "--dsp", "none", "--memsize", "14", "--tos", args.tos,
                        "--patch-tos", "true", "--fast-boot", "true", "--fast-forward", "true", "--sound", "off",
                        "--confirm-quit", "false", "--run-vbls", "1500", "--conout", "2", "coeftest.tos"],
                       cwd=gate, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=600)
    if not os.path.exists(out):
        sys.exit("FAIL: no output")
    raw = open(out, "rb").read()
    got = list(struct.unpack(f">{len(raw) // 4}I", raw))
    if got != want:
        k = next((i for i, (g, w) in enumerate(zip(got, want)) if g != w), min(len(got), len(want)))
        sys.exit(f"FAIL: {len(got)} words, expected {len(want)}; first difference at word {k} "
                 f"(model {k // (683 * 128)}, fc {(k // 128) % 683 * 3}, res {k // 8 % 16}, word {k % 8}): "
                 f"68030 {got[k] if k < len(got) else None}, C {want[k] if k < len(want) else None}")
    print(f"{len(got) // 8} coefficient sets identical\n\nPASS")


if __name__ == "__main__":
    main()
