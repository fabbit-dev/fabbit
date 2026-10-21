`default_nettype none

// Синхронизатор одного бита в домен clk: Stages триггеров с ASYNC_REG, без логики перед первым
// (UG949 «Synchronizer», Cummings SNUG 2008). Только для уровней и медленных флагов; многобитные
// данные — через fifo_async или рукопожатие.
module sync_bit #(
    parameter int Stages = 2,
    parameter bit Init = 1'b0
) (
    input  wire clk,
    input  wire d,
    output wire q
);
  (* ASYNC_REG = "TRUE" *) logic [Stages-1:0] s = {Stages{Init}};

  always_ff @(posedge clk) s <= {s[Stages-2:0], d};

  assign q = s[Stages-1];

endmodule
