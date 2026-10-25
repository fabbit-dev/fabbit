`default_nettype none

// Видеотракт оболочки: общий тип «пиксель с координатами» и режимы развёртки.
//
// Тракт собирается из ступеней, каждая берёт vpx_t и отдаёт vpx_t на такте пикселя:
//   video_timing → источник (тест, ядро, скейлер) → наложение OSD → hdmi_tx / LCD.
// Синхро и координаты едут вместе с цветом, поэтому ступень с любой задержкой не ломает
// выравнивание, а ступени можно переставлять и выкидывать. Неиспользуемые поля синтез убирает.
package video_pkg;

  typedef struct packed {
    logic [11:0] x;    // столбец, 0 = первый видимый
    logic [11:0] y;    // строка
    logic        de;   // видимая область
    logic        hs;   // строчный синхроимпульс, уже с полярностью режима
    logic        vs;   // кадровый синхроимпульс
    logic        sof;  // первый пиксель кадра (x = 0, y = 0)
    logic [7:0]  r;
    logic [7:0]  g;
    logic [7:0]  b;
  } vpx_t;

  typedef struct packed {
    logic [11:0] h_active, h_front, h_sync, h_back;
    logic [11:0] v_active, v_front, v_sync, v_back;
    logic        h_pol, v_pol;  // 1 = синхроимпульс положительный
  } vmode_t;

  // CEA-861 VIC 1, пиксель 25,175 МГц (на стенде 25,0 или 25,1875 МГц, мониторы принимают)
  localparam vmode_t Vmode640x480 = '{
      h_active: 640, h_front: 16, h_sync: 96, h_back: 48,
      v_active: 480, v_front: 10, v_sync: 2, v_back: 33,
      h_pol: 1'b0, v_pol: 1'b0};

  // CEA-861 VIC 4, пиксель 74,25 МГц
  localparam vmode_t Vmode1280x720 = '{
      h_active: 1280, h_front: 110, h_sync: 40, h_back: 220,
      v_active: 720, v_front: 5, v_sync: 5, v_back: 20,
      h_pol: 1'b1, v_pol: 1'b1};

  // тот же пиксель (синхро, координаты) с новым цветом: так источник красит поток
  function automatic vpx_t vpx_rgb(input vpx_t p, input logic [7:0] r, input logic [7:0] g,
                                    input logic [7:0] b);
    vpx_t o;
    o = p;
    o.r = r;
    o.g = g;
    o.b = b;
    return o;
  endfunction

endpackage
