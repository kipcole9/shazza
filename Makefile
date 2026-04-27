# Built by elixir_make. ERTS_INCLUDE_DIR and MIX_APP_PATH come from the
# mix compiler. We link against libavutil only — Xav already pulls in the
# rest of the FFmpeg shared libraries.

PRIV_DIR = $(MIX_APP_PATH)/priv
NIF_SO   = $(PRIV_DIR)/libav_silence.so

CFLAGS  ?= -O2 -Wall -Wextra
CFLAGS  += -fPIC -shared
IFLAGS   = -I$(ERTS_INCLUDE_DIR)
LDFLAGS  = -lavutil

ifeq ($(shell uname -s),Darwin)
	IFLAGS  += $(shell pkg-config --cflags-only-I libavutil)
	LDFLAGS  = $(shell pkg-config --libs libavutil)
	CFLAGS  += -undefined dynamic_lookup
endif

SOURCES = c_src/av_silence.c

all: $(NIF_SO)

$(NIF_SO): $(SOURCES)
	mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) $(IFLAGS) $(SOURCES) $(LDFLAGS) -o $(NIF_SO)

clean:
	rm -f $(NIF_SO)

.PHONY: all clean
