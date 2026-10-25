// Real screen/controller, capture client and renderer against a fake FPGA link.
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fpga_link.h"
#include "la_capture.h"
#include "la_demo.h"
#include "la_screen.h"
#include "ui.h"

static uint8_t fb[UI_FB_SIZE];
static uint32_t regs[66];
static int locks, arms, aborts, plane_writes, show_writes, data_reads, allocations;
static int fail_alloc, fail_id, fail_read, fail_write, tear, wrong_profile, no_plane;
static uint32_t keys;
static int64_t clock_us;
static unsigned grayscale_seen[16][4];
static bool demo_enabled;
bool la_demo_active(void) { return demo_enabled; }
void la_demo_stop(void) { demo_enabled=false; }

void fl_lock(void) { locks++; }
void fl_unlock(void) { assert(locks); locks--; }
int64_t esp_timer_get_time(void) { clock_us += 300000; return clock_us; }
uint32_t in_state(void) { return keys; }
void *heap_caps_malloc(size_t n, int caps)
{
    (void)caps;
    allocations++;
    return fail_alloc ? NULL : malloc(n);
}
esp_err_t fl_id(fl_id_t *id)
{
    assert(locks);
    if (fail_id) return ESP_ERR_TIMEOUT;
    *id=(fl_id_t){.profile=wrong_profile ? 1 : LA_PROFILE_ID};
    strcpy(id->magic,"FBPR");
    return ESP_OK;
}
esp_err_t fl_csr_read(uint8_t index, uint32_t *v, size_t n)
{
    assert(locks && index+n<=66);
    memcpy(v,regs+index,n*sizeof *v);
    if (index==64 && no_plane) v[0]=0;
    return ESP_OK;
}
esp_err_t fl_csr_write(uint8_t index,const uint32_t *v,size_t n)
{
    assert(locks && index+n<=18);
    memcpy(regs+index,v,n*sizeof *v);
    if (index==1 && *v==(LA_KEY|1)) {
        arms++;
        regs[14]++;
        regs[2]=LA_BUSY;
        regs[12]=regs[13]=0;
        regs[15]=regs[7];
        regs[17]=regs[16];
    }
    if (index==1 && *v==(LA_KEY|2)) {
        aborts++;
        regs[2]=regs[12]=regs[13]=0;
    }
    return ESP_OK;
}
esp_err_t fl_read(uint8_t cmd,uint32_t offset,void *data,size_t size)
{
    assert(locks && cmd==FL_CMD_CAPTURE_R && size<=FL_BUF_SIZE);
    assert(offset+size<=regs[12]*2);
    data_reads++;
    if (fail_read) return ESP_ERR_TIMEOUT;
    for (size_t i=0;i<size;i++) {
        uint32_t address=offset+(uint32_t)i;
        uint16_t word=(uint16_t)(address/2);
        ((uint8_t *)data)[i]=(uint8_t)(word>>((address&1)*8));
    }
    if (tear) { tear=0; regs[14]++; }
    return ESP_OK;
}
esp_err_t fl_write(uint8_t cmd,uint32_t address,const void *data,size_t size)
{
    assert(locks && cmd==0x44 && size<=FL_BUF_SIZE);
    assert(!wrong_profile);
    if (fail_write) return ESP_ERR_TIMEOUT;
    const uint8_t *p=data;
    unsigned x=address&4095, y=address>>12, w=p[0]*256u+p[1], h=p[2]*256u+p[3];
    assert(x%8==0 && w%8==0 && x+w<=640 && y+h<=480 && size==4+w/8*h);
    for (unsigned yy=0;yy<h;yy++)
        for (unsigned xx=0;xx<w;xx++) {
            unsigned px=x+xx, py=y+yy;
            uint8_t nibble=fb[py*UI_STRIDE+px/2];
            nibble=(px&1) ? nibble&15 : nibble>>4;
            bool expected=nibble>=8;
            grayscale_seen[nibble][(py&1)*2+(px&1)]++;
            assert(!!(p[4+yy*w/8+xx/8]&(0x80u>>(xx&7)))==expected);
        }
    plane_writes++;
    return ESP_OK;
}
esp_err_t fl_osd_show(bool on)
{
    assert(locks && !wrong_profile && on);
    show_writes++;
    return ESP_OK;
}
static void press(in_key_t key)
{
    in_event_t event={.type=IN_PRESS,.key=key};
    la_screen_key(&event);
    assert(!locks);
}
static void finish(void)
{
    regs[2]=LA_TRIGGERED|LA_DONE;
    regs[12]=regs[5];
    regs[13]=regs[5]-regs[6];
}
int main(void)
{
    regs[0]=LA_MAGIC;
    regs[3]=131068;
    regs[4]=400000000;
    regs[64]=0x46424d56;
    ui_init(fb,NULL);
    fail_alloc=1;
    assert(!la_screen_attach());
    fail_alloc=0;
    no_plane=1;
    assert(!la_screen_attach());
    no_plane=0;
    assert(la_screen_attach());
    fail_write=1;
    assert(la_screen_tick() && !show_writes);  // never expose uninitialized RAM on failed first draw
    fail_write=0;
    assert(la_screen_tick() && plane_writes && show_writes && !arms && !locks);
    // Every gray level must map identically on both rows and both pixel parities.
    // The 104-row region crosses the 102-row transfer band boundary at full width.
    memset(grayscale_seen,0,sizeof grayscale_seen);
    for (int level=0;level<16;level++) ui_fill(level*40,180,40,104,(uint8_t)level);
    assert(ui_flush());
    for (int level=0;level<16;level++)
        for (int parity=0;parity<4;parity++) assert(grayscale_seen[level][parity]);
    // Dirty rectangles expand to byte boundaries without changing neighboring pixels.
    ui_fill(74,201,10,2,7);
    assert(ui_flush());
    ui_fill(74,201,10,2,8);
    assert(ui_flush());
    ui_fill(630,203,10,2,15);
    assert(ui_flush());
    press(IN_DOWN);
    press(IN_F3);  // rising D1
    keys=1u<<IN_FN;
    press(IN_F2);
    assert(!arms);
    keys=0;
    press(IN_F2);
    assert(arms==1 && regs[7]==39 && regs[10]==2 && !regs[11] && !regs[16]);
    assert(la_screen_tick());
    press(IN_F2);
    assert(aborts==1);
    assert(la_screen_tick());
    press(IN_F3);  // falling D1
    press(IN_F2);
    assert(arms==2 && regs[11]==2 && !regs[10]);
    finish();
    int before=data_reads;
    assert(la_screen_tick() && data_reads>before);
    before=data_reads;
    assert(la_screen_tick() && data_reads==before);  // no repeated download of unchanged freeze
    for (int i=0;i<9;i++) { press(IN_F4); assert(la_screen_tick()); }
    assert(arms==2);
    press(IN_RIGHT);
    assert(la_screen_tick());
    fail_read=1;
    demo_enabled=true;
    press(IN_F1);
    assert(la_screen_tick());
    assert(!demo_enabled);
    fail_read=0;
    assert(la_screen_tick());  // retry same epoch after bus failure
    fail_id=1;
    demo_enabled=true;
    assert(la_screen_tick());
    assert(!demo_enabled);
    fail_id=0;
    before=data_reads;
    assert(la_screen_tick() && data_reads>before);  // error state recovers even with same snapshot
    tear=1;
    press(IN_F1);
    assert(la_screen_tick());
    assert(la_screen_tick());  // discard torn window, recover with new epoch
    fail_write=1;
    press(IN_UP);
    assert(la_screen_tick());
    fail_write=0;
    before=plane_writes;
    assert(la_screen_tick() && plane_writes>before);  // dirty rectangles retry
    demo_enabled=true;
    la_screen_demo();
    press(IN_F2);
    assert(arms==3 && regs[10]==128 && !regs[11]);  // demo selects rising marker D7
    assert(la_screen_tick());
    wrong_profile=1;
    before=plane_writes;
    assert(!la_screen_tick() && plane_writes==before && !locks);
    assert(!demo_enabled);
    puts("PASS LA screen: attach, packing, input, ARM/STOP, trigger, zoom, tears, retry, profile exit");
}
