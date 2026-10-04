/*
 * F030SID reference model. See sid_ref.h.
 *
 * The oscillator, noise and envelope logic is a transcription of reSID
 * (libsidplayfp fork, third_party/resid: wave.h/wave.cc, envelope.h/
 * envelope.cc, voice.cc, SID::clock(delta_t)), bulk-clocked: one call per
 * codec frame advances every unit by that frame's whole cycle count. Where
 * reSID has a separate single-cycle path with pipeline delays, this model
 * follows the bulk path, which is what a frame-rate renderer can do.
 *
 * DSP mapping notes are marked "DSP:".
 */
#include "sid_ref.h"
#include "filter_tables.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

/* ------------------------------------------------------------------ tables */

static uint16_t wave_table[2][8][1 << 12];
static uint16_t wave_dac[2][1 << 12];
static uint16_t env_dac[2][1 << 8];
static int32_t  blep_step[129];           /* S(i/64) - 1, Q23, i = 0..128 */

static const uint16_t rate_counter_period[16] = {
    8, 31, 62, 94, 148, 219, 266, 312, 391, 976, 1953, 3125, 3906, 11719,
    19531, 31250
};

static const uint8_t sustain_level[16] = {
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
};

static const int32_t wave_zero[2] = { 0x380, 0x9e0 };

/* reSID noise/floating-output timing constants (cycles). */
#define SHIFT_REGISTER_RESET_START_6581   35000
#define SHIFT_REGISTER_RESET_BIT_6581      1000
#define SHIFT_REGISTER_RESET_START_8580 2519864
#define SHIFT_REGISTER_RESET_BIT_8580    315000
#define FLOATING_OUTPUT_TTL_START_6581   182000
#define FLOATING_OUTPUT_TTL_BIT_6581       1500
#define FLOATING_OUTPUT_TTL_START_8580  4400000
#define FLOATING_OUTPUT_TTL_BIT_8580      50000

/* reSID dac.cc: R-2R ladder with leakage, bits wide. */
static void build_dac_table(uint16_t *dac, int bits, double _2R_div_R, int term)
{
    double vbit[12];
    const double leakage = term ? 0.0035 : 0.0075;
    int set_bit, bit, i, j;

    for (set_bit = 0; set_bit < bits; set_bit++) {
        double Vn = 1.0, R = 1.0, _2R = _2R_div_R * R;
        double Rn = term ? _2R : INFINITY;

        for (bit = 0; bit < set_bit; bit++) {
            if (Rn == INFINITY) Rn = R + _2R;
            else Rn = R + _2R * Rn / (_2R + Rn);
        }
        if (Rn == INFINITY) {
            Rn = _2R;
        } else {
            Rn = _2R * Rn / (_2R + Rn);
            Vn = Vn * Rn / _2R;
        }
        for (++bit; bit < bits; bit++) {
            double I;
            Rn += R;
            I = Vn / Rn;
            Rn = _2R * Rn / (_2R + Rn);
            Vn = Rn * I;
        }
        vbit[set_bit] = Vn;
    }
    for (i = 0; i < (1 << bits); i++) {
        int x = i;
        double Vo = 0;
        for (j = 0; j < bits; j++) {
            Vo += ((x & 1) ? 1.0 : leakage) * vbit[j];
            x >>= 1;
        }
        dac[i] = (uint16_t)(((1 << bits) - 1) * Vo + 0.5);
    }
}

static int load_combined(uint16_t *dst, const char *dir, const char *name)
{
    char path[1024];
    unsigned char buf[4096];
    FILE *f;
    int i;

    snprintf(path, sizeof path, "%s/%s", dir, name);
    f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "sid_ref: cannot open %s\n", path);
        return -1;
    }
    if (fread(buf, 1, sizeof buf, f) != sizeof buf) {
        fprintf(stderr, "sid_ref: %s is not 4096 bytes\n", path);
        fclose(f);
        return -1;
    }
    fclose(f);
    for (i = 0; i < 4096; i++) dst[i] = (uint16_t)(buf[i] << 4);
    return 0;
}

int sid_tables_init(const char *dir)
{
    static const char *const names[2][4] = {
        { "wave6581__ST.dat", "wave6581_P_T.dat", "wave6581_PS_.dat", "wave6581_PST.dat" },
        { "wave8580__ST.dat", "wave8580_P_T.dat", "wave8580_PS_.dat", "wave8580_PST.dat" },
    };
    static const int slot[4] = { 3, 5, 6, 7 };
    uint32_t acc = 0;
    int m, i;

    for (m = 0; m < 2; m++)
        for (i = 0; i < 4; i++)
            if (load_combined(wave_table[m][slot[i]], dir, names[m][i]))
                return -1;

    for (i = 0; i < (1 << 12); i++) {
        uint32_t msb = acc & 0x800000;
        uint32_t mask = msb ? 0xffffffffu : 0u;
        for (m = 0; m < 2; m++) {
            wave_table[m][0][i] = 0xfff;
            wave_table[m][1][i] = (uint16_t)(((acc ^ mask) >> 11) & 0xffe);
            wave_table[m][2][i] = (uint16_t)(acc >> 12);
            wave_table[m][4][i] = 0xfff;
        }
        acc += 0x1000;
    }

    build_dac_table(wave_dac[0], 12, 2.20, 0);
    build_dac_table(wave_dac[1], 12, 2.00, 1);
    build_dac_table(env_dac[0], 8, 2.20, 0);
    build_dac_table(env_dac[1], 8, 2.00, 1);

    /* Integral of the cubic cardinal B-spline (support 4 samples) minus the
     * unit step, for d = 0..2 frames after an edge. The kernel is symmetric,
     * so the residual before an edge is the negative mirror image.
     * DSP: 129 words in internal Y RAM (or 65 with a halved resolution). */
    for (i = 0; i <= 128; i++) {
        double x = i / 64.0, S;
        if (x <= 1.0) S = 0.5 + x * (2.0 / 3.0) - x * x * x / 3.0 + x * x * x * x / 8.0;
        else S = 1.0 - pow(2.0 - x, 4.0) / 24.0;
        blep_step[i] = (int32_t)lrint((S - 1.0) * 8388608.0);
    }
    return 0;
}

const uint16_t *sid_tab_wave_dac(sid_model_t m) { return wave_dac[m]; }
const uint16_t *sid_tab_env_dac(sid_model_t m) { return env_dac[m]; }
const uint16_t *sid_tab_rate_period(void) { return rate_counter_period; }
const uint8_t *sid_tab_sustain_level(void) { return sustain_level; }
const uint16_t *sid_tab_wave(sid_model_t m, int w) { return wave_table[m][w & 7]; }
int32_t sid_shift_reset_start(sid_model_t m)
{
    return m == SID_MOS6581 ? SHIFT_REGISTER_RESET_START_6581 : SHIFT_REGISTER_RESET_START_8580;
}
int32_t sid_wave_zero(sid_model_t m) { return wave_zero[m]; }
int32_t sid_floating_ttl_start(sid_model_t m)
{
    return m == SID_MOS6581 ? FLOATING_OUTPUT_TTL_START_6581 : FLOATING_OUTPUT_TTL_START_8580;
}

/* -------------------------------------------------------------- envelope */

static void env_set_exponential_counter(sid_voice_t *v)
{
    switch (v->envelope_counter) {
    case 0xff: v->exponential_counter_period = 1; break;
    case 0x5d: v->exponential_counter_period = 2; break;
    case 0x36: v->exponential_counter_period = 4; break;
    case 0x1a: v->exponential_counter_period = 8; break;
    case 0x0e: v->exponential_counter_period = 16; break;
    case 0x06: v->exponential_counter_period = 30; break;
    case 0x00: v->exponential_counter_period = 1; v->hold_zero = 1; break;
    }
}

static void env_reset(sid_voice_t *v)
{
    v->state_pipeline = 0;
    v->attack = v->decay = v->sustain = v->release = 0;
    v->gate = 0;
    v->rate_counter = 0;
    v->exponential_counter = 0;
    v->exponential_counter_period = 1;
    v->state = ENV_RELEASE;
    v->rate_period = rate_counter_period[v->release];
    v->hold_zero = 0;
}

/* reSID writeCONTROL_REG with the single-cycle pipeline terms
 * (reset_rate_counter, exponential_pipeline, envelope_pipeline) at zero, as
 * they always are under bulk clocking. */
static void env_write_control(sid_voice_t *v, uint32_t control)
{
    uint32_t gate_next = control & 1;

    if (v->gate != gate_next) {
        v->next_state = gate_next ? ENV_ATTACK : ENV_RELEASE;
        if (v->next_state == ENV_ATTACK) {
            v->state = ENV_DECAY_SUSTAIN;
            v->rate_period = rate_counter_period[v->decay];
        }
        v->state_pipeline = 2;
        v->gate = gate_next;
    }
}

static void env_write_attack_decay(sid_voice_t *v, uint32_t ad)
{
    v->attack = (ad >> 4) & 0xf;
    v->decay = ad & 0xf;
    if (v->state == ENV_ATTACK) v->rate_period = rate_counter_period[v->attack];
    else if (v->state == ENV_DECAY_SUSTAIN) v->rate_period = rate_counter_period[v->decay];
}

static void env_write_sustain_release(sid_voice_t *v, uint32_t sr)
{
    v->sustain = (sr >> 4) & 0xf;
    v->release = sr & 0xf;
    if (v->state == ENV_RELEASE) v->rate_period = rate_counter_period[v->release];
}

/*
 * Advance the envelope by dt cycles (reSID EnvelopeGenerator::clock(dt)).
 *
 * DSP: rate_counter and rate_period are 15-bit; the frame step adds dt (20 or
 * 21) and compares. The loop body (an envelope step) runs at most once or
 * twice a frame at the fastest attack (period 8 cycles), so it is the cold
 * path; the hot path is the add, the 0x8000 wrap test and the compare.
 */
static void env_clock(sid_voice_t *v, int dt)
{
    int rate_step;

    if (v->state_pipeline) {
        if (v->next_state == ENV_ATTACK) {
            v->state = ENV_ATTACK;
            v->hold_zero = 0;
            v->rate_period = rate_counter_period[v->attack];
        } else if (v->next_state == ENV_RELEASE) {
            v->state = ENV_RELEASE;
            v->rate_period = rate_counter_period[v->release];
        } else if (v->next_state == ENV_FREEZED) {
            v->hold_zero = 1;
        }
        v->state_pipeline = 0;
    }

    /* ADSR delay bug: a rate period set below the running counter makes the
     * counter wrap at 2^15 before the next step. */
    rate_step = (int)v->rate_period - (int)v->rate_counter;
    if (rate_step <= 0) rate_step += 0x7fff;

    while (dt) {
        if (dt < rate_step) {
            v->rate_counter += (uint32_t)dt;
            if (v->rate_counter & 0x8000) {
                ++v->rate_counter;
                v->rate_counter &= 0x7fff;
            }
            return;
        }

        v->rate_counter = 0;
        dt -= rate_step;

        if (v->state == ENV_ATTACK || ++v->exponential_counter == v->exponential_counter_period) {
            v->exponential_counter = 0;

            if (v->hold_zero) {
                rate_step = (int)v->rate_period;
                continue;
            }

            switch (v->state) {
            case ENV_ATTACK:
                v->envelope_counter = (v->envelope_counter + 1) & 0xff;
                if (v->envelope_counter == 0xff) {
                    v->state = ENV_DECAY_SUSTAIN;
                    v->rate_period = rate_counter_period[v->decay];
                }
                break;
            case ENV_DECAY_SUSTAIN:
                if (v->envelope_counter != sustain_level[v->sustain])
                    v->envelope_counter = (v->envelope_counter - 1) & 0xff;
                break;
            case ENV_RELEASE:
                v->envelope_counter = (v->envelope_counter - 1) & 0xff;
                break;
            case ENV_FREEZED:
                break;
            }
            env_set_exponential_counter(v);
        }
        rate_step = (int)v->rate_period;
    }
}

/* ------------------------------------------------------------ oscillator */

static void wave_set_noise_output(sid_voice_t *w)
{
    uint32_t sr = w->shift_register;
    w->noise_output =
        ((sr & 0x100000) >> 9) | ((sr & 0x040000) >> 8) |
        ((sr & 0x004000) >> 5) | ((sr & 0x000800) >> 3) |
        ((sr & 0x000200) >> 2) | ((sr & 0x000020) << 1) |
        ((sr & 0x000004) << 3) | ((sr & 0x000001) << 4);
    w->no_noise_or_noise_output = w->no_noise | w->noise_output;
}

/* One LFSR step: x^23 + x^18 + 1 with the output taps scattered over eight
 * bits. DSP: 23-bit shift, one XOR of two bits, and the gather is two table
 * lookups (or about a dozen mask/shift/or instructions). */
static void wave_clock_shift_register(sid_voice_t *w)
{
    uint32_t bit0 = ((w->shift_register >> 22) ^ (w->shift_register >> 17)) & 1;
    w->shift_register = ((w->shift_register << 1) | bit0) & 0x7fffff;
    wave_set_noise_output(w);
}

static void wave_write_shift_register(sid_voice_t *w)
{
    w->shift_register &=
        ~((1u << 20) | (1u << 18) | (1u << 14) | (1u << 11) | (1u << 9) |
          (1u << 5) | (1u << 2) | (1u << 0)) |
        ((w->waveform_output & 0x800) << 9) |
        ((w->waveform_output & 0x400) << 8) |
        ((w->waveform_output & 0x200) << 5) |
        ((w->waveform_output & 0x100) << 3) |
        ((w->waveform_output & 0x080) << 2) |
        ((w->waveform_output & 0x040) >> 1) |
        ((w->waveform_output & 0x020) >> 3) |
        ((w->waveform_output & 0x010) >> 4);
    w->noise_output &= w->waveform_output;
    w->no_noise_or_noise_output = w->no_noise | w->noise_output;
}

static void wave_bitfade(sid_voice_t *w, sid_model_t m)
{
    w->waveform_output &= w->waveform_output >> 1;
    if (w->waveform_output != 0)
        w->floating_output_ttl = (m == SID_MOS6581) ?
            FLOATING_OUTPUT_TTL_BIT_6581 : FLOATING_OUTPUT_TTL_BIT_8580;
}

static uint32_t noise_pulse6581(uint32_t noise)
{
    return (noise < 0xf00) ? 0x000 : noise & (noise << 1) & (noise << 2);
}

static uint32_t noise_pulse8580(uint32_t noise)
{
    return (noise < 0xfc0) ? noise & (noise << 1) : 0xfc0;
}

/* reSID WaveformGenerator::clock(delta_t). DSP: the 24-bit phase is one
 * add; the noise shift count comes from the bit-19 crossings. */
static void wave_clock(sid_voice_t *w, int dt)
{
    if (w->test) {
        if (w->shift_register_reset) {
            w->shift_register_reset -= dt;
            if (w->shift_register_reset <= 0) {
                w->shift_register = 0x7fffff;
                w->shift_register_reset = 0;
                wave_set_noise_output(w);
            }
        }
        w->pulse_output = 0xfff;
    } else {
        uint32_t delta_accumulator = (uint32_t)dt * w->freq;
        uint32_t accumulator_next = (w->acc + delta_accumulator) & 0xffffff;
        uint32_t accumulator_bits_set = ~w->acc & accumulator_next;
        uint32_t shift_period = 0x100000;

        w->acc = accumulator_next;
        w->msb_rising = (accumulator_bits_set & 0x800000) ? 1 : 0;

        while (delta_accumulator) {
            if (delta_accumulator < shift_period) {
                shift_period = delta_accumulator;
                if (shift_period <= 0x080000) {
                    if (((w->acc - shift_period) & 0x080000) || !(w->acc & 0x080000))
                        break;
                } else {
                    if (((w->acc - shift_period) & 0x080000) && !(w->acc & 0x080000))
                        break;
                }
            }
            wave_clock_shift_register(w);
            delta_accumulator -= shift_period;
        }
        w->pulse_output = ((w->acc >> 12) >= w->pw) ? 0xfff : 0x000;
    }
}

/* reSID WaveformGenerator::set_waveform_output(delta_t) */
static void wave_set_output_dt(sid_voice_t *w, const sid_voice_t *src, sid_model_t m, int dt)
{
    if (w->waveform) {
        uint32_t ix = (w->acc ^ (~src->acc & w->ring_msb_mask)) >> 12;
        w->waveform_output = wave_table[m][w->waveform & 7][ix] &
            (w->no_pulse | w->pulse_output) & w->no_noise_or_noise_output;

        if ((w->waveform & 2) && (w->waveform & 0xd) && m == SID_MOS6581)
            w->acc &= (w->waveform_output << 12) | 0x7fffff;
        if (w->waveform > 8 && !w->test)
            wave_write_shift_register(w);
    } else if (w->floating_output_ttl) {
        w->floating_output_ttl -= dt;
        if (w->floating_output_ttl <= 0) {
            w->floating_output_ttl = 0;
            w->waveform_output = 0;
        }
    }
}

/* reSID WaveformGenerator::set_waveform_output(), used after a control write. */
static void wave_set_output(sid_voice_t *w, const sid_voice_t *src, sid_model_t m)
{
    if (w->waveform) {
        uint32_t ix = (w->acc ^ (~src->acc & w->ring_msb_mask)) >> 12;
        w->waveform_output = wave_table[m][w->waveform & 7][ix] &
            (w->no_pulse | w->pulse_output) & w->no_noise_or_noise_output;

        if ((w->waveform & 0xc) == 0xc)
            w->waveform_output = (m == SID_MOS6581) ?
                noise_pulse6581(w->waveform_output) : noise_pulse8580(w->waveform_output);

        if ((w->waveform & 2) && (w->waveform & 0xd) && m == SID_MOS6581)
            w->acc &= (w->waveform_output << 12) | 0x7fffff;
        if (w->waveform > 8 && !w->test)
            wave_write_shift_register(w);
    } else if (w->floating_output_ttl) {
        if (!--w->floating_output_ttl)
            wave_bitfade(w, m);
    }
    w->pulse_output = -((w->acc >> 12) >= w->pw) & 0xfff;
}

static int do_pre_writeback(uint32_t prev, uint32_t cur, int is6581)
{
    if (prev <= 0x8) return 0;
    if (prev == 0xc) {
        if (is6581) return 0;
        if (cur != 0x9 && cur != 0xe) return 0;
    }
    if (is6581 &&
        ((((prev & 3) == 1) && ((cur & 3) == 2)) ||
         (((prev & 3) == 2) && ((cur & 3) == 1))))
        return 0;
    return 1;
}

static void wave_write_control(sid_voice_t *w, const sid_voice_t *src, sid_model_t m, uint32_t control)
{
    uint32_t waveform_prev = w->waveform;
    uint32_t test_prev = w->test;

    w->waveform = (control >> 4) & 0x0f;
    w->test = control & 0x08;
    w->ring_mod = control & 0x04;
    w->sync = control & 0x02;

    w->ring_msb_mask = ((~control >> 5) & (control >> 2) & 1) << 23;
    w->no_noise = (w->waveform & 0x8) ? 0x000 : 0xfff;
    w->no_noise_or_noise_output = w->no_noise | w->noise_output;
    w->no_pulse = (w->waveform & 0x4) ? 0x000 : 0xfff;

    if (!test_prev && w->test) {
        w->acc = 0;
        w->shift_register_reset = (m == SID_MOS6581) ?
            SHIFT_REGISTER_RESET_START_6581 : SHIFT_REGISTER_RESET_START_8580;
        w->pulse_output = 0xfff;
    } else if (test_prev && !w->test) {
        uint32_t bit0;
        if (do_pre_writeback(waveform_prev, w->waveform, m == SID_MOS6581))
            wave_write_shift_register(w);
        bit0 = (~w->shift_register >> 17) & 1;
        w->shift_register = ((w->shift_register << 1) | bit0) & 0x7fffff;
        wave_set_noise_output(w);
    }

    if (w->waveform) {
        wave_set_output(w, src, m);
    } else if (waveform_prev) {
        w->floating_output_ttl = (m == SID_MOS6581) ?
            FLOATING_OUTPUT_TTL_START_6581 : FLOATING_OUTPUT_TTL_START_8580;
    }
}

static void wave_reset(sid_voice_t *w)
{
    w->freq = 0;
    w->pw = 0;
    w->msb_rising = 0;
    w->waveform = 0;
    w->test = 0;
    w->ring_mod = 0;
    w->sync = 0;
    w->ring_msb_mask = 0;
    w->no_noise = 0xfff;
    w->no_pulse = 0xfff;
    w->pulse_output = 0xfff;
    w->shift_register = 0x7ffffe;
    w->shift_register_reset = 0;
    wave_set_noise_output(w);
    w->waveform_output = 0;
    w->floating_output_ttl = 0;
    w->recip = 0;
}

/* ------------------------------------------------------------------ chip */

static void filter_coeffs(sid_ref_t *s);
static void filter_write(sid_ref_t *s, unsigned reg, unsigned value);

void sid_ref_reset(sid_ref_t *s, sid_model_t model)
{
    int i;

    memset(s, 0, sizeof *s);
    s->model = model;
    for (i = 0; i < 3; i++) {
        sid_voice_t *v = &s->v[i];
        v->acc = 0x555555;               /* reSID constructor values */
        v->envelope_counter = 0xaa;
        v->next_state = ENV_RELEASE;
        wave_reset(v);
        env_reset(v);
    }
    filter_coeffs(s);
}

void sid_ref_write(sid_ref_t *s, unsigned reg, unsigned value)
{
    int i = (int)(reg / 7);
    sid_voice_t *v;
    const sid_voice_t *src;

    if (reg >= 21 && reg <= 24) { filter_write(s, reg - 21, value & 0xff); return; }
    if (i > 2) return;
    v = &s->v[i];
    src = &s->v[(i + 2) % 3];            /* voice i is hard-synced and ring-modulated by i-1 */
    value &= 0xff;

    switch (reg % 7) {
    case 0: v->freq = (v->freq & 0xff00) | value; break;
    case 1: v->freq = ((value << 8) & 0xff00) | (v->freq & 0x00ff); break;
    case 2:
        v->pw = (v->pw & 0xf00) | value;
        v->pulse_output = ((v->acc >> 12) >= v->pw) ? 0xfff : 0x000;
        break;
    case 3:
        v->pw = ((value << 8) & 0xf00) | (v->pw & 0x0ff);
        v->pulse_output = ((v->acc >> 12) >= v->pw) ? 0xfff : 0x000;
        break;
    case 4:
        wave_write_control(v, src, s->model, value);
        env_write_control(v, value);
        break;
    case 5: env_write_attack_decay(v, value); break;
    case 6: env_write_sustain_release(v, value); break;
    }

    /* DSP: derived by the 68030 when the frequency changes. */
    v->recip = v->freq ? ((uint64_t)1 << 62) / ((uint64_t)v->freq * (uint64_t)SID_CYC_Q24) : 0;
}

static void synchronize(sid_ref_t *s, int i)
{
    sid_voice_t *w = &s->v[i];
    sid_voice_t *dest = &s->v[(i + 1) % 3];
    const sid_voice_t *src = &s->v[(i + 2) % 3];

    if (w->msb_rising && dest->sync && !(w->sync && src->msb_rising))
        dest->acc = 0;
}

/* SID::clock(delta_t) for the voices: envelopes, oscillators split at every
 * msb toggle of a sync source (hard sync must act on the exact cycle), then
 * the waveform outputs. */
static void clock_voices(sid_ref_t *s, int dt)
{
    int i, dt_osc = dt;

    for (i = 0; i < 3; i++) env_clock(&s->v[i], dt);

    while (dt_osc) {
        int dt_min = dt_osc;

        for (i = 0; i < 3; i++) {
            const sid_voice_t *w = &s->v[i];
            uint32_t delta, next;

            if (!(s->v[(i + 1) % 3].sync && w->freq)) continue;
            delta = (w->acc & 0x800000 ? 0x1000000u : 0x800000u) - w->acc;
            next = delta / w->freq;
            if (delta % w->freq) ++next;
            if ((int)next < dt_min) dt_min = (int)next;
        }
        for (i = 0; i < 3; i++) wave_clock(&s->v[i], dt_min);
        for (i = 0; i < 3; i++) synchronize(s, i);
        dt_osc -= dt_min;
    }

    for (i = 0; i < 3; i++)
        wave_set_output_dt(&s->v[i], &s->v[(i + 2) % 3], s->model, dt);
}

/* reSID Voice::output(): (wave DAC - zero level) * envelope DAC. Fits 24 bits
 * signed (|x| < 2^21). DSP: one MPY. */
static int32_t voice_output(const sid_ref_t *s, const sid_voice_t *v)
{
    return ((int32_t)wave_dac[s->model][v->waveform_output] - wave_zero[s->model]) *
           (int32_t)env_dac[s->model][v->envelope_counter];
}

/*
 * 4-point polyBLEP residual for an edge of height `jump` (wave DAC units) at
 * phase `edge`, seen from the sample phase `ph`; result in Q12 DAC units.
 *
 * The distance to the edge in frames is delta / (freq * cycles per frame);
 * the division is a multiply by the per-frequency reciprocal.
 * DSP: sub, abs, mpy by recip (mantissa + shift), compare to 2 frames,
 * table fetch with linear interpolation, mpy by jump.
 */
static int64_t blep(const sid_voice_t *v, uint32_t ph, uint32_t edge, int32_t jump)
{
    int32_t delta = (int32_t)((ph - edge) & 0xffffff);
    uint64_t pos;
    uint32_t idx, frac;
    int32_t t;
    int64_t r;
    int neg = 0;

    if (delta >= 0x800000) delta -= 0x1000000;
    if (delta < 0) { delta = -delta; neg = 1; }

    pos = ((uint64_t)delta * v->recip) >> 24;        /* 1/64 frame, Q8 */
    if (pos >= (uint64_t)(2 * 64) << 8) return 0;    /* beyond +-2 frames */
    idx = (uint32_t)(pos >> 8);
    frac = (uint32_t)(pos & 255);
    t = blep_step[idx] + (int32_t)(((int64_t)(blep_step[idx + 1] - blep_step[idx]) * frac) >> 8);

    r = ((int64_t)jump * t) >> 11;                   /* Q23 -> Q12 */
    return neg ? -r : r;
}

/* Output for the uniform sample instant eps (Q24 cycle fraction) after the
 * voice's integer cycle. Only the single plain waveforms (triangle, saw,
 * pulse) are corrected; noise and combined waveforms have no clean edges and
 * pass through unchanged. */
static int32_t voice_output_bl(const sid_ref_t *s, const sid_voice_t *v, const sid_voice_t *src, uint32_t eps)
{
    const sid_model_t m = s->model;
    uint32_t w = v->waveform, ph, ix, pulse, code;
    int32_t dac;
    int64_t wave_q12;

    if ((w != 1 && w != 2 && w != 4) || v->test || !v->freq)
        return voice_output(s, v);

    /* Phase at the true sample instant: the integer-cycle phase plus freq * eps. */
    ph = (v->acc + (uint32_t)(((uint64_t)v->freq * eps) >> 24)) & 0xffffff;

    ix = (ph ^ (~src->acc & v->ring_msb_mask)) >> 12;
    pulse = ((ph >> 12) >= v->pw) ? 0xfff : 0x000;
    code = wave_table[m][w][ix] & (v->no_pulse | pulse) & v->no_noise_or_noise_output;
    dac = (int32_t)wave_dac[m][code] - wave_zero[m];
    wave_q12 = (int64_t)dac << 12;

    if (w == 2) {
        wave_q12 += blep(v, ph, 0, (int32_t)wave_dac[m][0] - (int32_t)wave_dac[m][0xfff]);
    } else if (w == 4 && v->pw != 0) {
        int32_t jump = (int32_t)wave_dac[m][0xfff] - (int32_t)wave_dac[m][0];
        wave_q12 += blep(v, ph, v->pw << 12, jump);       /* rising edge */
        wave_q12 += blep(v, ph, 0, -jump);                /* falling edge at the wrap */
    }

    return (int32_t)((wave_q12 * (int32_t)env_dac[m][v->envelope_counter]) >> 12);
}


/* ------------------------------------------------- filter, mixer, external */

/*
 * The filter, mixer and external filter in exactly the arithmetic of the DSP
 * kernel (src/dsp/sid.asm.in): 24-bit coefficient words, 24x24 multiplies into
 * the 56-bit accumulator (MPY: 2*a*b), 48-bit states (Q24: a1 = integer part,
 * a0 = fraction). Every step below is one DSP instruction group; shifts are
 * arithmetic (floor). `lim` is the accumulator's limiter, applied when a 56-bit
 * accumulator is read as a 24-bit word.
 *
 * Gain staging is calibrated on reSID (tools/ref/mix_cal.c, oracle_resid cal).
 */
#define MIX_K23_6581      3491          /* voice units * volume -> 16-bit chip scale, Q23 */
#define MIX_K23_8580      1586
#define FILTER_GAIN       4194304       /* filter path gain, Q22: 1.0 (undoes the headroom shift); the gain of
                                         * each output against a voice routed past the filter is fitted per
                                         * cutoff and comes with the coefficients (wl, wb, wh) */
#define EXT_LP_W          5182881       /* external 15.9 kHz low-pass, g/(1+g), Q23 */
#define EXT_HP_W          8522          /* external 15.9 Hz high-pass */

static const int32_t mix_k23[2]      = { MIX_K23_6581, MIX_K23_8580 };

void sid_mix_config(sid_model_t model, int32_t *hp_cancel, int32_t *mix_k, int32_t *filter_gain)
{
    *hp_cancel = 0x7fffff;                          /* reserved */
    *mix_k = mix_k23[model];
    *filter_gain = FILTER_GAIN;
}

/* MPY / MAC product of two 24-bit words, fractional mode. */
static inline int64_t mpy(int32_t a, int32_t b) { return 2 * (int64_t)a * (int64_t)b; }

/* Read a 56-bit accumulator as a 24-bit word (a1, saturated by the limiter). */
static inline int32_t lim(int64_t acc)
{
    int64_t v = acc >> 24;

    return (int32_t)(v > 0x7fffff ? 0x7fffff : v < -0x800000 ? -0x800000 : v);
}

/*
 * Host side (68030): the coefficient words from fc and res, by table lookup
 * and integer arithmetic only: no divide (1/x comes from a table with linear
 * interpolation) and the products that depend on fc alone are tabulated
 * (g, g*g, g*k0). Everything is Q21 until the words are formed.
 *
 *   D  = 1 + g*g + g*k0*kr            a1 = 1/D        a2 = g*a1      a3 = g*g*a1
 *   k4 = k/4 = k0*kr/4
 * The gains of the three outputs and the low-pass share in the high-pass output
 * depend on the cutoff alone and are read from the tables.
 */
void sid_filter_coeffs(sid_model_t model, unsigned fc, unsigned res, sid_filter_coeffs_t *c)
{
    const uint64_t kr = filter_kr_q21[model][res];
    const uint64_t g = filter_g_q21[model][fc];
    const uint64_t g2 = filter_g2_q21[model][fc];
    const uint64_t gk = (filter_gk0_q21[model][fc] * kr) >> 21;
    const uint64_t k = (filter_k0_q21[model][fc] * kr) >> 21;
    uint64_t d = (1u << 21) + g2 + gk, m, a1, a2, a3, r, frac;
    unsigned idx, e = 0;

    while ((d >> e) >= (2u << 21)) e++;                 /* d = m * 2^e, m in [1, 2) Q21 */
    m = d >> e;
    idx = (unsigned)((m - (1u << 21)) >> 13);           /* 8 bits */
    frac = (m - (1u << 21)) & 0x1fff;                   /* 13 bits */
    r = filter_recip_q24[idx] - (((uint64_t)(filter_recip_q24[idx] - filter_recip_q24[idx + 1]) * frac) >> 13);
    a1 = r >> e;                                        /* Q24 */
    a2 = (g * a1) >> 22;                                /* Q21 * Q24 -> Q23 */
    a3 = (g2 * a1) >> 22;
    a1 >>= 1;
    c->a1 = (int32_t)(a1 > 0x7fffff ? 0x7fffff : a1);
    c->a2 = (int32_t)(a2 > 0x7fffff ? 0x7fffff : a2);
    c->a3 = (int32_t)(a3 > 0x7fffff ? 0x7fffff : a3);
    c->k4 = (int32_t)k;                                 /* k/4 in Q23 is k in Q21 */
    c->wl = filter_wl_q22[model][fc];                   /* the outputs' gains: per cutoff, from the tables */
    c->wb = filter_wb_q22[model][fc];
    c->wh = filter_wh_q22[model][fc];
    c->wleak = filter_wleak_q22[model][fc];
}

static void filter_coeffs(sid_ref_t *s)
{
    sid_filter_coeffs(s->model, s->flt.fc, s->flt.res, &s->flt.c);
}

static void filter_write(sid_ref_t *s, unsigned reg, unsigned value)
{
    sid_filter_t *f = &s->flt;

    switch (reg) {
    case 0: f->fc = (f->fc & 0x7f8) | (value & 7); filter_coeffs(s); break;
    case 1: f->fc = ((value << 3) & 0x7f8) | (f->fc & 7); filter_coeffs(s); break;
    case 2: f->res = value >> 4; f->filt = value & 0x0f; filter_coeffs(s); break;
    case 3: f->mode = value >> 4; f->vol = value & 0x0f; break;
    }
}

/* One-pole TPT low-pass on a Q24 state, coefficient word w (g/(1+g), Q23).
 * Only the integer part of the difference is multiplied (one MPY). */
static int64_t onepole(int64_t *state, int64_t x, int32_t w)
{
    int64_t v = mpy(w, (int32_t)((x - *state) >> 24));
    int64_t y = *state + v;

    *state = y + v;
    return y;
}

/* Mix the three voice outputs: routed voices through the SVF, the rest past
 * it, times the volume, then the external filter; 16-bit chip output scale. */
static int32_t mix_output(const sid_ref_t *s, sid_filter_state_t *st, const int32_t vo[3])
{
    const sid_filter_t *f = &s->flt;
    const sid_filter_coeffs_t *c = &f->c;
    int32_t direct = 0, xs = 0, x, s1h, v3h, v1h, v2h, hph, t, mixed, ml, mb, mh;
    int64_t xa, h3, v1, v2, hp, acc, y, y2;
    int i;

    for (i = 0; i < 3; i++) {
        if (f->filt & (1 << i)) xs += vo[i];
        else if (!(i == 2 && (f->mode & 8))) direct += vo[i];       /* voice 3 off */
    }
    x = xs >> 2;                                    /* headroom for the resonance peak */
    if (!(f->filt & 7)) st->s1 = st->s2 = 0;        /* nothing routed: the integrators are idle (the DSP skips them) */

    /* TPT state-variable filter (Zavalishin), states Q24. */
    xa = (int64_t)x << 24;
    h3 = xa - st->s2;
    v3h = (int32_t)(h3 >> 24);
    s1h = (int32_t)(st->s1 >> 24);
    v1 = mpy(c->a1, s1h) + mpy(c->a2, v3h);
    v2 = st->s2 + mpy(c->a2, s1h) + mpy(c->a3, v3h);
    st->s1 = 2 * v1 - st->s1;
    st->s2 = 2 * v2 - st->s2;
    v1h = (int32_t)(v1 >> 24);
    v2h = (int32_t)(v2 >> 24);
    hp = xa - 4 * mpy(c->k4, v1h) - ((int64_t)v2h << 24);
    hph = (int32_t)(hp >> 24);

    /* The selected outputs, each with its fitted gain (words hold gain / 2); the
     * high-pass output carries a share of the low-pass. DSP: the three weights are
     * set when the mode or the coefficients change. */
    ml = ((f->mode & 1) ? c->wl : 0) + ((f->mode & 4) ? c->wleak : 0);
    mb = (f->mode & 2) ? c->wb : 0;
    mh = (f->mode & 4) ? c->wh : 0;
    acc = 2 * (mpy(ml, v2h) + mpy(mb, v1h) + mpy(mh, hph));
    t = lim(acc);

    acc = ((int64_t)direct << 24) + 8 * mpy(FILTER_GAIN, t);
    mixed = lim(acc);

    acc = mpy(mixed, (int32_t)f->vol * mix_k23[s->model]);            /* Q24, 16-bit chip scale */

    /* external filter: vo = lp(16 kHz)(mixed) - lp(16 Hz)(lp(16 kHz)(mixed)) */
    y = onepole(&st->xl, acc, EXT_LP_W);
    y2 = onepole(&st->xh, y, EXT_HP_W);
    return (int32_t)((y - y2 + (1 << 23)) >> 24);
}

void sid_ref_frame(sid_ref_t *s, sid_frame_t *f)
{
    int i;

    f->n = sid_frame_step(&s->eps);
    f->eps = s->eps;
    clock_voices(s, f->n);
    for (i = 0; i < 3; i++) {
        f->naive[i] = voice_output(s, &s->v[i]);
        f->bl[i] = voice_output_bl(s, &s->v[i], &s->v[(i + 2) % 3], s->eps);
    }
    f->mix = mix_output(s, &s->st[0], f->naive);
    f->mix_bl = mix_output(s, &s->st[1], f->bl);
}
