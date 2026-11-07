// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// One acknowledged bundled-data transfer. Source payload remains stable until
// destination completes it. Reset BOTH endpoints together, only while quiescent.
module retro_mailbox #(parameter int Width=32) (
    input wire sclk, srst, send,
    input wire [Width-1:0] data,
    output wire busy,
    input wire dclk, drst,
    output wire valid,
    output wire [Width-1:0] received,
    input wire complete
);
  logic request=0, acknowledge=0;
  logic [Width-1:0] payload='0;
  logic [Width-1:0] received_q='0;
  logic pending=0;
  wire ack_sync, req_sync;
  sync_bit ack_cdc (.clk(sclk), .d(acknowledge), .q(ack_sync));
  sync_bit req_cdc (.clk(dclk), .d(request), .q(req_sync));
  assign busy = request != ack_sync;
  assign valid = pending;
  assign received = received_q;
  always_ff @(posedge sclk)
    if (srst) begin request<=0; payload<='0; end
    else if (send && !busy) begin request<=~request; payload<=data; end
  always_ff @(posedge dclk)
    if (drst) begin acknowledge<=0;pending<=0;received_q<='0;end
    else if (!pending) begin
      if (req_sync != acknowledge) begin
        received_q<=payload;
        pending<=1;
      end
    end else if (complete) begin
      acknowledge<=req_sync;
      pending<=0;
    end
endmodule
`default_nettype wire
