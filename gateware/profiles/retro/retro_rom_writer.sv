`default_nettype none

// Canonical ROM stream -> packed SDRAM words. First file byte is word bits 7:0.
// MD/SNES byte-lane extraction belongs to each console memory adapter.
// Last short word pads with FF; writes are always full words (DQM=0).
// start_valid/start_ready snapshots length and base word. Limit 4 MiB, with
// base+ceil(length/4) constrained to the 8-MiB physical word address space.
// ABORT stops input immediately but DRAINS an accepted/pending memory write.
// idle is safe for the switch controller only once this drain completes.
module retro_rom_writer (
    input  wire        clk,
    input  wire        rst,
    input  wire        start_valid,
    output wire        start_ready,
    input  wire [23:0] length,
    input  wire [20:0] base_word,
    input  wire        abort_load,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [7:0] in_data,
    output wire        idle,
    output wire        done,
    output wire        failed,
    output wire [23:0] received,
    output wire        mem_valid,
    input  wire        mem_ready,
    output wire [20:0] mem_addr,
    output wire [31:0] mem_wdata,
    input  wire        mem_rsp_valid,
    output wire        mem_rsp_ready
);
  typedef enum logic [2:0] {Idle, Collect, Issue, Wait, Finished, Error} state_t;
  state_t state = Idle;
  logic cancel = 1'b0;
  logic [23:0] count = '0, expected = '0;
  logic [20:0] address = '0;
  logic [31:0] data = '1;
  logic [1:0] lane = '0;
  wire [24:0] words = ({1'b0, length} + 25'd3) >> 2;
  wire [25:0] end_word = {5'b0, base_word} + {1'b0, words};
  wire valid_size = length != 0 && length <= 24'd4194304 && end_word <= 26'd2097152;
  assign start_ready = !rst && !abort_load &&
                       (state == Idle || state == Finished || state == Error);
  assign in_ready = !rst && !abort_load && state == Collect;
  assign idle = state == Idle || state == Finished || state == Error;
  assign done = !rst && !abort_load && state == Finished;
  assign failed = state == Error;
  assign received = count;
  assign mem_valid = !rst && state == Issue;
  assign mem_addr = address;
  assign mem_wdata = data;
  assign mem_rsp_ready = !rst && state == Wait;
  always_ff @(posedge clk) begin
    if (rst) begin
      state <= Idle;
      cancel <= 1'b0;
      count <= '0;
      expected <= '0;
      lane <= '0;
      data <= '1;
      address <= '0;
    end else begin
      if (start_valid && start_ready) begin
        count <= '0;
        expected <= length;
        address <= base_word;
        data <= '1;
        lane <= '0;
        cancel <= 1'b0;
        state <= valid_size ? Collect : Error;
      end else case (state)
        Collect: if (abort_load) state <= Idle;
        else if (in_valid) begin
          data[lane*8+:8] <= in_data;
          lane <= lane + 1'b1;
          count <= count + 1'b1;
          if (lane == 2'd3 || count + 1'b1 == expected) state <= Issue;
        end
        Issue: begin
          if (abort_load) cancel <= 1'b1;
          if (mem_ready) state <= Wait;
        end
        Wait: begin
          if (abort_load) cancel <= 1'b1;
          if (mem_rsp_valid) begin
            if (cancel || abort_load) state <= Idle;
            else if (count == expected) state <= Finished;
            else begin
              address <= address + 1'b1;
              data <= '1;
              lane <= '0;
              state <= Collect;
            end
          end
        end
        default: if (abort_load) state <= Idle;
      endcase
    end
  end
endmodule
