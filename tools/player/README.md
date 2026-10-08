# Player tools

The player (`src/m68k/player.s`, `release/f030sid.ttp`) runs a PSID's 6510 code
on the 68030 and sends the SID register writes, stamped with their cycle, to
the DSP kernel's stream. Everything here is its specification and its gates.

| File | What it is |
| --- | --- |
| `gen_6502.py` | the 6510 opcode table, once: a C table for the reference core and one generated 68030 handler per opcode (`cpu6502_ops.i`) |
| `psidref.c` | the reference: 6510 core and PSID driver in C; writes a register trace (the format of `tools/trace`) |
| `make_exerciser.py` | opcode exerciser PSIDs: random instructions over every opcode and addressing mode, the processor state dumped to the SID after every block |
| `check_portable.py` | the reference core against libsidplayfp's 6510 (`make cpu-ref-check`) |
| `cpu_gate.py` | the 68030 core against the reference: same writes, same cycles (`make cpu-gate`) |
| `gen_player_tables.c` | the tables the player carries per chip model (DSP tables in the kernel's scaling, filter tables) |
| `coefref.c`, `coef_gate.py` | the 68030 filter coefficient routine against `sid_filter_coeffs()` (`make coef-gate`) |
| `make_trace_sid.py` | a PSID that replays a register trace at 50 Hz (music with a filter sweep for the player gate, without a copyrighted tune) |
| `play_gate.py` | the player end to end under Hatari (`make play-gate`) |

## The rules both cores follow

- 64 KB of RAM and no ROMs; `$01` is plain RAM. A tune that calls the KERNAL or
  BASIC, or relies on banking, does not work.
- Writes to `$D400-$D7FF` are SID writes (register = address & `$1f`); SID reads
  return 0, so tunes that read OSC3/ENV3 (`$D41B/$D41C`) get zeros.
  `$D012`/`$D011` read a raster derived from the cycle count. The rest of
  `$D000-$DFFF` is RAM: there is no CIA or VIC, and no interrupts.
- All documented opcodes, decimal mode as the NMOS chip does it, and the stable
  undocumented ones (SLO RLA SRE RRA SAX LAX DCP ISB ANC ALR ARR SBX, the NOPs,
  SBC `$EB`). The unstable ones (ANE LXA SHA SHX SHY TAS LAS) are no-operations
  of the right length; ARR ignores decimal mode. KIL and BRK end the call.
- A call (init or play) runs until RTS or RTI with the stack empty, BRK/KIL, or
  a cycle limit. init is called with A = song - 1 at cycle 0; play once per
  period: a PAL frame (19656 cycles) or, with the tune's speed bit set, the CIA
  timer latch the tune left in `$DC04/$DC05` (+1; 16421 if none). A play
  address of 0 means the vector the init routine left in `$0314`, else `$FFFE`.
- So: PSID tunes with a play routine called at a fixed rate. RSID tunes, digi
  playback from NMI or raster interrupts, multi-speed through CIA interrupts
  the tune programs itself, NTSC timing and a second SID are not supported yet.

## What the gates establish

1. `cpu-ref-check`: on six portable exercisers (about 7,000 state dumps) the C
   reference and libsidplayfp's 6510 write the same values with the same cycle
   spacing (libsidplayfp's machine adds bad lines and its driver's interrupt).
2. `cpu-gate`: the 68030 core logs exactly the reference's writes and cycles on
   the test tunes and twelve exercisers (unstable opcodes, ARR and I/O reads
   included).
3. `coef-gate`: 21,856 coefficient sets (every third fc, every res, both
   models) equal the C routine's.
4. `play-gate`: `F030SID.TTP` plays each tune for some seconds under the
   DSP-calibrated Hatari; the DSP's checksum over every rendered frame equals
   the chip reference's (band-limited) rendering of the reference trace, the transmitter never
   overtakes the renderer, and elapsed time stays within the gate tolerance.
   A checksum match alone does not pass timing.

## Real-tune checks

`tune_check.py` compares the reference core's register/value sequence with
libsidplayfp over their aligned common prefix. It does not establish exact
per-write timing. `make tune-check` uses local `music/*.sid`; `make tune-gate`
plays them for 30 seconds with their header-selected model. Gate arguments
can select longer windows, separate build directories and parallel instances.

`fetch_heavy_corpus.py` downloads/verifies the SHA-256-pinned workload in
`tests/heavy-corpus.json` under ignored `music/`. It includes unsupported
RSID and multi-SID examples; exclude those from claims about supported playback.
The [latest two-minute check](../../docs/heavy-load-check.md) records the
seventeen supported inputs, checksum matches, pacing failures and Monofail's
overtakes. `make_exerciser.py`, `make_trace_sid.py` and `make_demo_trace.py`
produce synthetic tunes for reproducible gates without a downloaded corpus.

The player normally exits through GEMDOS Pterm ($4c); the gate quits there
rather than idling after completion. `--plain` uses `-v -p` to record status
without the checksum overhead.
