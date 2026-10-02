/*
 * F030SID reference model: SID voices at the Falcon codec rate.
 *
 * A frame-rate (49,169.921875 Hz) model of the three SID voices written in
 * the integer arithmetic a DSP56001 has: 24-bit words, with explicit 48/56-bit
 * products only where the DSP has them. It is the specification the DSP code
 * is transliterated from and is gated against reSID (third_party/resid).
 *
 * Two outputs per frame:
 *
 *   naive  The voice exactly as reSID's Voice::output() reads at the frame's
 *          integer SID cycle. Bit-identical to reSID clocked with
 *          SID::clock(n) frame by frame (tools/ref/voice_gate.py).
 *   bl     The same voice made fit for the uniform 49.17 kHz grid:
 *            - the waveform is evaluated at the true sample instant, a
 *              fraction `eps` of a SID cycle after the integer cycle (the
 *              grid is 20.0376 cycles per frame, so the instants jitter);
 *            - saw and pulse edges are band-limited with a 4-point polyBLEP.
 *          The state (phase, LFSR, envelope) is unaffected; bl is purely an
 *          output-stage correction.
 *
 * The voice logic follows reSID's bulk clocking (clock(delta_t)), not its
 * single-cycle pipeline model: see README.md in this directory for the exact
 * list of what is and is not modelled.
 */
#ifndef SID_REF_H
#define SID_REF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SID_CLOCK_HZ     985248LL                     /* PAL */
#define SID_CODEC_NUM    25175000LL                   /* codec rate = NUM/DEN */
#define SID_CODEC_DEN    512LL                        /* prescale 1: 49,169.921875 Hz */

/* SID cycles per output frame in Q24 (20.0376...), rounded. */
#define SID_CYC_Q24 \
    ((((SID_CLOCK_HZ * SID_CODEC_DEN) << 24) + SID_CODEC_NUM / 2) / SID_CODEC_NUM)

/*
 * Frame clock. eps is the Q24 fraction of a SID cycle by which the sample
 * instant lies after the integer cycle count; one 24-bit add per frame, and
 * the carry says whether this frame is 21 cycles instead of 20.
 * Returns the cycles in this frame and advances *eps to the frame's end.
 */
static inline int sid_frame_step(uint32_t *eps)
{
    uint32_t sum = *eps + (uint32_t)(SID_CYC_Q24 & 0xffffff);
    *eps = sum & 0xffffff;
    return (int)(SID_CYC_Q24 >> 24) + (int)(sum >> 24);
}

typedef enum { SID_MOS6581 = 0, SID_MOS8580 = 1 } sid_model_t;

typedef enum { ENV_ATTACK, ENV_DECAY_SUSTAIN, ENV_RELEASE, ENV_FREEZED } sid_env_state_t;

typedef struct {
    /* oscillator */
    uint32_t acc;                 /* 24-bit phase at the frame's integer cycle */
    uint32_t freq;                /* 16 bit */
    uint32_t pw;                  /* 12 bit */
    uint32_t shift_register;      /* 23-bit noise LFSR */
    int32_t  shift_register_reset;
    uint32_t ring_msb_mask;
    uint32_t no_noise, noise_output, no_noise_or_noise_output;
    uint32_t no_pulse, pulse_output;
    uint32_t waveform_output;     /* 12-bit chip code */
    int32_t  floating_output_ttl;
    uint32_t waveform;            /* control bits 7..4 */
    uint32_t test, ring_mod, sync;
    int      msb_rising;
    /* envelope */
    uint32_t rate_counter, rate_period;
    uint32_t exponential_counter, exponential_counter_period;
    uint32_t envelope_counter;
    int      hold_zero;
    int      state_pipeline;
    sid_env_state_t state, next_state;
    uint32_t attack, decay, sustain, release;
    uint32_t gate;
    /* derived on a frequency write (host side on the DSP) */
    uint64_t recip;               /* 2^62 / (freq * SID_CYC_Q24), 0 if freq == 0 */
} sid_voice_t;

typedef struct {
    sid_model_t model;
    sid_voice_t v[3];
    uint32_t eps;                 /* Q24 sample-instant fraction, see sid_frame_step */
} sid_ref_t;

typedef struct {
    int      n;                   /* SID cycles in this frame (20 or 21) */
    uint32_t eps;                 /* Q24 */
    int32_t  naive[3];            /* reSID Voice::output() units, about +-2^21 */
    int32_t  bl[3];               /* band-limited, same units */
} sid_frame_t;

/* Load reSID's combined-waveform data (wave*.dat in resid_dir) and build the
 * DAC and polyBLEP tables. Returns 0 on success. */
int  sid_tables_init(const char *resid_dir);

/* The tables the DSP is given (valid after sid_tables_init). */
const uint16_t *sid_tab_wave_dac(sid_model_t model);   /* 4096 entries */
const uint16_t *sid_tab_env_dac(sid_model_t model);    /* 256 entries */
const uint16_t *sid_tab_rate_period(void);             /* 16 entries */
const uint8_t  *sid_tab_sustain_level(void);           /* 16 entries */
int32_t sid_wave_zero(sid_model_t model);
int32_t sid_floating_ttl_start(sid_model_t model);

void sid_ref_reset(sid_ref_t *s, sid_model_t model);

/* Register write, reg 0..20 (voice 1 = 0..6, voice 2 = 7..13, voice 3 = 14..20). */
void sid_ref_write(sid_ref_t *s, unsigned reg, unsigned value);

/* Advance one codec frame and produce the voice outputs at its end. */
void sid_ref_frame(sid_ref_t *s, sid_frame_t *f);

#ifdef __cplusplus
}
#endif

#endif
