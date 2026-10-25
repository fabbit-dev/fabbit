OUT := ../../build/firmware-tests
COMP := ../ports/esp32s3/components
CPPFLAGS := -Istubs -I$(COMP)/fpga_link/include -I$(COMP)/nes_rom/include -I$(COMP)/profile_mgr/include
CFLAGS := -std=c11 -g -O1 -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined -fno-omit-frame-pointer

test: $(OUT)/test_loader
	cd $(OUT) && ./test_loader

$(OUT):
	mkdir -p $@

HEADERS := $(wildcard stubs/*.h stubs/freertos/*.h $(COMP)/*/include/*.h)

$(OUT)/nes_rom.o: $(COMP)/nes_rom/nes_rom.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(OUT)/profile_mgr.o: $(COMP)/profile_mgr/profile_mgr.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -Dfopen=test_fopen -c $< -o $@

$(OUT)/test_loader: test_loader.c $(OUT)/nes_rom.o $(OUT)/profile_mgr.o
	$(CC) $(CPPFLAGS) $(CFLAGS) $^ -o $@

.PHONY: test
