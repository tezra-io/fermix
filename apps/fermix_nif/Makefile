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

clean:
	$(RM) $(LIB_NAME)

.PHONY: all clean
