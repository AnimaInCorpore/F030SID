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

SID_BOOT_IMAGE := $(GENERATED_BUILD)/sid_boot.i
RATETEST_BOOT_IMAGE := $(GENERATED_BUILD)/ratetest_boot.i
DSPPROBE_BOOT_IMAGE := $(GENERATED_BUILD)/dspprobe_boot.i

M68K_SOURCES := \
	src/m68k/main.s
M68K_OBJECTS := $(patsubst src/m68k/%.s,$(M68K_BUILD)/%.o,$(M68K_SOURCES))

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

.PHONY: all help host dsp check run clean tools ratetest-hatari dspprobe-hatari \
	ref ref-gate

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
	$(HOST_CXX) -O2 -static -std=gnu++11 -w -I$(RESID_GEN) -I$(RESID_DIR) -Isrc/ref \
		-DVERSION='"1.0"' $(addprefix $(RESID_DIR)/,$(RESID_SOURCES)) $< -o $@

$(REF_BUILD)/ref_run$(REF_EXE): tools/ref/ref_run.c src/ref/sid_ref.c src/ref/sid_ref.h
	@mkdir -p $(REF_BUILD)
	$(HOST_CC) -O2 -static -std=c99 -Wall -Wextra -Isrc/ref src/ref/sid_ref.c $< -o $@ -lm

# Bit-exactness against reSID and band-limiting against the per-cycle chip.
ref-gate: ref
	$(PYTHON) tools/ref/voice_gate.py --build $(REF_BUILD) | tee $(REF_BUILD)/gate-results.txt

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
	@echo "  run              launch f030sid.tos in Hatari"
	@echo "  ratetest-hatari  run the physical-Falcon SSI rate test under Hatari"
	@echo "  dspprobe-hatari  run the physical-Falcon DSP bus probe under Hatari"
	@echo "  clean            remove generated build/ and release/ directories"

host: $(RELEASE_DIR)/f030sid.tos $(RELEASE_DIR)/f030sid.ttp \
		$(RELEASE_DIR)/ratetest.tos $(RELEASE_DIR)/dspprobe.tos

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

$(DSP_BUILD)/BUILD.BAT: tools/BUILD_DSP.BAT src/dsp/sid.asm src/dsp/protocol.inc \
		src/dsp/ratetest.asm src/dsp/dspprobe.asm
	@mkdir -p $(DSP_BUILD)
	cp tools/BUILD_DSP.BAT $(DSP_BUILD)/BUILD.BAT
	cp src/dsp/sid.asm $(DSP_BUILD)/SID.ASM
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
	@test -s $(DSP_BUILD)/RATETEST.LOD
	@test -s $(DSP_BUILD)/DSPPROBE.LOD
	@touch $@

$(RELEASE_DIR)/sid.lod: $(DSP_BUILD)/.assembled
	@mkdir -p $(RELEASE_DIR)
	cp $(DSP_BUILD)/SID.LOD $@

$(SID_BOOT_IMAGE): tools/generate_dsp_stage2.py $(DSP_BUILD)/.assembled
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_dsp_stage2.py --standalone $(DSP_BUILD)/SID.LOD \
		--prefix sid > $@

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
		src/m68k/protocol.i $(SID_BOOT_IMAGE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/main.lst

$(M68K_BUILD)/ratetest.o: src/m68k/ratetest.s src/m68k/xbios.i \
		$(RATETEST_BOOT_IMAGE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/ratetest.lst

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

$(RELEASE_DIR)/f030sid.ttp: $(RELEASE_DIR)/f030sid.tos
	cp $< $@

$(RELEASE_DIR)/ratetest.tos: $(M68K_BUILD)/ratetest.o $(VLINK)
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
	@for l in SID RATETEST DSPPROBE; do \
		rg -q "^0 +Errors" $(DSP_BUILD)/$$l.LST && \
		rg -q "^0 +Warnings" $(DSP_BUILD)/$$l.LST || { echo "error: $$l.LST not clean" >&2; exit 1; }; \
	done
	@rg -q "^SID_BOOT_WORDS equ " $(SID_BOOT_IMAGE)
	@rg -q "^RATETEST_BOOT_WORDS equ " $(RATETEST_BOOT_IMAGE)
	@rg -q "^DSPPROBE_BOOT_WORDS equ " $(DSPPROBE_BOOT_IMAGE)
	@file $(RELEASE_DIR)/f030sid.tos $(RELEASE_DIR)/sid.lod

ratetest-hatari: $(RELEASE_DIR)/ratetest.tos
	$(call require_hatari,ratetest-hatari)
	cd $(RELEASE_DIR) && $(HATARI) --machine falcon --dsp emu --tos \
		$(CURDIR)/third_party/f030dsp3d/tools/tos402.rom ratetest.tos

dspprobe-hatari: $(RELEASE_DIR)/dspprobe.tos
	$(call require_hatari,dspprobe-hatari)
	cd $(RELEASE_DIR) && $(HATARI) --machine falcon --dsp emu --tos \
		$(CURDIR)/third_party/f030dsp3d/tools/tos402.rom dspprobe.tos

run: all
	$(call require_hatari,run)
	cd $(RELEASE_DIR) && $(HATARI) --machine falcon --dsp emu --tos \
		$(CURDIR)/third_party/f030dsp3d/tools/tos402.rom f030sid.tos

clean:
	rm -rf build
	rm -f $(RELEASE_DIR)/f030sid.tos $(RELEASE_DIR)/f030sid.ttp \
		$(RELEASE_DIR)/ratetest.tos $(RELEASE_DIR)/dspprobe.tos \
		$(RELEASE_DIR)/sid.lod
	@rmdir $(RELEASE_DIR) 2>/dev/null || true
