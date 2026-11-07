#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "lc_app.h"

static uint8_t fb[UI_FB_SIZE];
static uint32_t now;
static int logic_runs, game_runs, demo_runs;
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
static bool demo(lc_progress_cb cb,void *ctx,char *err,size_t n)
{
    cb(ctx,"",50);
    demo_runs++;
    if (!success) snprintf(err,n,"test error");
    return success;
}
static void screenshot(void)
{
    FILE *f=fopen("la-demo-menu.ppm","wb");
    assert(f);
    fprintf(f,"P6\n640 480\n255\n");
    for(int y=0;y<UI_H;y++)
        for(int x=0;x<UI_W;x++) {
            unsigned char value=fb[y*UI_STRIDE+x/2];
            value=((x&1) ? value&15 : value>>4)*17;
            for(int c=0;c<3;c++) fputc(value,f);
        }
    fclose(f);
}
int main(void)
{
    const lc_port_t port={.now_ms=time_ms,.sleep_ms=sleep_ms,.palette=palette,
        .show=show,.games=games,.run=run,.run_logic=logic,.run_demo=demo};
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
    lc_app_back();
    lc_app_key(LC_BACK,false);  // HOME from game list
    lc_app_key(LC_DOWN,false);  // normal LA
    lc_app_key(LC_DOWN,false);  // demo card, separately selected
    screenshot();
    lc_app_key(LC_OK,false);
    assert(demo_runs==1 && logic_runs==4 && lc_app_running());
    lc_app_back();
    success=false;
    lc_app_key(LC_OK,false);
    assert(demo_runs==2 && !lc_app_running());
    lc_app_key(LC_BACK,false);
    success=true;
    lc_app_key(LC_OK,false);
    assert(demo_runs==3 && lc_app_running());
    lc_port_t old=port;
    old.run_logic=NULL;
    old.run_demo=NULL;
    lc_app_start(&old,fb,&ui);
    lc_app_key(LC_OK,false);
    lc_app_key(LC_DOWN,false);
    lc_app_key(LC_OK,false);
    assert(!lc_app_running() && logic_runs==4);  // unsupported ports retain stub
    lc_app_key(LC_BACK,false);
    lc_app_key(LC_DOWN,false);
    lc_app_key(LC_OK,false);
    assert(!lc_app_running() && demo_runs==3);
    puts("PASS launcher: logic start, exit, failure, NES return, unsupported port");
}
