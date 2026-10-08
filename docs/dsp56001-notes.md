# DSP56001 implementation notes

These constraints apply to `src/dsp/sid.asm.in` and its embedded loader.
The architectural reference is the local [DSP56001 manual](DSP56001_um.pdf).
The current kernel and memory map are in [dsp-kernel.md](dsp-kernel.md).

## Arithmetic

Data words are signed 24-bit fractions; MPY/MAC align their products in the
56-bit accumulator. Integer state uses explicit shifts and scaling. Phase
and filter integrators use paired X/Y words with `L:` moves. The output's
`rnd` rounds exact ties to even; the C reference's `mix_output` follows that
rule. A matching voice gate alone does not verify final mixer rounding.

A test of an accumulator sees its fractional bits too. When testing an
integer result after multiplication, remove the fraction where the algorithm
requires it. Changes to arithmetic must pass the bit-exact DSP/reference gate.

## Address generation

An indirect access needs one independent instruction cycle after writing its
address register (manual section 8.1, pipeline Case 2). Use a useful instruction
or a NOP to satisfy this delay. Indexed and post-update addressing pair
same-numbered registers: `(Rn+Nn)` and `(Rn)+Nn` exist; `(R7+N5)` does not.
Address arithmetic uses the pointer's own modifier register, so helpers must
preserve the caller's modulo configuration.

There is no register-plus-immediate-offset address mode. The source generator
instantiates each voice with absolute state addresses and suffixed labels,
allowing short moves and jumps in the common frame path.

## Loops and interrupts

`DO` and `REP` with a zero count execute 65,536 iterations. Guard counts that
may be zero. Motorola ASM56000 checks instruction restrictions near hardware
loop endpoints (manual section 8.1.2 and instruction descriptions).

The SSI transmitter uses a two-word fast interrupt. It must leave condition
codes intact: toggling an offset with `bchg` changed carry and failed the
stream gate. The current interrupt reads alternating offsets 0 and 1 through
`r7`, sending each mono ring word twice without changing flags.

## External memory and loading

The Falcon mapping used by Hatari aliases external P with external Y;
external X occupies the other half of SRAM. Keep the kernel below P:$1c00,
where the combined-waveform Y tables begin. This map still needs validation
on a physical Falcon.

`Dsp_ExecBoot` accepts at most 512 bootstrap words. The embedded loader occupies
P:$0040–$007f while receiving the sparse kernel, which begins at P:$0080.
The stream uses magic `$4d584c`, then section count and address/count/data
records. It replies `$4c4f41` and jumps through the new reset vector.
`tools/generate_dsp_stage2.py` rejects invalid sections, bootstrap overflow,
loader overlap and kernel sections past the configured P:$1c00 limit.

The kernel clears BCR at startup to select zero external-memory wait states.
Sound-path configuration, bus timing and SSI continuity remain hardware
validation tasks; the latest emulator results are in [heavy-load-check.md](heavy-load-check.md).
