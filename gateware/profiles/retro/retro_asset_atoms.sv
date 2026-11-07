// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// CSR atom -> existing sequential asset stream. CLEAR opens a session; atom
// addresses must be consecutive. Completion includes final backend coverage.
module retro_asset_atoms (
    input wire clk,rst,valid,
    input wire [39:0] command,
    output logic complete=0,
    input wire stopped,
    output logic error=0,
    output logic start=0,
    output logic [1:0] channel=0,
    output logic byte_valid=0,
    input wire byte_ready,
    output logic [10:0] byte_addr=0,
    output logic [7:0] byte_data=0,
    output logic byte_last=0,
    input wire asset_busy,asset_done,
    input wire [2:0] asset_error
);
  import retro_regs_pkg::*;
  typedef enum logic [2:0] {Idle,ClearWait,First,Second,Final,Reply,Released} state_t;
  state_t state=Idle;
  logic [11:0] coefficient=0;
  logic [10:0] next_addr=0;
  logic session=0;
  logic [1:0] clear_age=0;
  always_ff @(posedge clk) begin
    start<=0;byte_valid<=0;complete<=0;
    if (rst) begin state<=Idle;session<=0;error<=0;next_addr<=0;clear_age<=0;end
    else case (state)
      Idle: if (valid) begin
        if (!stopped) begin error<=1;state<=Reply;end
        else if (command[7:0]==RegControl &&
                 command[8+ClearIplBit]==command[8+ClearCoeffBit]) begin
          // Exactly ONE CLEAR per sequential session. Reject both/no clear
          // without touching either backend validity map.
          error<=1;state<=Reply;
        end else if (command[7:0]==RegControl) begin
          channel<=command[8+ClearCoeffBit] ? 1 : 0;
          next_addr<=0;session<=1;error<=0;start<=1;state<=ClearWait;clear_age<=0;
        end else if (!session || (command[7:0]==RegIpl ? channel!=0 ||
                     command[21:16]!=next_addr[5:0] : channel!=1 ||
                     command[28:20]!=next_addr[9:1])) begin error<=1;session<=0;state<=Reply;end
        else begin
          byte_addr<=next_addr;byte_data<=command[15:8];coefficient<=command[19:8];
          byte_last<=channel==0 && next_addr==63;
          state<=First;
        end
      end
      ClearWait: if (clear_age<2) clear_age<=clear_age+1'b1;
                 else if (asset_error!=0) begin error<=1;session<=0;state<=Reply;end
                 else if (byte_ready) state<=Reply;
      First: if (byte_ready) begin
        byte_valid<=1;next_addr<=next_addr+1'b1;
        if (channel==1) state<=Second;
        else state<=byte_last ? Final : Reply;
      end
      Second: begin
        // Previous registered valid is consumed at this edge; wait one cycle
        // before launching high byte to avoid presenting an old address twice.
        byte_valid<=0;byte_addr<=next_addr;byte_data<={4'b0,coefficient[11:8]};
        byte_last<=next_addr==1023;state<=Final;
      end
      Final: begin
        if (channel==1 && !byte_valid && next_addr[0] && byte_ready) begin
          byte_valid<=1;next_addr<=next_addr+1'b1;
          if (!byte_last) state<=Reply;
        end else if (asset_done) begin session<=0;state<=Reply;end
        else if (asset_error!=0) begin error<=1;session<=0;state<=Reply;end
      end
      Reply: begin complete<=1;state<=Released;end
      Released: if (!valid) state<=Idle;
      default: state<=Idle;
    endcase
  end
endmodule
`default_nettype wire
