# sidtrace

Runs a PSID/RSID tune in libsidplayfp and writes the SID register writes with
exact C64 cycle stamps, in the `.trace` format the voice reference model and
the reSID oracle read (`cycle reg value`, `end cycle`).

```sh
make trace            # fetches libsidplayfp 2.16.1 (sha256-pinned), builds sidtrace
build/lsfp/sidtrace -t 60 -o song.trace song.sid
build/lsfp/sidtrace -k 90 -t 30 -s 2 -m 8580 --pal -o chorus.trace song.sid
make trace-test       # traces two hand-assembled tunes and checks the result
```

| Option | Meaning |
| --- | --- |
| `-o FILE` | output; the second and third SID of a 2SID/3SID tune go to `FILE` with `.2` / `.3` before the extension |
| `-t SEC` | recorded window length (default 30) |
| `-k SEC` | skip this long first. The window opens with the register values at that moment replayed at cycle 0, so chip state is approximate: a gate bit left on is re-applied and restarts the envelope |
| `-s N` | song number |
| `-m 6581\|8580` | force the SID model |
| `--pal`, `--ntsc` | force the video standard (default: the tune's, else PAL). The reference model's frame clock is PAL; an NTSC trace needs a different cycle ratio |

How it works: `TraceFp` derives from libsidplayfp's own `ReSIDfp` emulation and
logs every `write()` with `EventScheduler::getTime(PHI1)` before passing it on,
so the 6510, CIA and VIC timing, the PSID driver and OSC3/ENV3 reads behave
exactly as in `sidplayfp`. The class is `final` upstream; the tool removes the
keyword with a macro in its own translation unit. It needs libsidplayfp's
*internal* headers, hence the source tarball rather than the installed package.
The power-on delay is fixed at 0 so traces are reproducible. Only registers
`$D400-$D418` are written out; chips are numbered in the order the player locks
them, which is SID order.

Limits: the traced writes carry what libsidplayfp does, including its CIA/VIC
modelling; no ROM images are loaded, so a tune that calls the KERNAL or BASIC
ROM sees libsidplayfp's stub behaviour. Real tunes are not in the repository
(`tests/psid/` holds two synthetic ones); point the tool at your own `.sid`
files. The tool links GPL code (libsidplayfp, reSID).

On Windows run `make` from an MSYS2 login shell (`bash -lc`); from a plain
Git-bash, libsidplayfp's `configure` fails with "invalid feature name".
