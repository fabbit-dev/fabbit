`default_nettype none

// Runtime selection for ONE configured FPGA image. All signals share clk.
// system: 1 NES, 2 Mega Drive, 3 SNES. Never releases a core before COMMIT.
// BEGIN/ABORT immediately revoke run/stream ownership. PREP waits for every
// backend to drain, then requests FIFO flush. fifo_empty must acknowledge BOTH
// ends of the FIFO reset before READY; a local pointer reset alone is insufficient.
// PREP does not reset a memory controller mid-transaction: all_idle means all
// accepted writes/responses are retired. init_ready covers memory init/clearing.
// The caller must serialize commands (BEGIN wins over ABORT/COMMIT on one cycle).
// run dropping means QUIESCE: stop producing new requests, DRAIN adapters, then
// reset each console only when all_idle. Wiring !run directly to a core reset
// while it still has a pending write is not a safe physical handover.
module retro_control #(
    parameter logic [2:0] Systems = 3'b111,
    parameter logic [23:0] MaxBytes = 24'd4194304
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        begin_load,
    input  wire        abort_load,
    input  wire        commit_load,
    input  wire [1:0] system,
    input  wire [23:0] length,
    input  wire        all_idle,
    input  wire        fifo_empty,
    input  wire        init_ready,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [7:0] in_data,
    output wire        out_valid,
    input  wire        out_ready,
    output wire [7:0] out_data,
    input  wire        backend_done,
    input  wire        backend_fail,
    output wire        flush_fifo,
    output wire        ready,
    output wire        loading,
    output wire        done,
    output wire        failed,
    output wire [2:0] run,
    output wire [1:0] selected,
    output wire [23:0] received
);
  typedef enum logic [2:0] {Idle, Drain, Flush, Receive, WaitCommit, Running, Error} state_t;
  state_t state = Idle;
  logic [1:0] active = '0;
  logic [23:0] expected = '0, count = '0;
  wire known_system = system != 0 && Systems[system-1'b1];
  wire length_ok = length != 0 && length <= MaxBytes;
  wire cancelled = rst || begin_load || abort_load;
  wire accept_stream = !cancelled && !commit_load && state == Receive && !backend_fail;
  assign out_valid = accept_stream && in_valid;
  assign in_ready = accept_stream && out_ready;
  assign out_data = in_data;
  assign selected = active;
  assign received = count;
  assign flush_fifo = !rst && state == Flush;
  assign ready = !cancelled && state == Receive;
  assign loading = state == Drain || state == Flush || state == Receive || state == WaitCommit;
  assign done = !cancelled && state == Running;
  assign failed = state == Error;
  assign run = done ? (3'b001 << (active-1'b1)) : 3'b000;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= Idle;
      active <= '0;
      expected <= '0;
      count <= '0;
    end else if (begin_load) begin
      active <= system;
      expected <= length;
      count <= '0;
      state <= known_system && length_ok ? Drain : Error;
    end else if (abort_load) begin
      state <= Idle;
      count <= '0;
    end else begin
      case (state)
        Drain: if (all_idle) state <= Flush;
        Flush: if (all_idle && fifo_empty && init_ready) state <= Receive;
        Receive: begin
          if (backend_fail || commit_load) state <= Error;
          else if (in_valid && out_ready) begin
            count <= count + 1'b1;
            if (count + 1'b1 == expected) state <= WaitCommit;
          end
        end
        WaitCommit: begin
          if (backend_fail) state <= Error;
          else if (commit_load) state <= backend_done ? Running : Error;
        end
        Running: if (backend_fail) state <= Error;
        default: ;
      endcase
    end
  end
endmodule
