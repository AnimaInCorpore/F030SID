#!/usr/bin/env python3
"""Check the BLEP countdown's conservative bound over all SID frequencies.

The optimization may skip work only when even the largest possible phase
advance plus sample-instant jitter remains outside the two-frame BLEP window.
This checks that inequality independently of the DSP's rendered-audio gates.
"""
import random


def main():
    rng = random.Random(56001)
    cases = 0
    for freq in range(1, 65536):
        width = freq * 1313185 // 65536
        reciprocal = min(0x7fffff, (4096 << 23) // (21 * freq))
        # Window edges, countdown boundaries, maximum phase and random phase.
        distances = [0, 1, 2 * width, 2 * width + 1, 42 * freq - 1,
                     42 * freq, 42 * freq + 1, 0xffffff,
                     rng.randrange(1 << 24)]
        for distance in distances:
            count = min(2047, max(0, (((distance >> 12) * reciprocal) >> 23) - 2))
            if count:
                assert count * 21 * freq + freq + 2 * width <= distance, (
                    freq, distance, count)
            cases += 1
    print(f"PASS: {cases} boundary/random cases across all 65535 nonzero frequencies")


if __name__ == '__main__':
    main()
