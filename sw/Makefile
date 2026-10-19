# Copyright (c) 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Paul Scheffler <paulsc@iis.ee.ethz.ch>
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Toolchain
RISCV_XLEN    ?= 32
RISCV_MARCH   ?= rv$(RISCV_XLEN)i_zicsr
RISCV_MABI    ?= ilp32
RISCV_PREFIX  ?= riscv64-unknown-elf-
RISCV_CC      ?= $(RISCV_PREFIX)gcc
RISCV_CXX     ?= $(RISCV_PREFIX)g++
RISCV_OBJDUMP ?= $(RISCV_PREFIX)objdump
RISCV_OBJCOPY ?= $(RISCV_PREFIX)objcopy
RISCV_AS      ?= $(RISCV_PREFIX)as
RISCV_AR      ?= $(RISCV_PREFIX)ar
RISCV_LD      ?= $(RISCV_PREFIX)ld
RISCV_STRIP   ?= $(RISCV_PREFIX)strip

# Compiler and linker flags
RISCV_FLAGS ?= -march=$(RISCV_MARCH) -mabi=$(RISCV_MABI) -mcmodel=medany \
	-static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding
RISCV_CCFLAGS ?= $(RISCV_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR)
RISCV_LDFLAGS ?= -static -nostartfiles -lm -lgcc $(RISCV_FLAGS)


# Directory defaults
BINDIR   ?= bin
BUILDDIR ?= build
CRT0     ?= crt0.S
LINK     ?= link.ld
SRCDIR   ?= lib/src
INCDIR   ?= lib/inc

# The default build remains the legacy GCC build used by the existing Croc
# tests. CHERIOT=1 is retained for compatibility with existing commands; use
# the explicit `cheriot` target to build the CHERIoT programs.
CHERIOT         ?= 0

# CHERIoT bare-metal toolchain and image layout.
CHERIOT_CC       ?= /cheriot-tools/bin/clang
CHERIOT_OBJDUMP  ?= /cheriot-tools/bin/llvm-objdump
CHERIOT_OBJCOPY  ?= /foss/tools/riscv-gnu-toolchain/bin/riscv64-unknown-elf-objcopy
CHERIOT_TARGET   ?= riscv32-unknown-elf
CHERIOT_CPU      ?= cheriot
CHERIOT_ABI      ?= cheriot-baremetal
CHERIOT_ASM_STARTUP ?= crt0_cheriot.S
CHERIOT_C_STARTUP   ?= crt0_cheriot_stack.S
CHERIOT_LINK     ?= link_cheriot.ld
CHERIOT_BUILDDIR ?= build/cheriot
CHERIOT_BINDIR   ?= bin/cheriot
CHERIOT_FLAGS    ?= --target=$(CHERIOT_TARGET) -mcpu=$(CHERIOT_CPU) \
	-mabi=$(CHERIOT_ABI) -mrelax -fshort-wchar \
	-ffreestanding -fno-builtin -nostdlib

# CHERIoT-RTOS applications each live in their own xmake project. Add a new
# project directory here; its directory name must match its firmware target.
CHERIOT_RTOS_PROJECTS      ?= \
	cheriot-rtos/hello_world \
	cheriot-rtos/test_exception_handling \
	cheriot-rtos/test_use_after_free_handling \
	cheriot-rtos/hello_compartment \
	cheriot-rtos/hello_safe_compartment \
	cheriot-rtos/temporal_safety \
	cheriot-rtos/sealing \
	cheriot-rtos/producer_consumer \
	cheriot-rtos/error_handling \
	cheriot-rtos/memory_safety \
# 	cheriot-rtos/javascript \
# 	cheriot-rtos/audit


CHERIOT_RTOS_BINDIR        ?= bin/cheriot-rtos
CHERIOT_RTOS_BUILD_ROOT    ?= $(CURDIR)/build/cheriot-rtos
CHERIOT_RTOS_LEGACY_PROJECT ?= cheriot-rtos
CHERIOT_RTOS_BOARD         ?= $(CURDIR)/../cheriot-rtos/sdk/boards/croc.json
CHERIOT_RTOS_ANALYZER     ?= $(CURDIR)/../scripts/analyze_trusted_stack.py
CHERIOT_RTOS_STACK_RESERVE ?= 1
# The trusted-stack check is enabled by default. The build fails when the
# configured frame count is below the analyzer's recommendation.
CHERIOT_RTOS_ANALYSIS_FLAGS ?= --check

# The upstream CHERIoT-RTOS tests are kept separate from the local demo
# projects. Build one firmware image per test so each simulation has its own
# result and object dump for debugging.
CHERIOT_RTOS_TESTS_PROJECT    ?= ../cheriot-rtos/tests
CHERIOT_RTOS_TESTS_PREFIX     ?= test-suite
CHERIOT_RTOS_TESTS_BUILD_ROOT ?= $(CHERIOT_RTOS_BUILD_ROOT)/upstream-tests

# `rust`, `allocator`, and `bigdata` are intentionally omitted. Rust needs a
# CHERIoT-enabled Rust toolchain; allocator requests a 1 MiB heap quota and
# bigdata needs more static memory than the Croc board provides.
CHERIOT_RTOS_UPSTREAM_TESTS ?= \
	ccompile \
	extra_compiles \
	preflight \
	debug_cxx \
	debug_c \
	mmio \
	unwind_cleanup \
	softfloat \
	stdio \
	static_sealing \
	crash_recovery \
	compartment_calls \
	check_pointer \
	misc \
	stack \
	thread_pool \
	global_constructors \
	queue \
	futex \
	locks \
	list \
	eventgroup \
	multiwaiter \
	bitpacks \
	time

CHERIOT_RTOS_TESTS_OUTPUTS := $(foreach test,$(CHERIOT_RTOS_UPSTREAM_TESTS), \
	$(CHERIOT_RTOS_BINDIR)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(test).elf \
	$(CHERIOT_RTOS_BINDIR)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(test).hex \
	$(CHERIOT_RTOS_BINDIR)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(test).dump)
CHERIOT_RTOS_TESTS_BUILD_TARGETS := $(foreach test,$(CHERIOT_RTOS_UPSTREAM_TESTS), \
	cheriot-rtos-test-$(test)-build)

CHERIOT_RTOS_NAMES         := $(notdir $(patsubst %/,%,$(CHERIOT_RTOS_PROJECTS)))
CHERIOT_RTOS_ELFS          := $(CHERIOT_RTOS_NAMES:%=$(CHERIOT_RTOS_BINDIR)/%.elf)
CHERIOT_RTOS_HEXS          := $(CHERIOT_RTOS_NAMES:%=$(CHERIOT_RTOS_BINDIR)/%.hex)
CHERIOT_RTOS_DUMPS         := $(CHERIOT_RTOS_NAMES:%=$(CHERIOT_RTOS_BINDIR)/%.dump)
CHERIOT_RTOS_OUTPUTS       := $(CHERIOT_RTOS_ELFS) $(CHERIOT_RTOS_HEXS) $(CHERIOT_RTOS_DUMPS)

# Collecting source files
LIB_SOURCES  := $(wildcard $(SRCDIR)/*.[cS])
TOP_SOURCES  := $(filter-out $(CRT0) $(CHERIOT_ASM_STARTUP) $(CHERIOT_C_STARTUP), $(wildcard *.[cS]))
TEST_SOURCES := $(wildcard test/*.[cS])
PROG_SOURCES := $(TOP_SOURCES) $(TEST_SOURCES)

PROG_NAMES   := $(basename $(PROG_SOURCES))

# Creating object fiel list from source files
CRT0_OBJ  := $(BUILDDIR)/$(basename $(CRT0)).o
LIB_OBJS  := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
	         $(basename $(LIB_SOURCES))))
PROG_OBJS := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
	         $(basename $(PROG_SOURCES))))

# Everything to be built
ALL_TARGETS := $(PROG_NAMES:%=$(BINDIR)/%.elf) \
	           $(PROG_NAMES:%=$(BINDIR)/%.dump) \
	           $(PROG_NAMES:%=$(BINDIR)/%.hex)

# CHERIoT programs are deliberately split by startup ABI. The handwritten
# assembly tests enable CHERIoT themselves; compiler-generated C programs use
# the stack/global-pointer startup.
CHERIOT_ASM_SOURCES       := $(wildcard cheriot/*.S)
CHERIOT_C_SOURCES         := $(wildcard cheriot/with_cheriot_compiler_only/*.c)
CHERIOT_ASM_PROGRAMS      := $(basename $(notdir $(CHERIOT_ASM_SOURCES)))
CHERIOT_C_PROGRAMS        := $(basename $(notdir $(CHERIOT_C_SOURCES)))
CHERIOT_ASM_OBJECTS       := $(CHERIOT_ASM_PROGRAMS:%=$(CHERIOT_BUILDDIR)/%.o)
CHERIOT_C_OBJECTS         := $(CHERIOT_C_PROGRAMS:%=$(CHERIOT_BUILDDIR)/%.o)
CHERIOT_ASM_STARTUP_OBJ   := $(CHERIOT_BUILDDIR)/$(CHERIOT_ASM_STARTUP:.S=.o)
CHERIOT_C_STARTUP_OBJ     := $(CHERIOT_BUILDDIR)/$(CHERIOT_C_STARTUP:.S=.o)
CHERIOT_ASM_ELFS          := $(CHERIOT_ASM_PROGRAMS:%=$(CHERIOT_BINDIR)/%.elf)
CHERIOT_C_ELFS            := $(CHERIOT_C_PROGRAMS:%=$(CHERIOT_BINDIR)/%.elf)
CHERIOT_HEX_TARGETS       := $(CHERIOT_ASM_ELFS:.elf=.hex) $(CHERIOT_C_ELFS:.elf=.hex)

# Dependency files for automatic rebuilds
DEPFILES := $(CRT0_OBJ:.o=.d) $(LIB_OBJS:.o=.d) $(PROG_OBJS:.o=.d) \
	$(CHERIOT_ASM_STARTUP_OBJ:.o=.d) $(CHERIOT_C_STARTUP_OBJ:.o=.d) \
	$(CHERIOT_ASM_OBJECTS:.o=.d) $(CHERIOT_C_OBJECTS:.o=.d)

# Ensure intermediate object files are not deleted after linking
.SECONDARY: $(CRT0_OBJ) $(LIB_OBJS) $(PROG_OBJS) \
	$(CHERIOT_ASM_STARTUP_OBJ) $(CHERIOT_C_STARTUP_OBJ) \
	$(CHERIOT_ASM_OBJECTS) $(CHERIOT_C_OBJECTS)

# Build every software variant with one command: legacy GCC programs,
# CHERIoT tests, and the CHERIoT-RTOS hello-world image.
all: compile cheriot cheriot-rtos cheriot-rtos-tests

$(BINDIR):
	mkdir -p $(BINDIR)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Assembly to object compilation
$(BUILDDIR)/%.o: %.S
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

# C to object compilation
$(BUILDDIR)/%.o: %.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

# Linking
$(BINDIR)/%.elf: $(BUILDDIR)/%.o $(CRT0_OBJ) $(LIB_OBJS) $(LINK)
	mkdir -p $(dir $@)
	$(RISCV_CC) -o $@ $(filter-out $(LINK), $^) $(RISCV_LDFLAGS) -T$(LINK)

# Dump ELF data and disassembly
$(BINDIR)/%.dump: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJDUMP) -D -s $< >$@

# Convert ELF to hex format for easy loading into simulators or hardware
$(BINDIR)/%.hex: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O verilog $< $@

# Phonies
.PHONY: all clean compile cheriot cheriot-inline cheriot-rtos \
	cheriot-rtos-check cheriot-rtos-build cheriot-rtos-tests \
	$(CHERIOT_RTOS_TESTS_BUILD_TARGETS) cheriot-rtos-hello

clean:
	# Remove every generated artifact from the legacy, CHERIoT, and RTOS builds.
	rm -rf \
		$(BINDIR) \
		$(BUILDDIR) \
		$(CHERIOT_RTOS_BUILD_ROOT) \
		$(CHERIOT_RTOS_LEGACY_PROJECT)/build \
		$(CHERIOT_RTOS_LEGACY_PROJECT)/.xmake \
		$(CHERIOT_RTOS_BINDIR)

compile: $(BINDIR) $(BUILDDIR) $(ALL_TARGETS)

# Build all CHERIoT binaries explicitly. This target is intentionally not part
# of `all`, so a normal GCC build never needs the CHERIoT LLVM image.
cheriot: $(CHERIOT_HEX_TARGETS)

# Convenience alias for the first CHERIoT compiler test.
cheriot-inline: $(CHERIOT_BINDIR)/test_simple_inline.hex

# Build every listed CHERIoT-RTOS project and convert its ELF into the
# 32-bit Verilog HEX format expected by the Croc testbench.
cheriot-rtos: $(CHERIOT_RTOS_OUTPUTS)

# Build the upstream CHERIoT-RTOS regression suite as one firmware image.
cheriot-rtos-tests: $(CHERIOT_RTOS_TESTS_OUTPUTS)

# Explicit alias for callers that want to make the safety check visible in the
# command line. The default `cheriot-rtos` target already enables --check.
cheriot-rtos-check: CHERIOT_RTOS_ANALYSIS_FLAGS=--check
cheriot-rtos-check: cheriot-rtos

# Backwards-compatible alias for the original single Hello World target.
cheriot-rtos-hello: cheriot-rtos

cheriot-rtos-build:
	@set -e; \
	for project in $(CHERIOT_RTOS_PROJECTS); do \
		name=$${project##*/}; \
		workdir="$(CHERIOT_RTOS_BUILD_ROOT)/$${name}"; \
		mkdir -p "$${workdir}"; \
		cd "$${workdir}"; \
		xmake config -c \
			-P "$(CURDIR)/$${project}" \
			--sdk=/cheriot-tools/ \
			--board="$(CHERIOT_RTOS_BOARD)"; \
		xmake; \
		python3 "$(CHERIOT_RTOS_ANALYZER)" \
			"$${workdir}/build/cheriot/cheriot/release/$${name}.json" \
			--xmake "$(CURDIR)/$${project}/xmake.lua" \
			--reserve "$(CHERIOT_RTOS_STACK_RESERVE)" \
			$(CHERIOT_RTOS_ANALYSIS_FLAGS); \
	done

define CHERIOT_RTOS_UPSTREAM_TEST_template
cheriot-rtos-test-$(1)-build:
	@set -e; \
	workdir="$(CHERIOT_RTOS_TESTS_BUILD_ROOT)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(1)"; \
	mkdir -p "$$$${workdir}"; \
	cd "$(CURDIR)/$(CHERIOT_RTOS_TESTS_PROJECT)"; \
	xmake config -c \
		--sdk=/cheriot-tools \
		--board="$(CHERIOT_RTOS_BOARD)" \
		--builddir="$$$${workdir}/build" \
		--most-tests=false \
		--test-$(1)=true; \
	xmake; \
	python3 "$(CHERIOT_RTOS_ANALYZER)" \
		"$$$${workdir}/build/cheriot/cheriot/release/test-suite.json" \
		--xmake "$(CURDIR)/$(CHERIOT_RTOS_TESTS_PROJECT)/xmake.lua" \
		--reserve "$(CHERIOT_RTOS_STACK_RESERVE)" \
		$(CHERIOT_RTOS_ANALYSIS_FLAGS)

$(CHERIOT_RTOS_BINDIR)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(1).elf: cheriot-rtos-test-$(1)-build
	mkdir -p "$(CHERIOT_RTOS_BINDIR)"
	cp $(CHERIOT_RTOS_TESTS_BUILD_ROOT)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(1)/build/cheriot/cheriot/release/test-suite $$@

$(CHERIOT_RTOS_BINDIR)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(1).hex: $(CHERIOT_RTOS_BINDIR)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(1).elf
	mkdir -p "$(CHERIOT_RTOS_BINDIR)"
	$(CHERIOT_OBJCOPY) -O verilog $$< $$@

$(CHERIOT_RTOS_BINDIR)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(1).dump: $(CHERIOT_RTOS_BINDIR)/$(CHERIOT_RTOS_TESTS_PREFIX)-$(1).elf
	mkdir -p "$(CHERIOT_RTOS_BINDIR)"
	$(CHERIOT_OBJDUMP) -D -s --print-imm-hex \
		--start-address=0x10000000 $$< > $$@
endef

$(foreach test,$(CHERIOT_RTOS_UPSTREAM_TESTS),$(eval $(call CHERIOT_RTOS_UPSTREAM_TEST_template,$(test))))

$(CHERIOT_RTOS_BINDIR)/%.elf: cheriot-rtos-build
	mkdir -p $(dir $@)
	cp $(CHERIOT_RTOS_BUILD_ROOT)/$*/build/cheriot/cheriot/release/$* $@

$(CHERIOT_RTOS_BINDIR)/%.hex: $(CHERIOT_RTOS_BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(CHERIOT_OBJCOPY) -O verilog $< $@

$(CHERIOT_RTOS_BINDIR)/%.dump: $(CHERIOT_RTOS_BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(CHERIOT_OBJDUMP) -D -s --print-imm-hex \
		--start-address=0x10000000 $< > $@

# CHERIoT startup objects use a separate directory from GCC.
$(CHERIOT_ASM_STARTUP_OBJ): $(CHERIOT_ASM_STARTUP)
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -MMD -MP -c $< -o $@

$(CHERIOT_C_STARTUP_OBJ): $(CHERIOT_C_STARTUP)
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR) -MMD -MP -c $< -o $@

$(CHERIOT_ASM_OBJECTS): $(CHERIOT_BUILDDIR)/%.o: cheriot/%.S
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR) -MMD -MP -c $< -o $@

$(CHERIOT_C_OBJECTS): $(CHERIOT_BUILDDIR)/%.o: cheriot/with_cheriot_compiler_only/%.c
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR) -MMD -MP -c $< -o $@

$(CHERIOT_ASM_ELFS): $(CHERIOT_BINDIR)/%.elf: $(CHERIOT_BUILDDIR)/%.o $(CHERIOT_ASM_STARTUP_OBJ) $(CHERIOT_LINK)
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -fuse-ld=lld -nostartfiles -T$(CHERIOT_LINK) \
		$(CHERIOT_ASM_STARTUP_OBJ) $(CHERIOT_BUILDDIR)/$*.o -o $@

$(CHERIOT_C_ELFS): $(CHERIOT_BINDIR)/%.elf: $(CHERIOT_BUILDDIR)/%.o $(CHERIOT_C_STARTUP_OBJ) $(CHERIOT_LINK)
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -fuse-ld=lld -nostartfiles -T$(CHERIOT_LINK) \
		$(CHERIOT_C_STARTUP_OBJ) $(CHERIOT_BUILDDIR)/$*.o -o $@

$(CHERIOT_BINDIR)/%.hex: $(CHERIOT_BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(CHERIOT_OBJCOPY) -O verilog $< $@

-include $(DEPFILES)
