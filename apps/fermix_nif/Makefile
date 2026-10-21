# Makefile for the fermix_nif C NIF, driven by elixir_make.
#
# elixir_make exports MIX_APP_PATH and ERTS_INCLUDE_DIR. The shared object is
# written to $(MIX_APP_PATH)/priv so the source tree keeps no priv/ directory
# (elixir_make guideline for :build_embedded correctness).

CC ?= cc
CFLAGS ?= -O2
# ci.yml's disclaim-shim job compiles fermix_nif.c with zig for every release
# target under these flags plus -Wextra -Werror; keep its flags a superset.
CFLAGS += -Wall -std=c99 -I"$(ERTS_INCLUDE_DIR)"

PREFIX = $(MIX_APP_PATH)/priv
LIB_NAME = $(PREFIX)/fermix_nif.so

SRC = c_src/fermix_nif.c

KERNEL_NAME := $(shell uname -s)

ifeq ($(KERNEL_NAME), Darwin)
	CFLAGS += -fPIC
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
	CFLAGS += -fPIC
	LDFLAGS += -shared
endif

all: $(LIB_NAME)

$(LIB_NAME): $(SRC)
	mkdir -p $(PREFIX)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $(LIB_NAME)

# The disclaim exec shim (macOS only) is a standalone EXECUTABLE, so it must
# not be built with $(CC): Burrito's cross-build sets CC to a `zig cc` string
# with `-shared` baked in, which would emit a dylib. Cross-builds for macOS
# targets pass DISCLAIM_TARGET (a zig triplet, from the burrito target's
# nif_env qualifier in the umbrella mix.exs); local macOS builds use cc.
# Keep DISCLAIM_CFLAGS in lockstep with the ci.yml disclaim_shim job so a
# strict-zig-only compile error can never first appear at release time.
DISCLAIM_SRC = c_src/fermix_disclaim.c
DISCLAIM_BIN = $(PREFIX)/disclaim
DISCLAIM_CFLAGS = -std=c99 -O2 -Wall -Wextra -Werror

# The Apple Maps helper (macOS only), one place search per process for
# place_search's apple_maps backend (M72 section 14): a Swift EXECUTABLE built
# with swiftc from the Command Line Tools, so only a native Darwin build makes
# it. A cross-build (DISCLAIM_TARGET set, on Linux) has no Swift toolchain for
# macOS and carries no helper. The deployment target is the app's floor: an API
# newer than macOS 15 is a compile error here instead of a crash on an older
# Mac, and a deprecation in a newer SDK stays a warning that cannot fire.
# Keep MAPS_SWIFTFLAGS in lockstep with the ci.yml check job's "Apple Maps
# helper (macOS)" step, which compiles it again with its own copy of the flags.
MAPS_SRC = swift_src/fermix_maps.swift
MAPS_BIN = $(PREFIX)/fermix-maps
MAPS_ARCH := $(shell uname -m)
MAPS_SWIFTFLAGS = -O -swift-version 5 -warnings-as-errors -target $(MAPS_ARCH)-apple-macos15.0

ifdef DISCLAIM_TARGET
all: $(DISCLAIM_BIN)

$(DISCLAIM_BIN): $(DISCLAIM_SRC)
	mkdir -p $(PREFIX)
	zig cc -target $(DISCLAIM_TARGET) $(DISCLAIM_CFLAGS) $(DISCLAIM_SRC) -o $(DISCLAIM_BIN)
else ifeq ($(KERNEL_NAME), Darwin)
all: $(DISCLAIM_BIN) $(MAPS_BIN)

$(DISCLAIM_BIN): $(DISCLAIM_SRC)
	mkdir -p $(PREFIX)
	cc $(DISCLAIM_CFLAGS) $(DISCLAIM_SRC) -o $(DISCLAIM_BIN)

$(MAPS_BIN): $(MAPS_SRC)
	mkdir -p $(PREFIX)
	swiftc $(MAPS_SWIFTFLAGS) $(MAPS_SRC) -o $(MAPS_BIN)
endif

clean:
	$(RM) $(LIB_NAME) $(DISCLAIM_BIN) $(MAPS_BIN)

.PHONY: all clean
