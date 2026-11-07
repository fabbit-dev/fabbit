`default_nettype none

// Masked logical writes over a full-word physical memory (i9+ DQM are tied low).
// One outstanding transaction, one clock domain. Addresses are 32-bit WORD indices.
// Each valid/ready pair transfers exactly once. Responses may stall indefinitely.
// This module owns the downstream port until the response is accepted, including
// both halves of read-modify-write. No other writer may bypass it during RMW.
// A zero write mask acknowledges without a physical transaction. Reads ignore mask.
// No memory timing or console deadline guarantee: those belong to the controller.
// Reset cancels this interface, NOT an accepted physical write. Reset the backend
// together, or drain it before asserting rst; never reset only one side mid-RMW.
module retro_mem_lanes #(
    parameter int AddrBits = 21
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                req_valid,
    output wire                req_ready,
    input  wire                req_write,
    input  wire [AddrBits-1:0] req_addr,
    input  wire [31:0]         req_wdata,
    input  wire [3:0]          req_mask,
    output wire                rsp_valid,
    input  wire                rsp_ready,
    output wire [31:0]         rsp_rdata,
    // Full-word controller port. Reads and writes both require a response.
    output wire                mem_valid,
    input  wire                mem_ready,
    output wire                mem_write,
    output wire [AddrBits-1:0] mem_addr,
    output wire [31:0]         mem_wdata,
    input  wire                mem_rsp_valid,
    output wire                mem_rsp_ready,
    input  wire [31:0]         mem_rdata
);
  typedef enum logic [2:0] {Idle, IssueRead, WaitRead, IssueWrite, WaitWrite, Reply} state_t;
  state_t state = Idle;
  logic [AddrBits-1:0] addr = '0;
  logic [31:0] data = '0, result = '0;
  logic [3:0] mask = '0;
  logic modify = 1'b0;

  assign req_ready = !rst && state == Idle;
  assign rsp_valid = !rst && state == Reply;
  assign rsp_rdata = result;
  assign mem_valid = !rst && (state == IssueRead || state == IssueWrite);
  assign mem_write = state == IssueWrite;
  assign mem_addr = addr;
  assign mem_wdata = data;
  assign mem_rsp_ready = !rst && (state == WaitRead || state == WaitWrite);

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= Idle;
      addr <= '0;
      data <= '0;
      result <= '0;
      mask <= '0;
      modify <= 1'b0;
    end else begin
      case (state)
        Idle: if (req_valid) begin
          addr <= req_addr;
          data <= req_wdata;
          mask <= req_mask;
          result <= '0;
          modify <= req_write;
          if (!req_write) state <= IssueRead;
          else if (req_mask == 4'b0000) state <= Reply;
          else if (req_mask == 4'b1111) state <= IssueWrite;
          else state <= IssueRead;
        end
        IssueRead: if (mem_ready) state <= WaitRead;
        WaitRead: if (mem_rsp_valid) begin
          result <= mem_rdata;
          if (modify) begin
            for (int lane = 0; lane < 4; lane++)
              if (!mask[lane]) data[lane*8+:8] <= mem_rdata[lane*8+:8];
            state <= IssueWrite;
          end else state <= Reply;
        end
        IssueWrite: if (mem_ready) state <= WaitWrite;
        WaitWrite: if (mem_rsp_valid) state <= Reply;
        Reply: if (rsp_ready) state <= Idle;
        default: state <= Idle;
      endcase
    end
  end
endmodule
