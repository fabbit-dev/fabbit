#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "la_view.h"
#include "ui.h"

static uint8_t fb[UI_FB_SIZE];
static uint8_t raw[131072*2];
static lav_column_t columns[LAV_COLUMNS];

static void screenshot(const char *path)
{
    FILE *f = fopen(path, "wb");
    assert(f);
    fprintf(f, "P6\n640 480\n255\n");
    for (int y = 0; y < UI_H; y++)
        for (int x = 0; x < UI_W; x++) {
            unsigned char v = fb[y*UI_STRIDE+x/2];
            v = ((x&1) ? v&15 : v>>4)*17;
            for (int i = 0; i < 3; i++) fputc(v, f);
        }
    fclose(f);
}

int main(void)
{
    lav_view_t v;
    lav_init(&v);
    ui_init(fb, NULL);
    lav_draw(&v, NULL);
    screenshot("la-ready.ppm");
    for (uint32_t count = 1; count <= 131072; count = count < 32 ? count+1 : count*2) {
        lav_capture(&v, count, count/2, 400000000, 39);
        for (int zoom = 0; zoom < 20; zoom++) {
            uint32_t previous = v.offset;
            for (unsigned x = 0; x < LAV_COLUMNS; x++) {
                uint32_t a,b;
                lav_range(&v,x,&a,&b);
                assert(a >= v.offset && a < b && b <= v.offset+v.span && b <= v.count);
                assert(a >= previous);
                previous = a;
            }
            lav_pan(&v,true);
            assert(v.offset <= v.count-v.span);
            lav_pan(&v,false);
            lav_zoom(&v,false);
        }
        assert(v.span == count);
        for (int zoom = 0; zoom < 20; zoom++) lav_zoom(&v,true);
        assert(v.span == 1);
    }
    // A one-sample pulse must remain visible when 131068 samples become 560 columns.
    lav_capture(&v,131068,65534,400000000,0);
    while (v.span < v.count) lav_zoom(&v,false);
    memset(raw,0,sizeof raw);
    raw[70001*2+1]=0x80;
    int pulses=0;
    for (unsigned x=0;x<LAV_COLUMNS;x++) {
        uint32_t a,b;
        lav_range(&v,x,&a,&b);
        lav_column(&columns[x],raw+a*2,b-a);
        if (columns[x].high & 0x8000) pulses++;
    }
    assert(pulses==1);
    uint8_t sequence[]={0x34,0x12,0xfe,0xff,0x00,0x80};
    lav_column_t c;
    lav_column(&c,sequence,3);
    assert(c.first==0x1234 && c.last==0x8000 && c.low==0 && c.high==0xfffe);
    // 16 tracks from deterministic data, screenshot is the same C renderer used on ESP.
    lav_capture(&v,131068,65534,400000000,39);
    v.span=4096;
    v.offset=63500;
    for (unsigned i=0;i<131068;i++) {
        uint16_t word=(uint16_t)(i/4);
        raw[i*2]=word;
        raw[i*2+1]=word>>8;
    }
    for (unsigned x=0;x<LAV_COLUMNS;x++) {
        uint32_t a,b;
        lav_range(&v,x,&a,&b);
        lav_column(&columns[x],raw+a*2,b-a);
    }
    lav_draw(&v,columns);
    screenshot("la-capture.ppm");
    v.demo=true;
    lav_draw(&v,columns);
    screenshot("la-demo.ppm");
    v.demo=false;
    v.state=LAV_WAIT;
    lav_draw(&v,NULL);
    screenshot("la-wait.ppm");
    v.divider=UINT32_MAX;
    lav_draw(&v,NULL);
    screenshot("la-fractional.ppm");
    puts("PASS LA view: bounds, zoom, pan, LE16, narrow pulse aggregation, 16-track renderer");
}
