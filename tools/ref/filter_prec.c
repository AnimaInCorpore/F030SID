/*
 * Precision of the DSP-arithmetic filter against the same filter in doubles.
 *
 *   filter_prec <6581|8580> <fc> <res> <mode> [noise|saw]
 *
 * One routed voice, steady note, the integer mixer (sid_frame_t.mix) against a
 * double-precision evaluation of the same equations on the same coefficient
 * words and the same voice outputs. Prints the error relative to the signal in
 * dB and in output LSB.
 */
#include "sid_ref.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    sid_ref_t s;
    sid_frame_t fr;
    unsigned fc, res, fm, wave;
    double s1 = 0, s2 = 0, xl = 0, xh = 0, ee = 0, ss = 0, maxe = 0;
    long long c = 0, n = 0;
    const double glp = 5182881 / 8388608.0, ghp = 8522 / 8388608.0;
    const double mixk[2] = { 3491 / 8388608.0, 1586 / 8388608.0 };
    const double fg[2] = { 1456640 / 2097152.0, 2152960 / 2097152.0 };
    const double cancel[2] = { 7936000 / 8388608.0, 8388607 / 8388608.0 };

    if (argc < 5) return 2;
    fc = atoi(argv[2]); res = atoi(argv[3]); fm = atoi(argv[4]);
    wave = argc > 5 && !strcmp(argv[5], "saw") ? 0x20 : 0x80;
    if (sid_tables_init("third_party/resid")) return 1;
    sid_ref_reset(&s, !strcmp(argv[1], "8580") ? SID_MOS8580 : SID_MOS6581);
    sid_ref_write(&s, 21, fc & 7); sid_ref_write(&s, 22, fc >> 3);
    sid_ref_write(&s, 23, (res << 4) | 1); sid_ref_write(&s, 24, (fm << 4) | 15);
    sid_ref_write(&s, 0, 0); sid_ref_write(&s, 1, wave == 0x80 ? 0x40 : 0x10);
    sid_ref_write(&s, 5, 0); sid_ref_write(&s, 6, 0xf0);
    sid_ref_write(&s, 4, wave | 1);
    while (c < 1500000) {
        double x, a1, a2, a3, k, v3, v1, v2, hp, f, mixed, y, y2, out;
        sid_ref_frame(&s, &fr);
        c += fr.n;
        x = (double)(fr.naive[0] >> 2) * 1.0;
        a1 = s.flt.c.a1 / 8388608.0; a2 = s.flt.c.a2 / 8388608.0; a3 = s.flt.c.a3 / 8388608.0;
        k = 4.0 * s.flt.c.k4 / 8388608.0;
        v3 = x - s2;
        v1 = a1 * s1 + a2 * v3;
        v2 = s2 + a2 * s1 + a3 * v3;
        s1 = 2 * v1 - s1; s2 = 2 * v2 - s2;
        hp = x - k * v1 - cancel[s.model] * v2;
        f = ((fm & 1) ? v2 : 0) + ((fm & 2) ? v1 : 0) + ((fm & 4) ? hp : 0);
        mixed = 4 * f * fg[s.model];
        mixed *= s.flt.vol * mixk[s.model] * 2.0 * 8388608.0 / 16777216.0 * 2.0 / 2.0;
        {   /* external filter, exact */
            double d = mixed - xl, v = glp * d; y = xl + v; xl = y + v;
            d = y - xh; v = ghp * d; y2 = xh + v; xh = y2 + v;
        }
        out = y - y2;
        if (c > 400000) {
            double e = fr.mix - out;
            ee += e * e; ss += out * out; n++;
            if (fabs(e) > maxe) maxe = fabs(e);
        }
    }
    printf("%s fc=%u res=%u mode=%u: signal rms %.1f, error rms %.3f LSB (%.1f dB), max %.1f\n",
           argv[1], fc, res, fm, sqrt(ss / n), sqrt(ee / n), 10 * log10(ee / ss), maxe);
    return 0;
}
