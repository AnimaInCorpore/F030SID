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

## Real tunes: `pick_songs.py`

The unpacked HVSC (`music/`, git-ignored; tunes are not bundled here) is
far too large to trace whole, so a test set is picked from it: famous and
demanding.

```sh
python3 tools/trace/pick_songs.py scan --hvsc music --sidtrace build/lsfp/sidtrace   # use sidtrace.exe on Windows
python3 tools/trace/pick_songs.py select --count 40 --famous 15 > tests/songs.txt
```

`scan` traces 20 s (after skipping 5 s) of every tune of 22 composers who
account for much of the C64's famous and technically demanding music (1,212
tunes) and extracts, from the register writes alone, what is hard on the
emulation: a moving filter cutoff, `$D418` written at sample rate (digi
playback), hard sync, ring modulation, combined waveforms and noise
combinations, the test bit, pulse-width modulation, the write rate. HVSC does
not record popularity, so fame is a curated list of titles; `select` takes the
most demanding of the famous ones first (`--famous`), then the most demanding
overall, with at most five per composer. `tests/songs.txt` records that selection: 40
tunes, 18 of them famous, with the reasons. It lists paths into HVSC only;
traces are written under `build/songs/` (ignored). No tune in this selection
is multi-SID: the scanned composers' multi-SID tunes were not among the
candidates, so 2SID/3SID needs a separate pick.

The trace tool's full C64 scheduling is broader than the Falcon player's
fixed-call environment. Successful RSID or multi-SID tracing does not imply
F030SID playback support. For the current supported-tune comparison window
and its limitations, see [the load check](../../docs/performance.md#two-minute-load-check).

This selection ranks workloads; it is not a list of tunes verified to play
correctly or in real time on F030SID.
