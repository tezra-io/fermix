# Makefile for the fermix_nif C NIF, driven by elixir_make.
#
# elixir_make exports MIX_APP_PATH and ERTS_INCLUDE_DIR. The shared object is
# written to $(MIX_APP_PATH)/priv so the source tree keeps no priv/ directory
# (elixir_make guideline for :build_embedded correctness).

CC ?= cc
CFLAGS ?= -O2
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

ifdef DISCLAIM_TARGET
all: $(DISCLAIM_BIN)

$(DISCLAIM_BIN): $(DISCLAIM_SRC)
	mkdir -p $(PREFIX)
	zig cc -target $(DISCLAIM_TARGET) $(DISCLAIM_CFLAGS) $(DISCLAIM_SRC) -o $(DISCLAIM_BIN)
else ifeq ($(KERNEL_NAME), Darwin)
all: $(DISCLAIM_BIN)

$(DISCLAIM_BIN): $(DISCLAIM_SRC)
	mkdir -p $(PREFIX)
	cc $(DISCLAIM_CFLAGS) $(DISCLAIM_SRC) -o $(DISCLAIM_BIN)
endif

clean:
	$(RM) $(LIB_NAME) $(DISCLAIM_BIN)

.PHONY: all clean
