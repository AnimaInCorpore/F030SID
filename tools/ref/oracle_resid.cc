// reSID oracle for the F030SID reference model.
//
//   oracle_resid frames <6581|8580> <trace> <out.tsv>
//       Clocks reSID's SID::clock(n) once per codec frame with exactly the
//       frame lengths and write timing src/ref/sid_ref.c uses, and dumps the
//       per-voice state the reference must reproduce bit for bit.
//
//   oracle_resid cycles <6581|8580> <trace> <voice 0-2> <out.i32>
//       Clocks reSID one SID cycle at a time (its cycle-exact path, with
//       writes at their exact cycle) and dumps Voice::output() after every
//       cycle as int32. This is the band-limiting ground truth.
//
// Trace format: "cycle reg value" per line (decimal or 0x hex), a final
// "end cycle" line. Registers 0..20 are the three voices' 7 registers each.
//
// reSID keeps its voices private; the hack below is for this test tool only.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define private public
#define protected public
#include "sid.h"
#undef private
#undef protected

#include "sid_ref.h"

struct Write { long long cycle; unsigned reg, value; };

static bool read_trace(const char *path, std::vector<Write> &w, long long &end)
{
    FILE *f = fopen(path, "r");
    char line[256];
    end = 0;
    if (!f) { perror(path); return false; }
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') ++p;
        if (*p == '#' || *p == '\n' || *p == 0) continue;
        if (!strncmp(p, "end", 3)) { end = strtoll(p + 3, nullptr, 0); continue; }
        Write x;
        if (sscanf(p, "%lli %i %i", &x.cycle, (int *)&x.reg, (int *)&x.value) == 3)
            w.push_back(x);
    }
    fclose(f);
    return end > 0;
}

static void setup(reSID::SID &sid, bool is8580)
{
    sid.set_chip_model(is8580 ? reSID::MOS8580 : reSID::MOS6581);
    // Any non-FAST method: FAST fakes a one-cycle write pipeline on the 8580.
    sid.set_sampling_parameters(985248.0, reSID::SAMPLE_RESAMPLE, 44100.0);
    sid.reset();
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: %s frames|cycles 6581|8580 trace [voice] out\n", argv[0]);
        return 2;
    }
    const std::string mode = argv[1];
    const bool is8580 = !strcmp(argv[2], "8580");
    std::vector<Write> writes;
    long long end;
    if (!read_trace(argv[3], writes, end)) return 1;

    reSID::SID sid;
    setup(sid, is8580);
    size_t wi = 0;

    if (mode == "frames") {
        FILE *out = fopen(argv[4], "w");
        if (!out) { perror(argv[4]); return 1; }
        long long c = 0;
        uint32_t eps = 0;
        for (long long k = 1; c < end; k++) {
            uint32_t peek = eps;
            int n = sid_frame_step(&peek);
            while (wi < writes.size() && writes[wi].cycle < c + n) {
                sid.write(writes[wi].reg, writes[wi].value);
                ++wi;
            }
            n = sid_frame_step(&eps);
            sid.clock(n);
            c += n;
            fprintf(out, "%lld %d", k, n);
            for (int i = 0; i < 3; i++) {
                reSID::Voice &v = sid.voice[i];
                fprintf(out, " %d %u %u %u %u", v.output(),
                        (unsigned)v.wave.accumulator, (unsigned)v.wave.shift_register,
                        (unsigned)v.envelope.envelope_counter,
                        (unsigned)v.envelope.rate_counter);
            }
            fputc('\n', out);
        }
        fclose(out);
        return 0;
    }

    if (mode == "cycles" && argc >= 6) {
        const int voice = atoi(argv[4]);
        FILE *out = fopen(argv[5], "wb");
        if (!out || voice < 0 || voice > 2) { perror(argv[5]); return 1; }
        std::vector<int32_t> buf;
        buf.reserve((size_t)end);
        for (long long c = 0; c < end; c++) {
            while (wi < writes.size() && writes[wi].cycle <= c) {
                sid.write(writes[wi].reg, writes[wi].value);
                ++wi;
            }
            sid.clock(1);
            buf.push_back(sid.voice[voice].output());
        }
        fwrite(buf.data(), sizeof(int32_t), buf.size(), out);
        fclose(out);
        return 0;
    }

    fprintf(stderr, "bad mode\n");
    return 2;
}
