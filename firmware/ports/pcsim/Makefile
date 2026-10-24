# Экраны лаунчера на ПК: make -C firmware/ports/pcsim  ->  build/pcsim/*.pgm
ROOT := ../../..
OUT  := $(ROOT)/build/pcsim
UI   := ../../components/ui
LC   := ../../components/launcher
SRC  := main.c $(UI)/ui.c $(wildcard $(UI)/assets/*.c) $(LC)/lc_view.c
CFLAGS := -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -I$(UI)/include -I$(LC)/include

run: $(OUT)/pcsim
	OUT=$(OUT) $(OUT)/pcsim

$(OUT)/pcsim: $(SRC) $(wildcard $(UI)/include/*.h $(LC)/include/*.h)
	mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $(SRC)

.PHONY: run
