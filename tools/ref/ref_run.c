/*
 * Run the F030SID reference model on a register trace.
 *
 *   ref_run <6581|8580> <trace> <resid_dir> <exact.tsv> <bl.tsv>
 *
 * exact.tsv has the columns oracle_resid writes (frame, cycles, then per
 * voice: output, accumulator, LFSR, envelope counter, rate counter) and must
 * match reSID exactly. bl.tsv has frame, eps (Q24), and the three band-limited
 * outputs, which are graded against the per-cycle truth by voice_gate.py.
 * Write timing is the same as the oracle's: a write is applied at the start
 * of the frame that contains its cycle.
 */
#include "sid_ref.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { long long cycle; unsigned reg, value; } write_t;

static int read_trace(const char *path, write_t **out, size_t *count, long long *end)
{
    FILE *f = fopen(path, "r");
    char line[256];
    size_t cap = 1024, n = 0;
    write_t *w = malloc(cap * sizeof *w);

    *end = 0;
    if (!f) { perror(path); return -1; }
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') ++p;
        if (*p == '#' || *p == '\n' || *p == 0) continue;
        if (!strncmp(p, "end", 3)) { *end = strtoll(p + 3, NULL, 0); continue; }
        {
            long long c;
            int r, v;
            if (sscanf(p, "%lli %i %i", &c, &r, &v) == 3) {
                if (n == cap) { cap *= 2; w = realloc(w, cap * sizeof *w); }
                w[n].cycle = c; w[n].reg = (unsigned)r; w[n].value = (unsigned)v;
                n++;
            }
        }
    }
    fclose(f);
    *out = w;
    *count = n;
    return *end > 0 ? 0 : -1;
}

int main(int argc, char **argv)
{
    sid_ref_t s;
    sid_frame_t fr;
    write_t *w;
    size_t nw, wi = 0;
    long long end, c = 0, k;
    FILE *ex, *bl;
    int i;

    if (argc < 6) {
        fprintf(stderr, "usage: %s 6581|8580 trace resid_dir exact.tsv bl.tsv\n", argv[0]);
        return 2;
    }
    if (read_trace(argv[2], &w, &nw, &end)) return 1;
    if (sid_tables_init(argv[3])) return 1;
    sid_ref_reset(&s, !strcmp(argv[1], "8580") ? SID_MOS8580 : SID_MOS6581);
    ex = fopen(argv[4], "w");
    bl = fopen(argv[5], "w");
    if (!ex || !bl) { perror("output"); return 1; }

    for (k = 1; c < end; k++) {
        uint32_t peek = s.eps;
        int n = sid_frame_step(&peek);

        while (wi < nw && w[wi].cycle < c + n) {
            sid_ref_write(&s, w[wi].reg, w[wi].value);
            wi++;
        }
        sid_ref_frame(&s, &fr);
        c += fr.n;

        fprintf(ex, "%lld %d", k, fr.n);
        for (i = 0; i < 3; i++)
            fprintf(ex, " %d %u %u %u %u", fr.naive[i], (unsigned)s.v[i].acc,
                    (unsigned)s.v[i].shift_register, (unsigned)s.v[i].envelope_counter,
                    (unsigned)s.v[i].rate_counter);
        fputc('\n', ex);
        fprintf(bl, "%lld %u %d %d %d\n", k, (unsigned)fr.eps, fr.bl[0], fr.bl[1], fr.bl[2]);
    }
    fclose(ex);
    fclose(bl);
    free(w);
    return 0;
}
