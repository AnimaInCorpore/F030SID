// sidtrace: run a PSID/RSID tune in libsidplayfp and dump the SID register
// writes with their exact C64 cycle stamps, in the .trace format the voice
// reference model and the reSID oracle read (see tools/ref/oracle_resid.cc).
//
//   sidtrace [options] tune.sid
//     -o FILE        output (default: tune name + .trace); further SID chips of
//                    a 2SID/3SID tune go to FILE with ".2"/".3" before the
//                    extension
//     -t SECONDS     length of the recorded window (default 30)
//     -k SECONDS     skip: run this long first, then record. The window opens
//                    with the register values at that moment replayed at
//                    cycle 0, so the chip state is approximated (a gate bit
//                    left on is re-applied and restarts the envelope)
//     -s SONG        song number (default: the tune's start song)
//     -m 6581|8580   force the SID model (default: the tune's preference)
//     --ntsc|--pal   force the video standard (default: the tune's, else PAL)
//
// The writes are tapped from libsidplayfp's own ReSIDfp emulation, so the
// player, CIA/VIC timing and OSC3/ENV3 reads behave exactly as in sidplayfp.
// Cycle stamps are C64 PHI1 cycles from the start of the recorded window
// (cycle 0 = power-on when -k is 0, including the PSID driver's init).
//
// Build: see the Makefile target `trace` (needs libsidplayfp's source tree
// for the internal sidemu headers; build/lsfp is the static library).

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include <sidplayfp/SidConfig.h>
#include <sidplayfp/SidInfo.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidTuneInfo.h>
#include <sidplayfp/sidbuilder.h>
#include <sidplayfp/sidplayfp.h>

// ReSIDfp is declared `final`; deriving from it is the least invasive way to
// tap the register stream of the real emulation. Only this translation unit
// sees the keyword removed, and it changes no layout.
#define final
#include "residfp-emu.h"
#undef final

namespace {

struct Write { uint64_t cycle; unsigned reg, value; };

struct ChipLog {
    std::vector<Write> writes;
    unsigned shadow[0x20] = {};
    bool seen[0x20] = {};
    uint64_t last_clock = 0;
    int order = -1;                       // 0, 1, 2: the order the player locked the chips
};

uint64_t g_skip = 0;                      // cycles to run before recording
std::vector<ChipLog *> g_logs;            // every chip created, in no particular order
int g_locked = 0;

class TraceFp : public libsidplayfp::ReSIDfp {
    ChipLog &log_;

public:
    TraceFp(sidbuilder *b, ChipLog &log) : libsidplayfp::ReSIDfp(b), log_(log) {}

    // The builder's chips sit in a pointer-ordered set, so their creation
    // order says nothing about which SID of a 2SID/3SID tune they are; the
    // player locks them in SID order.
    bool lock(libsidplayfp::EventScheduler *s) override
    {
        const bool ok = libsidplayfp::ReSIDfp::lock(s);
        if (ok) log_.order = g_locked++;
        return ok;
    }

    void write(uint_least8_t addr, uint8_t data) override
    {
        const uint64_t t = eventScheduler->getTime(libsidplayfp::EVENT_CLOCK_PHI1);
        log_.writes.push_back({t, addr, data});
        log_.shadow[addr & 0x1f] = data;
        log_.seen[addr & 0x1f] = true;
        libsidplayfp::ReSIDfp::write(addr, data);
    }

    void clock() override
    {
        if (eventScheduler)
            log_.last_clock = eventScheduler->getTime(libsidplayfp::EVENT_CLOCK_PHI1);
        libsidplayfp::ReSIDfp::clock();
    }
};

class TraceBuilder : public sidbuilder {
public:
    TraceBuilder() : sidbuilder("sidtrace") {}

    unsigned int create(unsigned int sids) override
    {
        for (unsigned i = 0; i < sids; i++) {
            ChipLog *l = new ChipLog;
            g_logs.push_back(l);
            sidobjs.insert(new TraceFp(this, *l));
        }
        return sids;
    }

    unsigned int availDevices() const override { return 0; }   // unlimited
    const char *credits() const override { return "sidtrace tap on ReSIDfp"; }
    void filter(bool) override {}
};

std::string chip_path(const std::string &base, unsigned chip)
{
    if (chip == 0) return base;
    const size_t dot = base.rfind('.');
    const std::string tag = "." + std::to_string(chip + 1);
    return dot == std::string::npos ? base + tag : base.substr(0, dot) + tag + base.substr(dot);
}

}  // namespace

int main(int argc, char **argv)
{
    std::string out, tunefile;
    double seconds = 30, skip = 0;
    unsigned song = 0;
    int model = 0;                       // 0 = tune's, else 6581/8580
    int video = 0;                       // 0 = tune's, 1 = PAL, 2 = NTSC

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-o") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(a, "-t") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(a, "-k") && i + 1 < argc) skip = atof(argv[++i]);
        else if (!strcmp(a, "-s") && i + 1 < argc) song = (unsigned)atoi(argv[++i]);
        else if (!strcmp(a, "-m") && i + 1 < argc) model = atoi(argv[++i]);
        else if (!strcmp(a, "--pal")) video = 1;
        else if (!strcmp(a, "--ntsc")) video = 2;
        else if (a[0] == '-') { fprintf(stderr, "unknown option %s\n", a); return 2; }
        else tunefile = a;
    }
    if (tunefile.empty() || (model && model != 6581 && model != 8580)) {
        fprintf(stderr, "usage: %s [-o file] [-t sec] [-k sec] [-s song] [-m 6581|8580] "
                        "[--pal|--ntsc] tune.sid\n", argv[0]);
        return 2;
    }
    if (out.empty()) {
        out = tunefile;
        const size_t dot = out.rfind('.');
        if (dot != std::string::npos) out.resize(dot);
        out += ".trace";
    }

    SidTune tune(tunefile.c_str());
    if (!tune.getStatus()) {
        fprintf(stderr, "%s: %s\n", tunefile.c_str(), tune.statusString());
        return 1;
    }
    tune.selectSong(song);

    const SidTuneInfo *ti = tune.getInfo();
    if (video == 0)
        video = ti->clockSpeed() == SidTuneInfo::CLOCK_NTSC ? 2 : 1;
    const uint64_t hz = video == 2 ? 1022727 : 985248;

    sidplayfp engine;
    TraceBuilder builder;
    builder.create(engine.info().maxsids());
    SidConfig cfg = engine.config();
    cfg.playback = SidConfig::MONO;
    cfg.sidEmulation = &builder;
    cfg.powerOnDelay = 0;                // deterministic start
    cfg.defaultC64Model = video == 2 ? SidConfig::NTSC : SidConfig::PAL;
    cfg.forceC64Model = true;
    if (model) {
        cfg.defaultSidModel = model == 8580 ? SidConfig::MOS8580 : SidConfig::MOS6581;
        cfg.forceSidModel = true;
    }
    if (!engine.config(cfg)) {
        fprintf(stderr, "config: %s\n", engine.error());
        return 1;
    }
    if (!engine.load(&tune)) {
        fprintf(stderr, "load: %s\n", engine.error());
        return 1;
    }

    g_skip = (uint64_t)(skip * (double)hz + 0.5);
    const uint64_t total = g_skip + (uint64_t)(seconds * (double)hz + 0.5);

    // The recorded window opens when the simulated time passes g_skip; snapshot
    // the shadow registers then.
    std::vector<std::vector<Write>> opening;
    bool opened = g_skip == 0;
    uint64_t done = 0;

    while (done < total) {
        unsigned chunk = 20000;
        if (!opened && done + chunk > g_skip) chunk = (unsigned)(g_skip - done);
        if (chunk > total - done) chunk = (unsigned)(total - done);
        if (!chunk) chunk = 1;
        const int r = engine.play(chunk);
        if (r < 0) {
            fprintf(stderr, "play: %s (stopped at cycle %llu)\n", engine.error(),
                    (unsigned long long)done);
            break;
        }
        done += chunk;
        if (!opened && done >= g_skip) {
            opened = true;
            for (int ord = 0; ord < g_locked; ord++) {
                ChipLog *l = nullptr;
                for (ChipLog *x : g_logs) if (x->order == ord) l = x;
                std::vector<Write> snap;
                for (unsigned r2 = 0; r2 < 0x19; r2++)
                    if (l->seen[r2]) snap.push_back({0, r2, l->shadow[r2]});
                opening.push_back(snap);
                // writes up to now are folded into the snapshot
                l->writes.clear();
            }
        }
    }

    const SidInfo &info = engine.info();
    std::vector<ChipLog *> chips(g_locked);
    for (ChipLog *l : g_logs)
        if (l->order >= 0) chips[l->order] = l;
    for (unsigned c = 0; c < chips.size(); c++) {
        const ChipLog &l = *chips[c];
        const std::string path = chip_path(out, c);
        FILE *f = fopen(path.c_str(), "w");
        if (!f) { perror(path.c_str()); return 1; }
        fprintf(f, "# sidtrace %s song %u of %u, chip %u of %u, %s %llu Hz\n",
                tunefile.c_str(), ti->currentSong(), ti->songs(), c + 1,
                (unsigned)chips.size(), video == 2 ? "NTSC" : "PAL", (unsigned long long)hz);
        for (unsigned s = 0; s < ti->numberOfInfoStrings(); s++)
            fprintf(f, "# %s\n", ti->infoString(s));
        fprintf(f, "# %s, SID model %s\n", info.speedString(),
                model == 8580 ? "8580 (forced)" : model == 6581 ? "6581 (forced)" : "tune's choice");
        if (g_skip) fprintf(f, "# window starts %.3f s into the tune; registers replayed at cycle 0\n", skip);
        if (c < opening.size())
            for (const Write &w : opening[c]) fprintf(f, "0 %u %u\n", w.reg, w.value);
        for (const Write &w : l.writes) {
            const uint64_t t = w.cycle >= g_skip ? w.cycle - g_skip : 0;
            if (w.reg < 0x19) fprintf(f, "%llu %u %u\n", (unsigned long long)t, w.reg, w.value);
        }
        fprintf(f, "end %llu\n", (unsigned long long)(l.last_clock > g_skip ? l.last_clock - g_skip : total - g_skip));
        fclose(f);
        fprintf(stderr, "%s: %zu writes\n", path.c_str(), l.writes.size() + (c < opening.size() ? opening[c].size() : 0));
    }
    return 0;
}
