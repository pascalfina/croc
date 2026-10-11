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

# Set CHERIOT=1 for a target below bin/cheriot. The default remains the legacy
# GCC build used by the existing Croc tests.
CHERIOT         ?= 0

# CHERIoT bare-metal toolchain and image layout.
CHERIOT_CC       ?= /cheriot-tools/bin/clang
CHERIOT_OBJCOPY  ?= /foss/tools/riscv-gnu-toolchain/bin/riscv64-unknown-elf-objcopy
CHERIOT_TARGET   ?= riscv32-unknown-elf
CHERIOT_CPU      ?= cheriot
CHERIOT_ABI      ?= cheriot-baremetal
CHERIOT_STARTUP  ?= crt0_cheriot.S
CHERIOT_LINK     ?= link_cheriot.ld
CHERIOT_BUILDDIR ?= build/cheriot
CHERIOT_BINDIR   ?= bin/cheriot
CHERIOT_FLAGS    ?= --target=$(CHERIOT_TARGET) -mcpu=$(CHERIOT_CPU) \
	-mabi=$(CHERIOT_ABI) -mrelax -fshort-wchar \
	-ffreestanding -fno-builtin -nostdlib

# Collecting source files
LIB_SOURCES  := $(wildcard $(SRCDIR)/*.[cS])
TOP_SOURCES  := $(filter-out $(CRT0), $(wildcard *.[cS]))
TEST_SOURCES := $(wildcard test/*.[cS])
CHERIOT_SOURCES := $(wildcard cheriot/*.S)
PROG_SOURCES := $(TOP_SOURCES) $(TEST_SOURCES) $(CHERIOT_SOURCES)

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

# Dependency files for automatic rebuilds
DEPFILES := $(CRT0_OBJ:.o=.d) $(LIB_OBJS:.o=.d) $(PROG_OBJS:.o=.d)

CHERIOT_STARTUP_OBJ := $(CHERIOT_BUILDDIR)/$(CHERIOT_STARTUP:.S=.o)
CHERIOT_PROGRAMS    := $(basename $(notdir $(wildcard cheriot/*.[cS])))
CHERIOT_OBJECTS     := $(CHERIOT_PROGRAMS:%=$(CHERIOT_BUILDDIR)/%.o)

# Ensure intermediate object files are not deleted after linking
.SECONDARY: $(CRT0_OBJ) $(LIB_OBJS) $(PROG_OBJS) \
	$(CHERIOT_STARTUP_OBJ) $(CHERIOT_OBJECTS)

all: compile

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
.PHONY: all clean compile cheriot-inline

clean:
	rm -rf $(BINDIR) $(BUILDDIR)

compile: $(BINDIR) $(BUILDDIR) $(ALL_TARGETS)

# Convenience alias for the first CHERIoT compiler test.
cheriot-inline:
	$(MAKE) CHERIOT=1 $(CHERIOT_BINDIR)/test_simple_inline.hex

ifeq ($(CHERIOT),1)

# CHERIoT startup and source objects use a separate directory from GCC.
$(CHERIOT_STARTUP_OBJ): $(CHERIOT_STARTUP)
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -MMD -MP -c $< -o $@

$(CHERIOT_BUILDDIR)/%.o: cheriot/%.S
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR) -MMD -MP -c $< -o $@

$(CHERIOT_BUILDDIR)/%.o: cheriot/%.c
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR) -MMD -MP -c $< -o $@

$(CHERIOT_BINDIR)/%.elf: $(CHERIOT_BUILDDIR)/%.o $(CHERIOT_STARTUP_OBJ) $(CHERIOT_LINK)
	mkdir -p $(dir $@)
	$(CHERIOT_CC) $(CHERIOT_FLAGS) -fuse-ld=lld -nostartfiles -T$(CHERIOT_LINK) \
		$(CHERIOT_STARTUP_OBJ) $(CHERIOT_BUILDDIR)/$*.o -o $@

$(CHERIOT_BINDIR)/%.hex: $(CHERIOT_BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(CHERIOT_OBJCOPY) -O verilog $< $@

endif

-include $(DEPFILES)
