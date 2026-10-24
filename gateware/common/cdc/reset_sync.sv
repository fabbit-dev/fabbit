`default_nettype none

// Сброс домена clk: включается сразу (асинхронно), снимается синхронно через Stages тактов
// (Cummings, Mills, Golson SNUG 2003; UG949 «Synchronous Reset vs. Asynchronous Reset»).
// Выход подаётся на синхронные сбросы автоматов; датапуть и память не сбрасываются.
module reset_sync #(
    parameter int Stages = 4
) (
    input  wire clk,
    input  wire rst_in,   // любой домен, активный 1 (например, ~mmcm_locked)
    output wire rst_out
);
  (* ASYNC_REG = "TRUE" *) logic [Stages-1:0] s = '1;

  always_ff @(posedge clk or posedge rst_in)
    if (rst_in) s <= '1;
    else s <= {s[Stages-2:0], 1'b0};

  assign rst_out = s[Stages-1];

endmodule
