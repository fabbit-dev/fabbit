`default_nettype none

// Full-word SDR SDRAM controller for the i9+ geometry: 4 banks x 2048 rows x
// 256 columns x 32 bits. DQM are physically tied low, so ALL writes are 32-bit.
// One request/response outstanding. Same-clock valid/ready interfaces, no CDC.
// Closed-page BL1/CAS3. Defaults are for a 100 MHz controller clock; override
// InitCycles/RefreshCycles for other rates. Never infer timing from simulation.
// These are simulation defaults, NOT an external SDRAM timing signoff.
// sd_clk is an externally forwarded, phase-adjusted copy of clk, NOT generated here.
// Capture phase and board I/O delays MUST be validated before hardware use.
// rst must reset the caller too: an accepted write cannot be undone by reset.
module retro_sdram #(
    parameter int InitCycles = 20000,  // >=200 us at 100 MHz
    parameter int RefreshCycles = 700,  // <=7 us at 100 MHz; scale for slower clk
    parameter int Trcd = 2,
    parameter int Trp = 2,
    parameter int Trfc = 7,
    parameter int Tras = 5,
    parameter int Twr = 2,
    parameter int Tmrd = 2,
    parameter int Cas = 3
) (
    input  wire        clk,
    input  wire        rst,
    output wire        initialized,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [20:0] req_addr,
    input  wire [31:0] req_wdata,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rsp_rdata,
    output logic [10:0] sd_a = '0,
    output logic [1:0] sd_ba = '0,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    input  wire [31:0] sd_dq_in,
    output wire [31:0] sd_dq_out,
    output wire        sd_dq_oe
);
  typedef enum logic [3:0] {
    PowerWait, InitRefOne, InitRefTwo, InitMode, InitDone,
    Idle, Column, Capture, WriteEnd, Precharge, Finish, Refresh
  } state_t;
  state_t state = PowerWait;
  logic [2:0] cmd = 3'b111;
  logic [31:0] dq_out = '0, result = '0;
  logic dq_oe = 1'b0, response = 1'b0, configured = 1'b0;
  logic [20:0] address = '0;
  logic write_req = 1'b0;
  int unsigned wait_left = InitCycles;
  int unsigned refresh_left = RefreshCycles;
  localparam logic [2:0] Nop = 3'b111, Pre = 3'b010, Ref = 3'b001;
  localparam logic [2:0] Mode = 3'b000, Act = 3'b011, Rd = 3'b101, Wr = 3'b100;
  localparam int WriteWait = Twr > Tras - Trcd ? Twr : Tras - Trcd;
  localparam int ReadPreWait = Tras > Trcd + Cas + 1 ? Tras - Trcd - Cas - 1 : 0;
  assign {sd_ras_n, sd_cas_n, sd_we_n} = cmd;
  assign sd_dq_out = dq_out;
  assign sd_dq_oe = dq_oe && !rst;
  assign initialized = configured && !rst;
  assign req_ready = !rst && state == Idle && !response && refresh_left != 0;
  assign rsp_valid = !rst && response;
  assign rsp_rdata = result;

  always_ff @(posedge clk) begin
    cmd <= Nop;
    dq_oe <= 1'b0;
    if (configured && refresh_left != 0) refresh_left <= refresh_left - 1;
    if (response && rsp_ready) response <= 1'b0;
    if (rst) begin
      state <= PowerWait;
      wait_left <= InitCycles;
      refresh_left <= RefreshCycles;
      configured <= 1'b0;
      response <= 1'b0;
      result <= '0;
      sd_a <= '0;
      sd_ba <= '0;
      cmd <= Nop;
    end else if (wait_left != 0) wait_left <= wait_left - 1;
    else case (state)
      PowerWait: begin
        cmd <= Pre;
        sd_a <= 11'b100_0000_0000;  // all banks
        wait_left <= Trp - 1;
        state <= InitRefOne;
      end
      InitRefOne: begin
        cmd <= Ref;
        wait_left <= Trfc - 1;
        state <= InitRefTwo;
      end
      InitRefTwo: begin
        cmd <= Ref;
        wait_left <= Trfc - 1;
        state <= InitMode;
      end
      InitMode: begin
        cmd <= Mode;
        sd_ba <= '0;
        sd_a <= 11'(Cas << 4);  // sequential BL1, programmed write burst
        wait_left <= Tmrd - 1;
        state <= InitDone;
      end
      InitDone: begin
        configured <= 1'b1;
        refresh_left <= RefreshCycles;
        state <= Idle;
      end
      Idle: begin
        if (refresh_left == 0) begin
          cmd <= Ref;
          refresh_left <= RefreshCycles;
          wait_left <= Trfc - 1;
          state <= Refresh;
        end else if (req_valid && !response) begin
          address <= req_addr;
          write_req <= req_write;
          dq_out <= req_wdata;
          sd_ba <= req_addr[20:19];
          sd_a <= req_addr[18:8];
          cmd <= Act;
          wait_left <= Trcd - 1;
          state <= Column;
        end
      end
      Column: begin
        cmd <= write_req ? Wr : Rd;
        sd_ba <= address[20:19];
        sd_a <= {3'b000, address[7:0]};  // explicit PRE, no auto-precharge
        dq_oe <= write_req;
        wait_left <= write_req ? WriteWait : Cas - 1;
        state <= write_req ? WriteEnd : Capture;
      end
      Capture: begin
        // CAS clk edges since registered READ command; phase validated separately.
        result <= sd_dq_in;
        // Keep capture at CAS. Delay only PRE when ACT->READ+CAS is shorter than tRAS.
        wait_left <= ReadPreWait;
        state <= Precharge;
      end
      WriteEnd: state <= Precharge;
      Precharge: begin
        cmd <= Pre;
        sd_a <= '0;
        sd_ba <= address[20:19];
        wait_left <= Trp - 1;
        state <= Finish;
      end
      Finish: begin
        response <= 1'b1;
        state <= Idle;
      end
      Refresh: state <= Idle;
      default: state <= PowerWait;
    endcase
  end
endmodule
