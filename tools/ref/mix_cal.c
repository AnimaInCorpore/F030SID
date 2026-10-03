/*
 * Gain calibration of the reference mixer against reSID: the same steady note
 * as `oracle_resid cal`, rms and mean of the output over the last 400k cycles.
 *
 *   mix_cal <6581|8580> <routed> <fc> <res> <mode> [wave]
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
    unsigned routed, fc, res, fm, wave = 0x20;
    double sum = 0, sq = 0, mean;
    long long cnt = 0, c = 0;

    if (argc < 6) return 2;
    routed = atoi(argv[2]); fc = atoi(argv[3]); res = atoi(argv[4]); fm = atoi(argv[5]);
    if (argc > 6) wave = strtoul(argv[6], 0, 0);
    if (sid_tables_init("third_party/resid")) return 1;
    sid_ref_reset(&s, !strcmp(argv[1], "8580") ? SID_MOS8580 : SID_MOS6581);
    sid_ref_write(&s, 21, fc & 7); sid_ref_write(&s, 22, fc >> 3);
    sid_ref_write(&s, 23, (res << 4) | routed); sid_ref_write(&s, 24, (fm << 4) | 15);
    sid_ref_write(&s, 0, 0); sid_ref_write(&s, 1, 0x10);
    sid_ref_write(&s, 2, 0); sid_ref_write(&s, 3, 8);
    sid_ref_write(&s, 5, 0); sid_ref_write(&s, 6, 0xf0);
    sid_ref_write(&s, 4, wave | 1);
    while (c < 1000000) {
        sid_ref_frame(&s, &fr);
        c += fr.n;
        if (c >= 600000) { double o = fr.mix; sum += o; sq += o * o; cnt++; }
    }
    mean = sum / cnt;
    printf("%s routed=%u fc=%u res=%u mode=%u mean=%.1f rms=%.1f\n", argv[1], routed, fc, res, fm, mean, sqrt(sq / cnt - mean * mean));
    return 0;
}
