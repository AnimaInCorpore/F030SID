VASM_ARCHIVE := third_party/f030dsp3d/tools/vasm.tar.gz
VLINK_ARCHIVE := third_party/f030dsp3d/tools/vlink.tar.gz
DSP_TOOL_SOURCE := third_party/f030dsp3d/tools/asm56k
RESID_SOURCE := third_party/resid

TOOLS_DIR := build/tools
VASM_DIR := $(TOOLS_DIR)/vasm
VLINK_DIR := $(TOOLS_DIR)/vlink
VASM := $(VASM_DIR)/vasmm68k_mot
VLINK := $(VLINK_DIR)/vlink

# vlink's vendored dir.c calls chmod() from its _WIN32 branch without a
# declaration; GCC 14+ rejects that. gnu99 plus a forced io.h supplies it.
# Only needed on Windows hosts.
HOST_UNAME := $(shell uname -s)
ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(HOST_UNAME)))
VLINK_MAKE_ARGS := COPTS="-std=gnu99 -O2 -fomit-frame-pointer -c -include io.h"
endif

M68K_BUILD := build/m68k
DSP_BUILD := build/dsp
GENERATED_BUILD := build/generated
RELEASE_DIR := release

DSP_STAGE2_IMAGE := $(GENERATED_BUILD)/dsp_stage2_image.i
RATETEST_BOOT_IMAGE := $(GENERATED_BUILD)/ratetest_boot.i
DSPPROBE_BOOT_IMAGE := $(GENERATED_BUILD)/dspprobe_boot.i

M68K_SOURCES := \
	src/m68k/main.s
M68K_OBJECTS := $(patsubst src/m68k/%.s,$(M68K_BUILD)/%.o,$(M68K_SOURCES))

# Machine-specific paths (DOSBOX, HATARI, PYTHON, ...) go in local.mk, which git ignores.
-include local.mk

DOSBOX ?= $(shell command -v dosbox-staging 2>/dev/null || command -v dosbox 2>/dev/null)
DOSBOX_FLAGS ?= --noprimaryconf --set output=texture

# Hatari selection. Stock Hatari runs the Falcon DSP at twice the hardware
# clock, so real-time results need the DSP-calibrated build from the
# F030Arcade tree; see docs/hatari-timing.md. Override either variable:
#   make <target> F030ARCADE=/path/to/F030Arcade
#   make <target> HATARI=/path/to/hatari
# Keep the candidate search in step with tools/hatari_binary.py.
F030ARCADE ?= $(HOME)/Work/F030Arcade
HATARI_ROOTS := $(F030ARCADE) $(abspath $(CURDIR)/../F030Arcade)
HATARI_CANDIDATES := $(foreach root,$(HATARI_ROOTS),$(foreach build,build build-ucrt64,\
	$(root)/third_party/hatari/$(build)/src/hatari \
	$(root)/third_party/hatari/$(build)/src/hatari.exe))
HATARI_CALIBRATED := $(firstword $(wildcard $(HATARI_CANDIDATES)))
HATARI ?= $(firstword $(HATARI_CALIBRATED) hatari)

# Hatari splits the program argument into a GEMDOS directory and a filename
# using the host's separator, so every target cd's into the program's own
# directory and passes a bare filename.
define require_hatari
	@if ! command -v $(HATARI) >/dev/null 2>&1; then \
		echo "error: $(1) target needs Hatari ($(HATARI))" >&2; \
		exit 1; \
	fi
	@if [ "$(abspath $(HATARI))" != "$(abspath $(HATARI_CALIBRATED))" ]; then \
		echo "warning: $(HATARI) is not the DSP-calibrated build; real-time" >&2; \
		echo "         results will describe a 32 MIPS DSP - see docs/hatari-timing.md" >&2; \
	fi
endef

# --- reference model and reSID oracle (host tools) -------------------------

HOST_CC ?= gcc
HOST_CXX ?= g++
ifeq ($(HOST_UNAME),Darwin)
HOST_STATIC ?=           # macOS has no static libc
else
HOST_STATIC ?= -static
endif
PERL ?= perl
PYTHON ?= python3
REF_BUILD := build/ref
RESID_DIR := third_party/resid
RESID_GEN := $(REF_BUILD)/resid-gen
RESID_SOURCES := sid.cc voice.cc wave.cc envelope.cc filter8580new.cc dac.cc \
	extfilt.cc pot.cc version.cc
RESID_TABLES := wave6581_PST wave6581_PS_ wave6581_P_T wave6581__ST \
	wave8580_PST wave8580_PS_ wave8580_P_T wave8580__ST
REF_EXE := $(if $(filter MINGW% MSYS% CYGWIN%,$(HOST_UNAME)),.exe,)

.PHONY: all help host dsp check run clean tools ratetest-hatari dspprobe-hatari smoke profile-sid \
	ref ref-gate filter-gate dsp-gate stream-gate cpu-gate cpu-ref-check coef-gate play-gate \
	package package-gate tune-check tune-gate

ref: $(REF_BUILD)/ref_run$(REF_EXE) $(REF_BUILD)/oracle_resid$(REF_EXE)

# reSID's siddefs.h.in is an autoconf template; fill it for a plain C++11 build.
$(RESID_GEN)/siddefs.h: $(RESID_DIR)/siddefs.h.in
	@mkdir -p $(RESID_GEN)
	sed -e 's/@RESID_INLINING@/1/; s/@RESID_INLINE@/inline/' \
		-e 's/@RESID_BRANCH_HINTS@/1/; s/@NEW_8580_FILTER@/1/' \
		-e 's/@HAVE_BOOL@/1/; s/@HAVE_BUILTIN_EXPECT@/1/; s/@HAVE_LOG1P@/1/' $< > $@

$(RESID_GEN)/%.h: $(RESID_DIR)/%.dat
	@mkdir -p $(RESID_GEN)
	$(PERL) $(RESID_DIR)/samp2src.pl $* $< $@

$(REF_BUILD)/oracle_resid$(REF_EXE): tools/ref/oracle_resid.cc src/ref/sid_ref.h \
		$(RESID_GEN)/siddefs.h $(addprefix $(RESID_GEN)/,$(addsuffix .h,$(RESID_TABLES)))
	@mkdir -p $(REF_BUILD)
	$(HOST_CXX) -O2 $(HOST_STATIC) -std=gnu++11 -w -I$(RESID_GEN) -I$(RESID_DIR) -Isrc/ref \
		-DVERSION='"1.0"' $(addprefix $(RESID_DIR)/,$(RESID_SOURCES)) $< -o $@

$(REF_BUILD)/ref_run$(REF_EXE): tools/ref/ref_run.c src/ref/sid_ref.c src/ref/sid_ref.h
	@mkdir -p $(REF_BUILD)
	$(HOST_CC) -O2 $(HOST_STATIC) -std=c99 -Wall -Wextra -Isrc/ref src/ref/sid_ref.c $< -o $@ -lm

# Bit-exactness against reSID and band-limiting against the per-cycle chip.
ref-gate: ref
	$(PYTHON) tools/ref/voice_gate.py --build $(REF_BUILD) | tee $(REF_BUILD)/gate-results.txt

# The reference filter/mixer against reSID by spectrum (not bit-exact: reSID
# integrates an analog model at 1 MHz). Needs numpy and scipy.
filter-gate: ref
	$(PYTHON) tools/ref/filter_gate.py --build $(REF_BUILD) | tee $(REF_BUILD)/filter-gate-results.txt

# The DSP kernel against the C reference, bit for bit, under Hatari: each trace
# becomes a test vector, the m68k harness replays it through the kernel, and the
# DSP's output words must equal the reference model's. DSP_GATE_ARGS=--quick runs
# two traces; trace names after it select others.
$(REF_BUILD)/make_vec$(REF_EXE): tools/dsp/make_vec.c src/ref/sid_ref.c src/ref/sid_ref.h
	@mkdir -p $(REF_BUILD)
	$(HOST_CC) -O2 $(HOST_STATIC) -std=c99 -Wall -Wextra -Isrc/ref src/ref/sid_ref.c $< -o $@ -lm

dsp-gate: all $(REF_BUILD)/make_vec$(REF_EXE)
	$(call require_hatari,dsp-gate)
	$(PYTHON) tools/dsp/voice_dsp_gate.py --build build --make-vec $(REF_BUILD)/make_vec$(REF_EXE) \
		--vasm $(VASM)$(REF_EXE) --vlink $(VLINK)$(REF_EXE) --hatari $(HATARI) \
		--tos third_party/f030dsp3d/tools/tos402.rom --vbls 6000 $(DSP_GATE_ARGS) | tee build/dsp-gate-results.txt

# The kernel's SSI stream under Hatari: the same traces played through the
# transmitter with cycle-stamped writes, bit-identical to the reference and in
# real time (STREAM_GATE_ARGS=--stress adds the stress traces).
stream-gate: all $(REF_BUILD)/make_vec$(REF_EXE)
	$(call require_hatari,stream-gate)
	$(PYTHON) tools/dsp/stream_gate.py --build build --make-vec $(REF_BUILD)/make_vec$(REF_EXE) \
		--vasm $(VASM)$(REF_EXE) --vlink $(VLINK)$(REF_EXE) --hatari $(HATARI) \
		--tos third_party/f030dsp3d/tools/tos402.rom $(STREAM_GATE_ARGS) | tee build/stream-gate-results.txt

# --- sidtrace: PSID -> cycle-stamped SID register trace ------------------------
# Taps the register stream of libsidplayfp's own player. It derives from
# libsidplayfp's internal sidemu class, so it needs the matching source tree:
# the release tarball is fetched (checksum-pinned) and built as a static library.

LSFP_VERSION := 2.16.1
LSFP_SHA256 := ace0f73c2ef8645ab069ce1b298b10e31e36af7b5996109983b2b67ad60ff3ca
LSFP_URL := https://github.com/libsidplayfp/libsidplayfp/releases/download/v$(LSFP_VERSION)/libsidplayfp-$(LSFP_VERSION).tar.gz
LSFP_TAR := build/dl/libsidplayfp-$(LSFP_VERSION).tar.gz
LSFP_SRC := build/dl/libsidplayfp-$(LSFP_VERSION)/src
LSFP_BUILD := build/lsfp
LSFP_LIB := $(LSFP_BUILD)/src/.libs/libsidplayfp.a

.PHONY: trace trace-test

trace: $(LSFP_BUILD)/sidtrace$(REF_EXE)

$(LSFP_TAR):
	@mkdir -p build/dl
	curl -fsSL -o $@ $(LSFP_URL)
	echo "$(LSFP_SHA256)  $@" | sha256sum -c -

$(LSFP_SRC)/../configure: $(LSFP_TAR)
	tar -xzf $< -C build/dl
	@touch $@

# libsidplayfp's configure needs a POSIX shell with a working expr; from a
# non-login Git-bash it fails with "invalid feature name", from an MSYS2 login
# shell (bash -lc) it is fine.
$(LSFP_LIB): $(LSFP_SRC)/../configure
	@mkdir -p $(LSFP_BUILD)
	cd $(LSFP_BUILD) && $(CURDIR)/$(LSFP_SRC)/../configure --disable-shared --enable-static \
		--without-gcrypt --without-usbsid --without-exsid CXXFLAGS=-O2
	$(MAKE) -C $(LSFP_BUILD)

$(LSFP_BUILD)/sidtrace$(REF_EXE): tools/trace/sidtrace.cc $(LSFP_LIB)
	$(HOST_CXX) -O2 -std=gnu++17 -DHAVE_CONFIG_H -I$(LSFP_SRC) \
		-I$(LSFP_SRC)/builders/residfp-builder -I$(LSFP_SRC)/builders/residfp-builder/residfp \
		-I$(LSFP_BUILD)/src -I$(LSFP_BUILD)/src/builders/residfp-builder/residfp \
		$< $(LSFP_LIB) -o $@

# Self-test: trace the hand-assembled tunes and check the timestamps.
trace-test: trace
	$(PYTHON) tools/trace/make_test_sid.py
	$(LSFP_BUILD)/sidtrace$(REF_EXE) -t 1 -o $(LSFP_BUILD)/test_pulse.trace tests/psid/test_pulse.sid
	$(LSFP_BUILD)/sidtrace$(REF_EXE) -t 1 -o $(LSFP_BUILD)/test_2sid.trace tests/psid/test_2sid.sid
	$(PYTHON) tools/trace/check_traces.py $(LSFP_BUILD) $(REF_BUILD)

all: host dsp

help:
	@echo "Build targets:"
	@echo "  all              build the Falcon executables and DSP image"
	@echo "  check            build everything and validate the assembler listings"
	@echo "  package          build release/F030SID.ZIP (player, demo tune, README.TXT)"
	@echo "  run              launch f030sid.tos in Hatari"
	@echo "  ratetest-hatari  run the physical-Falcon SSI rate test under Hatari"
	@echo "  dspprobe-hatari  run the physical-Falcon DSP bus probe under Hatari"
	@echo "  clean            remove generated build/ and release/ directories"

host: $(RELEASE_DIR)/f030sid.tos $(RELEASE_DIR)/f030sid.ttp \
		$(RELEASE_DIR)/ratetest.tos $(RELEASE_DIR)/dspprobe.tos $(RELEASE_DIR)/sidmenu.tos

dsp: $(RELEASE_DIR)/sid.lod

tools: $(VASM) $(VLINK)

$(TOOLS_DIR)/.vasm-unpacked: $(VASM_ARCHIVE)
	@mkdir -p $(TOOLS_DIR)
	tar -xf $< -C $(TOOLS_DIR)
	@touch $@

$(VASM): $(TOOLS_DIR)/.vasm-unpacked
	$(MAKE) -C $(VASM_DIR) CPU=m68k SYNTAX=mot

$(TOOLS_DIR)/.vlink-unpacked: $(VLINK_ARCHIVE)
	@mkdir -p $(TOOLS_DIR)
	tar -xf $< -C $(TOOLS_DIR)
	@touch $@

$(VLINK): $(TOOLS_DIR)/.vlink-unpacked
	$(MAKE) -C $(VLINK_DIR) $(VLINK_MAKE_ARGS)

# --- DSP56001 -------------------------------------------------------------

$(DSP_BUILD)/BUILD.BAT: tools/BUILD_DSP.BAT src/dsp/sid.asm.in tools/dsp/gen_sid_asm.py src/dsp/protocol.inc \
		src/dsp/stage2_loader.asm src/dsp/ratetest.asm src/dsp/dspprobe.asm
	@mkdir -p $(DSP_BUILD)
	cp tools/BUILD_DSP.BAT $(DSP_BUILD)/BUILD.BAT
	python3 tools/dsp/gen_sid_asm.py src/dsp/sid.asm.in $(DSP_BUILD)/SID.ASM
	cp src/dsp/stage2_loader.asm $(DSP_BUILD)/SIBOOT.ASM
	cp src/dsp/protocol.inc $(DSP_BUILD)/
	cp src/dsp/ratetest.asm $(DSP_BUILD)/RATETEST.ASM
	cp src/dsp/dspprobe.asm $(DSP_BUILD)/DSPPROBE.ASM
	cp $(DSP_TOOL_SOURCE)/ASM56000.EXE $(DSP_TOOL_SOURCE)/CLDLOD.EXE \
		$(DSP_TOOL_SOURCE)/DOS4GW.EXE $(DSP_TOOL_SOURCE)/ioequ.inc $(DSP_BUILD)/
	@touch $@

$(DSP_BUILD)/.assembled: $(DSP_BUILD)/BUILD.BAT
	@if [ -z "$(DOSBOX)" ]; then \
		echo "error: DSP build needs dosbox-staging or dosbox" >&2; \
		exit 1; \
	fi
	@rm -f $(DSP_BUILD)/*.CLD $(DSP_BUILD)/*.LOD $(DSP_BUILD)/*.LST
	"$(DOSBOX)" $(DOSBOX_FLAGS) "$(abspath $(DSP_BUILD)/BUILD.BAT)"
	@test -s $(DSP_BUILD)/SID.LOD
	@test -s $(DSP_BUILD)/SIBOOT.LOD
	@test -s $(DSP_BUILD)/RATETEST.LOD
	@test -s $(DSP_BUILD)/DSPPROBE.LOD
	@touch $@

$(RELEASE_DIR)/sid.lod: $(DSP_BUILD)/.assembled
	@mkdir -p $(RELEASE_DIR)
	cp $(DSP_BUILD)/SID.LOD $@

# 512-word bootstrap plus the sparse program (internal P, then external P up to
# P:$1c00, where external Y tables begin to alias); see docs/dsp-kernel.md.
$(DSP_STAGE2_IMAGE): tools/generate_dsp_stage2.py $(DSP_BUILD)/.assembled
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_dsp_stage2.py --bootstrap $(DSP_BUILD)/SIBOOT.LOD \
		--program $(DSP_BUILD)/SID.LOD --program-limit 0x1c00 > $@

$(RATETEST_BOOT_IMAGE): tools/generate_dsp_stage2.py $(DSP_BUILD)/.assembled
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_dsp_stage2.py --standalone $(DSP_BUILD)/RATETEST.LOD \
		--prefix ratetest > $@

$(DSPPROBE_BOOT_IMAGE): tools/generate_dsp_stage2.py $(DSP_BUILD)/.assembled
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_dsp_stage2.py --standalone $(DSP_BUILD)/DSPPROBE.LOD \
		--prefix dspprobe > $@

# --- 68030 ----------------------------------------------------------------

$(M68K_BUILD)/main.o: src/m68k/main.s src/m68k/xbios.i src/m68k/verbose.i \
		src/m68k/protocol.i $(DSP_STAGE2_IMAGE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/main.lst

$(M68K_BUILD)/ratetest.o: src/m68k/ratetest.s src/m68k/xbios.i \
		$(RATETEST_BOOT_IMAGE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/ratetest.lst

$(M68K_BUILD)/sidmenu.o: src/m68k/sidmenu.s src/m68k/xbios.i $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -o $@ -L $(M68K_BUILD)/sidmenu.lst

$(M68K_BUILD)/dspprobe.o: src/m68k/dspprobe.s src/m68k/xbios.i \
		$(DSPPROBE_BOOT_IMAGE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/dspprobe.lst

# No -tos-fastload: the loader must clear the TPA, since player state assumes
# zero-initialized BSS.
$(RELEASE_DIR)/f030sid.tos: $(M68K_OBJECTS) $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $(M68K_OBJECTS) -b ataritos -s -e start -o $@

# --- the player (docs/player.md) --------------------------------------------
# One opcode table for the C reference core and the 68030 core; the DSP and
# filter tables per chip model as binaries the player carries.
PLAYER_OPS := $(GENERATED_BUILD)/cpu6502_ops.i
PLAYER_TABLES := $(GENERATED_BUILD)/sidtab.i

$(PLAYER_OPS): tools/player/gen_6502.py
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/player/gen_6502.py $(GENERATED_BUILD)/cpu6502_tab.h $@

$(REF_BUILD)/psidref$(REF_EXE): tools/player/psidref.c $(PLAYER_OPS)
	@mkdir -p $(REF_BUILD)
	$(HOST_CC) -O2 $(HOST_STATIC) -std=c99 -Wall -Wextra -I$(GENERATED_BUILD) $< -o $@

$(REF_BUILD)/gen_player_tables$(REF_EXE): tools/player/gen_player_tables.c src/ref/sid_ref.c src/ref/sid_ref.h src/ref/filter_tables.h
	@mkdir -p $(REF_BUILD)
	$(HOST_CC) -O2 $(HOST_STATIC) -std=c99 -Wall -Wextra -Isrc/ref src/ref/sid_ref.c $< -o $@ -lm

$(REF_BUILD)/coefref$(REF_EXE): tools/player/coefref.c src/ref/sid_ref.c src/ref/sid_ref.h src/ref/filter_tables.h
	@mkdir -p $(REF_BUILD)
	$(HOST_CC) -O2 $(HOST_STATIC) -std=c99 -Wall -Wextra -Isrc/ref src/ref/sid_ref.c $< -o $@ -lm

$(PLAYER_TABLES): $(REF_BUILD)/gen_player_tables$(REF_EXE)
	@mkdir -p $(GENERATED_BUILD)
	$(REF_BUILD)/gen_player_tables$(REF_EXE) $(RESID_DIR) $(GENERATED_BUILD)

$(M68K_BUILD)/player.o: src/m68k/player.s src/m68k/cpu6502.s src/m68k/psid.s src/m68k/filtcoef.s \
		src/m68k/xbios.i src/m68k/protocol.i $(PLAYER_OPS) $(PLAYER_TABLES) $(DSP_STAGE2_IMAGE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/player.lst

$(RELEASE_DIR)/f030sid.ttp: $(M68K_BUILD)/player.o $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $< -b ataritos -s -e start -o $@

GATE_TOOLS = --vasm $(VASM)$(REF_EXE) --vlink $(VLINK)$(REF_EXE) --hatari $(HATARI) \
	--tos third_party/f030dsp3d/tools/tos402.rom

# The 68030 6510 core against the C reference: the test tunes and the opcode exercisers.
cpu-gate: $(REF_BUILD)/psidref$(REF_EXE) $(PLAYER_OPS) $(VASM) $(VLINK)
	$(call require_hatari,cpu-gate)
	$(PYTHON) tools/player/make_exerciser.py build/cpu 6
	$(PYTHON) tools/player/cpu_gate.py --build build --psidref $(REF_BUILD)/psidref$(REF_EXE) $(GATE_TOOLS) $(CPU_GATE_ARGS)

# The C reference core against libsidplayfp's 6510 (needs `make trace`).
cpu-ref-check: $(REF_BUILD)/psidref$(REF_EXE) trace
	$(PYTHON) tools/player/make_exerciser.py build/cpu 6
	$(PYTHON) tools/player/check_portable.py $(REF_BUILD)/psidref$(REF_EXE) $(LSFP_BUILD)/sidtrace$(REF_EXE) build/cpu/portable_*.sid

# The 68030 filter coefficient routine against the C one.
coef-gate: $(REF_BUILD)/coefref$(REF_EXE) $(PLAYER_TABLES) $(VASM) $(VLINK)
	$(call require_hatari,coef-gate)
	$(PYTHON) tools/player/coef_gate.py --build build --coefref $(REF_BUILD)/coefref$(REF_EXE) $(GATE_TOOLS)

# The player end to end: PSID in, the DSP's frames bit-identical to the references, in real time.
play-gate: all $(REF_BUILD)/psidref$(REF_EXE) $(REF_BUILD)/make_vec$(REF_EXE)
	$(call require_hatari,play-gate)
	@mkdir -p build/play
	$(PYTHON) tools/player/make_trace_sid.py tests/traces/voice_music_1.trace build/play/music_1.sid "F030SID music 1"
	$(PYTHON) tools/player/make_trace_sid.py tests/traces/voice_music_2.trace build/play/music_2.sid "F030SID music 2"
	$(PYTHON) tools/player/play_gate.py --build build --psidref $(REF_BUILD)/psidref$(REF_EXE) \
		--make-vec $(REF_BUILD)/make_vec$(REF_EXE) --player $(RELEASE_DIR)/f030sid.ttp \
		--hatari $(HATARI) --tos third_party/f030dsp3d/tools/tos402.rom $(PLAY_GATE_ARGS) | tee build/play-gate-results.txt

# --- the release package ----------------------------------------------------
# F030SID.ZIP: the player, a demo tune and the 40-column release note, in one
# folder (the DSP image is inside the TTP). The note goes out with CRLF line
# ends; the demo is an original trace replayed by make_trace_sid.py's routine.
PACKAGE_BUILD := build/package
PACKAGE_DIR := $(PACKAGE_BUILD)/F030SID
PACKAGE_ZIP := $(RELEASE_DIR)/F030SID.ZIP

$(PACKAGE_BUILD)/demo.sid: tools/player/make_demo_trace.py tools/player/make_trace_sid.py
	@mkdir -p $(PACKAGE_BUILD)
	$(PYTHON) tools/player/make_demo_trace.py $(PACKAGE_BUILD)/demo.trace
	$(PYTHON) tools/player/make_trace_sid.py $(PACKAGE_BUILD)/demo.trace $@ "F030SID demo"

package: $(PACKAGE_ZIP)

$(PACKAGE_ZIP): $(RELEASE_DIR)/f030sid.ttp $(PACKAGE_BUILD)/demo.sid package/README.TXT
	@awk 'length($$0) > 40 { printf "error: package/README.TXT line %d is wider than 40 columns\n", NR; bad = 1 } \
		END { exit bad }' package/README.TXT >&2
	@rm -rf $(PACKAGE_DIR) $@ && mkdir -p $(PACKAGE_DIR)
	cp $(RELEASE_DIR)/f030sid.ttp $(PACKAGE_DIR)/F030SID.TTP
	cp $(PACKAGE_BUILD)/demo.sid $(PACKAGE_DIR)/DEMO.SID
	awk '{ printf "%s\r\n", $$0 }' package/README.TXT > $(PACKAGE_DIR)/README.TXT
	cd $(PACKAGE_BUILD) && zip -q -X -r $(CURDIR)/$@ F030SID
	@unzip -l $@

# The packaged player on the packaged demo tune, through the player gate.
package-gate: $(PACKAGE_ZIP) $(REF_BUILD)/psidref$(REF_EXE) $(REF_BUILD)/make_vec$(REF_EXE)
	$(call require_hatari,package-gate)
	$(PYTHON) tools/player/play_gate.py --build build --psidref $(REF_BUILD)/psidref$(REF_EXE) \
		--make-vec $(REF_BUILD)/make_vec$(REF_EXE) --player $(PACKAGE_DIR)/F030SID.TTP \
		--hatari $(HATARI) --tos third_party/f030dsp3d/tools/tos402.rom --seconds 32 --jobs 2 \
		$(PACKAGE_DIR)/DEMO.SID

# Real tunes (music/*.sid, not in the repository): the reference 6510 core
# against libsidplayfp, then the player end to end on the same tunes.
TUNES ?= $(wildcard music/*.sid)
tune-check: $(REF_BUILD)/psidref$(REF_EXE) trace
	$(PYTHON) tools/player/tune_check.py $(REF_BUILD)/psidref$(REF_EXE) $(LSFP_BUILD)/sidtrace$(REF_EXE) $(TUNES)

tune-gate: all $(REF_BUILD)/psidref$(REF_EXE) $(REF_BUILD)/make_vec$(REF_EXE)
	$(call require_hatari,tune-gate)
	$(PYTHON) tools/player/play_gate.py --build build --psidref $(REF_BUILD)/psidref$(REF_EXE) \
		--make-vec $(REF_BUILD)/make_vec$(REF_EXE) --player $(RELEASE_DIR)/f030sid.ttp \
		--hatari $(HATARI) --tos third_party/f030dsp3d/tools/tos402.rom --seconds 30 --models tune --vbls-per-second 130 \
		$(PLAY_GATE_ARGS) $(TUNES)

$(RELEASE_DIR)/ratetest.tos: $(M68K_BUILD)/ratetest.o $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $< -b ataritos -s -e start -o $@

# The tune menu: keys 1 to 9 start F030SID.TTP on the tunes MENU.INF lists.
$(RELEASE_DIR)/sidmenu.tos: $(M68K_BUILD)/sidmenu.o $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $< -b ataritos -s -e start -o $@

$(RELEASE_DIR)/dspprobe.tos: $(M68K_BUILD)/dspprobe.o $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $< -b ataritos -s -e start -o $@

# --- gates ----------------------------------------------------------------

check: all
	@test -s $(RELEASE_DIR)/f030sid.tos
	@test -s $(RELEASE_DIR)/f030sid.ttp
	@test -s $(RELEASE_DIR)/ratetest.tos
	@test -s $(RELEASE_DIR)/dspprobe.tos
	@test -s $(RELEASE_DIR)/sid.lod
	@for l in SID SIBOOT RATETEST DSPPROBE; do \
		rg -q "^0 +Errors" $(DSP_BUILD)/$$l.LST && \
		rg -q "^0 +Warnings" $(DSP_BUILD)/$$l.LST || { echo "error: $$l.LST not clean" >&2; exit 1; }; \
	done
	@rg -q "^DSP_BOOT_WORDS equ " $(DSP_STAGE2_IMAGE)
	@rg -q "^DSP_STAGE2_PROGRAM_WORDS equ " $(DSP_STAGE2_IMAGE)
	@rg -q "^RATETEST_BOOT_WORDS equ " $(RATETEST_BOOT_IMAGE)
	@rg -q "^DSPPROBE_BOOT_WORDS equ " $(DSPPROBE_BOOT_IMAGE)
	@file $(RELEASE_DIR)/f030sid.tos $(RELEASE_DIR)/sid.lod

# The two physical-Falcon validation programs, gated under Hatari. Under Hatari
# they can only prove the programs' mechanics; run them on a real Falcon for
# the hardware answer (RATETEST.TXT / DSPPROBE.TXT land beside the program).
ratetest-hatari: $(RELEASE_DIR)/ratetest.tos
	$(call require_hatari,ratetest-hatari)
	@mkdir -p build
	@cd $(RELEASE_DIR) && $(HATARI_HEADLESS) --run-vbls 6000 --conout 2 \
		ratetest.tos > $(CURDIR)/build/ratetest-hatari.out 2>&1
	@cat build/ratetest-hatari.out
	@rg -q "^RESULT: PASS" build/ratetest-hatari.out

dspprobe-hatari: $(RELEASE_DIR)/dspprobe.tos
	$(call require_hatari,dspprobe-hatari)
	@mkdir -p build
	@cd $(RELEASE_DIR) && $(HATARI_HEADLESS) --run-vbls 2500 --conout 2 \
		dspprobe.tos > $(CURDIR)/build/dspprobe-hatari.out 2>&1
	@cat build/dspprobe-hatari.out
	@rg -q "^RESULT: PASS" build/dspprobe-hatari.out

run: all
	$(call require_hatari,run)
	cd $(RELEASE_DIR) && $(HATARI) --machine falcon --dsp emu --tos \
		$(CURDIR)/third_party/f030dsp3d/tools/tos402.rom f030sid.tos

# Hatari without a window or sound; every target below runs a program for a
# fixed number of VBLs and exits.
HATARI_HEADLESS = SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy $(HATARI) \
	--machine falcon --dsp emu \
	--tos $(CURDIR)/third_party/f030dsp3d/tools/tos402.rom --patch-tos true \
	--fast-boot true --fast-forward true --sound off --confirm-quit false

# Boot f030sid.tos in Hatari and check the bring-up verdict it prints: the DSP
# boots, answers the protocol, and the SID register shadow round-trips.
smoke: all
	$(call require_hatari,smoke)
	@mkdir -p build
	@cd $(RELEASE_DIR) && $(HATARI_HEADLESS) --run-vbls 800 --conout 2 \
		--log-file $(CURDIR)/build/hatari-smoke.log \
		--trace-file $(CURDIR)/build/hatari-smoke.trace \
		--trace gemdos,dsp_host_interface,xbios \
		f030sid.tos > $(CURDIR)/build/hatari-smoke.out 2>&1
	@cat build/hatari-smoke.out
	@rg -q "^PASS" build/hatari-smoke.out
	@rg -q "XBIOS 0x6E Dsp_ExecBoot" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x010000" build/hatari-smoke.trace
	@rg -q "Transfer 0x534944" build/hatari-smoke.trace
	@! rg -q "Illegal instruction|Modulo addressing result unpredictable" build/hatari-smoke.log
	@echo "smoke: ok"

# Cycle-count a DSP code range between two labels with Hatari's DSP profiler.
# PROFILE_START/PROFILE_END name labels in src/dsp/sid.asm; the default range
# is the register-file clear that runs when the DSP starts.
PROFILE_START ?= sid_clear_regs
PROFILE_END ?= sid_loop
PROFILE_DIR := build/dsp-profile
profile-sid: all
	$(call require_hatari,profile-sid)
	@rm -rf $(PROFILE_DIR)
	@$(PYTHON) tools/profile_dsp.py prepare --listing $(DSP_BUILD)/SID.LST \
		--output-dir $(PROFILE_DIR) --start $(PROFILE_START) --end $(PROFILE_END)
	@cd $(RELEASE_DIR) && $(HATARI_HEADLESS) --run-vbls 800 \
		--parse $(CURDIR)/$(PROFILE_DIR)/start.ini f030sid.tos \
		> $(CURDIR)/$(PROFILE_DIR)/debug.log 2>&1 || { tail -n 60 $(CURDIR)/$(PROFILE_DIR)/debug.log >&2; exit 1; }
	@test -s $(PROFILE_DIR)/profile.txt || { echo "error: Hatari captured no profile" >&2; \
		tail -n 60 $(PROFILE_DIR)/debug.log >&2; exit 1; }
	@$(PYTHON) tools/profile_dsp.py report --listing $(DSP_BUILD)/SID.LST \
		--profile $(PROFILE_DIR)/profile.txt --output $(PROFILE_DIR)/report.txt

clean:
	rm -rf build
	rm -f $(RELEASE_DIR)/f030sid.tos $(RELEASE_DIR)/f030sid.ttp \
		$(RELEASE_DIR)/ratetest.tos $(RELEASE_DIR)/dspprobe.tos \
		$(RELEASE_DIR)/sid.lod $(RELEASE_DIR)/F030SID.ZIP
	@rmdir $(RELEASE_DIR) 2>/dev/null || true
