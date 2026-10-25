#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "lc_app.h"

static uint8_t fb[UI_FB_SIZE];
static uint32_t now;
static int logic_runs, game_runs;
static bool success=true;
static uint32_t time_ms(void) { now+=100; return now; }
static void sleep_ms(uint32_t ms) { now+=ms; }
static void palette(const uint32_t rgb[16]) { (void)rgb; }
static void show(bool on) { (void)on; }
static bool rect(int x,int y,int w,int h,const uint8_t *px,size_t stride)
{
    (void)x; (void)y; (void)w; (void)h; (void)px; (void)stride;
    return true;
}
static bool fill(int x,int y,int w,int h,uint8_t color)
{
    (void)x; (void)y; (void)w; (void)h; (void)color;
    return true;
}
static int games(lc_game_t *g,int max)
{
    assert(max>0);
    *g=(lc_game_t){.name="test",.path="test.nes"};
    return 1;
}
static bool run(const lc_game_t *g,lc_progress_cb cb,void *ctx,char *err,size_t n)
{
    (void)g; (void)err; (void)n;
    cb(ctx,"",50);
    game_runs++;
    return true;
}
static bool logic(lc_progress_cb cb,void *ctx,char *err,size_t n)
{
    cb(ctx,"",50);
    logic_runs++;
    if (!success) snprintf(err,n,"test error");
    return success;
}
int main(void)
{
    const lc_port_t port={.now_ms=time_ms,.sleep_ms=sleep_ms,.palette=palette,
        .show=show,.games=games,.run=run,.run_logic=logic};
    const ui_port_t ui={rect,fill};
    lc_app_start(&port,fb,&ui);
    lc_app_key(LC_OK,false);  // skip splash
    lc_app_key(LC_DOWN,false);
    lc_app_key(LC_OK,false);
    assert(logic_runs==1 && !game_runs && lc_app_running());
    lc_app_back();
    lc_app_key(LC_OK,false);
    assert(logic_runs==2 && lc_app_running());  // returns to profile card, not NES list
    lc_app_back();
    success=false;
    lc_app_key(LC_OK,false);
    assert(logic_runs==3 && !lc_app_running());
    lc_app_key(LC_BACK,false);  // error returns to HOME
    success=true;
    lc_app_key(LC_OK,false);
    assert(logic_runs==4 && lc_app_running());
    lc_app_back();
    lc_app_key(LC_UP,false);
    lc_app_key(LC_OK,false);  // games list
    assert(!lc_app_running());
    lc_app_key(LC_OK,false);
    assert(game_runs==1 && lc_app_running());
    lc_app_back();
    lc_app_key(LC_OK,false);
    assert(game_runs==2);  // NES exit still returns to game list
    lc_port_t old=port;
    old.run_logic=NULL;
    lc_app_start(&old,fb,&ui);
    lc_app_key(LC_OK,false);
    lc_app_key(LC_DOWN,false);
    lc_app_key(LC_OK,false);
    assert(!lc_app_running() && logic_runs==4);  // unsupported ports retain stub
    puts("PASS launcher: logic start, exit, failure, NES return, unsupported port");
}
