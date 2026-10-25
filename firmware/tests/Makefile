OUT := ../../build/firmware-tests
COMP := ../ports/esp32s3/components
CPPFLAGS := -Istubs -I$(COMP)/fpga_link/include -I$(COMP)/nes_rom/include -I$(COMP)/profile_mgr/include \
            -I$(COMP)/la_capture/include -I../ports/esp32s3/main
CFLAGS := -std=c11 -g -O1 -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined -fno-omit-frame-pointer
HEADERS := $(wildcard stubs/*.h stubs/freertos/*.h $(COMP)/*/include/*.h ../ports/esp32s3/main/*.h)

test: $(OUT)/test_loader $(OUT)/test_la $(OUT)/test_la_view $(OUT)/test_la_screen $(OUT)/test_launcher
	cd $(OUT) && ./test_loader
	$(OUT)/test_la
	cd $(OUT) && ./test_la_view
	$(OUT)/test_la_screen
	$(OUT)/test_launcher

$(OUT)/test_launcher: test_launcher.c ../components/launcher/lc_app.c \
                       ../components/launcher/lc_view.c ../components/ui/ui.c \
                       $(wildcard ../components/ui/assets/*.c) | $(OUT)
	$(CC) $(CFLAGS) -I../components/ui/include -I../components/launcher/include $^ -o $@

$(OUT)/test_la_screen: test_la_screen.c ../ports/esp32s3/main/la_screen.c \
                        $(COMP)/la_capture/la_capture.c ../components/la_view/la_view.c \
                        ../components/launcher/lc_view.c ../components/ui/ui.c \
                        $(wildcard ../components/ui/assets/*.c) $(HEADERS) | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -I$(COMP)/input/include -I../components/la_view/include \
	  -I../components/ui/include -I../components/launcher/include $(filter %.c,$^) -o $@

$(OUT)/test_la_view: test_la_view.c ../components/la_view/la_view.c ../components/launcher/lc_view.c \
                      ../components/ui/ui.c $(wildcard ../components/ui/assets/*.c) | $(OUT)
	$(CC) $(CFLAGS) -I../components/la_view/include -I../components/ui/include \
	  -I../components/launcher/include $^ -o $@

$(OUT)/cmd_capture.o: ../ports/esp32s3/main/cmd_capture.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -Dmalloc=test_capture_malloc -c $< -o $@

$(OUT)/test_la: test_la.c $(COMP)/la_capture/la_capture.c $(OUT)/cmd_capture.o $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(filter %.c %.o,$^) -o $@

$(OUT):
	mkdir -p $@

$(OUT)/nes_rom.o: $(COMP)/nes_rom/nes_rom.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(OUT)/profile_mgr.o: $(COMP)/profile_mgr/profile_mgr.c $(HEADERS) Makefile | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) -Dfopen=test_fopen -c $< -o $@

$(OUT)/test_loader: test_loader.c $(OUT)/nes_rom.o $(OUT)/profile_mgr.o
	$(CC) $(CPPFLAGS) $(CFLAGS) $^ -o $@

.PHONY: test
