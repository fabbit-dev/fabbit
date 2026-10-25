OUT := ../../build/firmware-tests
COMP := ../ports/esp32s3/components
CPPFLAGS := -Istubs -I$(COMP)/fpga_link/include -I$(COMP)/nes_rom/include -I$(COMP)/profile_mgr/include \
            -I../components/rom/include -I../ports/esp32s3/main -I$(COMP)/retro_rom/include
CFLAGS := -std=c11 -g -O1 -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined -fno-omit-frame-pointer

test: $(OUT)/test_loader $(OUT)/test_rom $(OUT)/test_rom_port $(OUT)/test_rom_entries $(OUT)/test_rom_cart $(OUT)/test_retro $(OUT)/test_retro_hotkeys
	cd $(OUT) && ./test_loader
	$(OUT)/test_rom
	$(OUT)/test_rom_port
	$(OUT)/test_rom_entries
	$(OUT)/test_rom_cart
	$(OUT)/test_retro
	$(OUT)/test_retro_hotkeys

$(OUT):
	mkdir -p $@

HEADERS := $(wildcard stubs/*.h stubs/freertos/*.h $(COMP)/*/include/*.h ../components/rom/include/*.h ../ports/esp32s3/main/*.h)

$(OUT)/test_rom: test_rom.c ../components/rom/rom.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CFLAGS) -I../components/rom/include $(filter %.c,$^) -o $@

$(OUT)/test_rom_cart: test_rom_cart.c ../components/rom/rom_cart.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CFLAGS) -I../components/rom/include $(filter %.c,$^) -o $@

ROM_SRC := ../components/rom/rom.c ../components/rom/rom_cart.c ../components/rom/rom_file.c

$(OUT)/test_rom_port: test_rom_port.c ../ports/esp32s3/main/rom_port.c $(ROM_SRC) $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(filter %.c,$^) -o $@

$(OUT)/test_rom_entries: test_rom_entries.c ../ports/esp32s3/main/launcher_port.c ../ports/esp32s3/main/cmd_profile.c ../ports/esp32s3/main/rom_port.c $(COMP)/retro_rom/retro_rom.c $(ROM_SRC) $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) -I$(COMP)/input/include -I../components/launcher/include -I../components/ui/include \
		$(CFLAGS) -Wno-unused-function -ffunction-sections -fdata-sections \
		test_rom_entries.c $(ROM_SRC) -Wl,--gc-sections -o $@

$(OUT)/test_retro: test_retro.c $(COMP)/retro_rom/retro_rom.c $(ROM_SRC) $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) test_retro.c $(ROM_SRC) -o $@

$(OUT)/test_retro_hotkeys: test_retro_hotkeys.c ../ports/esp32s3/main/cmd_pad.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -I$(COMP)/input/include -I$(COMP)/pad/include \
	  -Wno-unused-function -ffunction-sections -fdata-sections test_retro_hotkeys.c \
	  -Wl,--gc-sections -o $@

$(OUT)/nes_rom.o: $(COMP)/nes_rom/nes_rom.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(OUT)/profile_mgr.o: $(COMP)/profile_mgr/profile_mgr.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -Dfopen=test_fopen -c $< -o $@

$(OUT)/test_loader: test_loader.c $(OUT)/nes_rom.o $(OUT)/profile_mgr.o ../components/rom/rom.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $^ -o $@

.PHONY: test
