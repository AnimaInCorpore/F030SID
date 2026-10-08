#!/usr/bin/env python3
"""Measure DSP56001 cycles between two labels with Hatari's DSP profiler.

  profile_dsp.py prepare --listing X.LST --output-dir DIR --start LABEL --end LABEL [--hit N]
      writes Hatari debugger scripts: a DSP breakpoint at LABEL `start` that
      switches the DSP profiler on and a second one at `end` that saves the
      profile and switches it off. Run Hatari with `--parse DIR/start.ini`.
      --hit N profiles the N-th pass through `start` (a frame in the middle of a run).

  profile_dsp.py report --listing X.LST --profile DIR/profile.txt [--frames N --rate HZ]
      summarises the saved profile per label: instruction cycles (Hatari
      counts oscillator clocks, two per instruction cycle), instructions, and
      with --frames/--rate the cost per output frame against the real-time
      budget (oscillator / 2 / rate).

The listing is Motorola's .LST (`SID.LST` etc.). The cycle model is Hatari's:
zero wait states on external memory, two extra cycles for an instruction that
touches two external spaces. Use the DSP-calibrated build (docs/performance.md)
for anything involving real time; the cycle counts themselves do not depend on
the calibration.
"""

from __future__ import annotations

import argparse
import bisect
import re
from collections import defaultdict
from pathlib import Path

LABEL_RE = re.compile(r"^\s*\d+\s+(?:[PXY]:[0-9A-F]+\s+)?\s*([A-Za-z_][A-Za-z0-9_]*):\s*(?:;.*)?$")
ADDRESS_RE = re.compile(r"^\s*\d+\s+([PXYL]):([0-9A-F]+)\b")
# a label with its instruction on the same line
INLINE_RE = re.compile(r"^\s*\d+\s+P:([0-9A-F]+)\s+[0-9A-F]{6}(?:\s[0-9A-F]{6})?\s+([A-Za-z_][A-Za-z0-9_]*):")
# Hatari prints the percentage through the host locale ("0,01%" on a German
# Windows host); the counts beside it are plain integers.
PROFILE_RE = re.compile(r"^p:([0-9a-f]+).*?\s([0-9]+[.,][0-9]+)% \((\d+), (\d+), (\d+)\)$")


def parse_listing(path: Path) -> dict[tuple[str, str], int]:
    """Label -> address, from the line that follows each label."""
    symbols: dict[tuple[str, str], int] = {}
    pending: list[str] = []
    for line in path.read_text(errors="replace").splitlines():
        label = LABEL_RE.match(line)
        if label:
            pending.append(label.group(1))
            continue
        inline = INLINE_RE.match(line)
        if inline:
            symbols[("P", inline.group(2))] = int(inline.group(1), 16)
        address = ADDRESS_RE.match(line)
        if not address or not pending:
            continue
        space = address.group(1).upper()
        value = int(address.group(2), 16)
        for name in pending:
            for resolved in (("X", "Y") if space == "L" else (space,)):
                symbols[(resolved, name)] = value
        pending.clear()
    return symbols


def symbol(symbols, space: str, name: str) -> int:
    if (space, name) not in symbols:
        raise SystemExit(f"error: {space}:{name} is not in the DSP listing")
    return symbols[(space, name)]


def prepare(listing: Path, out: Path, start: str, end: str, hit: int = 1) -> None:
    sym = parse_listing(listing)
    a, b = symbol(sym, "P", start), symbol(sym, "P", end)
    out.mkdir(parents=True, exist_ok=True)
    begin = (out / "begin.ini").resolve()
    finish = (out / "end.ini").resolve()
    profile = (out / "profile.txt").resolve()
    count = f" :{hit}" if hit > 1 else ""
    (out / "start.ini").write_text(f"db pc = ${a:04x}{count} :once :trace :file {begin}\n")
    begin.write_text(f"dp on\ndb pc = ${b:04x} :once :trace :file {finish}\n")
    finish.write_text(f"dp save {profile}\ndp off\n")


def parse_profile(path: Path):
    cps = 0
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("Cycles/second:"):
            cps = int(line.split(":", 1)[1])
            continue
        m = PROFILE_RE.match(line)
        if m:
            rows.append((int(m.group(1), 16), int(m.group(3)), int(m.group(4))))
    if not cps or not rows:
        raise SystemExit(f"error: {path} is not a complete Hatari DSP profile")
    return cps, rows


def report(listing: Path, profile: Path, output: Path | None, frames: int, rate: float) -> None:
    sym = parse_listing(listing)
    labels = sorted((addr, name) for (space, name), addr in sym.items() if space == "P")
    addrs = [a for a, _ in labels]
    cps, rows = parse_profile(profile)
    osc = sum(r[2] for r in rows)
    instr = sum(r[1] for r in rows)
    blocks: defaultdict[str, list[int]] = defaultdict(lambda: [0, 0])
    for pc, n, cyc in rows:
        i = bisect.bisect_right(addrs, pc) - 1
        name = labels[i][1] if i >= 0 else f"p_${pc:04x}"
        blocks[name][0] += n
        blocks[name][1] += cyc
    lines = [
        f"  Hatari DSP oscillator:       {cps:,} Hz",
        f"  executed instructions:       {instr:,}",
        f"  oscillator cycles:           {osc:,}",
        f"  instruction cycles:          {osc / 2:,.1f}",
    ]
    if frames:
        per = osc / 2 / frames
        budget = cps / 2 / rate
        lines += [
            f"  frames:                      {frames}",
            f"  instruction cycles/frame:    {per:,.2f}",
            f"  budget/frame at {rate:,.0f} Hz:  {budget:,.2f}  ({per * 100 / budget:.1f}% used)",
        ]
    lines += ["", "By label (instruction cycles = oscillator / 2):"]
    for name, (n, cyc) in sorted(blocks.items(), key=lambda kv: kv[1][1], reverse=True)[:16]:
        lines.append(f"  {cyc / 2:9,.1f} cycles  {n:7,d} instructions  {cyc * 100.0 / osc:5.1f}%  {name}")
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--listing", type=Path, required=True)
    p.add_argument("--output-dir", type=Path, required=True)
    p.add_argument("--start", required=True)
    p.add_argument("--end", required=True)
    p.add_argument("--hit", type=int, default=1, help="profile the N-th pass through --start")
    r = sub.add_parser("report")
    r.add_argument("--listing", type=Path, required=True)
    r.add_argument("--profile", type=Path, required=True)
    r.add_argument("--output", type=Path)
    r.add_argument("--frames", type=int, default=0)
    r.add_argument("--rate", type=float, default=25175000 / 512)
    a = ap.parse_args()
    if a.cmd == "prepare":
        prepare(a.listing, a.output_dir, a.start, a.end, a.hit)
    else:
        report(a.listing, a.profile, a.output, a.frames, a.rate)


if __name__ == "__main__":
    main()
