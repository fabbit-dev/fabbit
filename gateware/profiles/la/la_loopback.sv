`default_nettype none

// Eight slow test outputs for an external P6 -> P2 loop. No internal bypass of input pads.
// CSR 32 CTRL: key 0x4C47, mode[2:1], enable[0]. 33 PERIOD: 100 MHz clocks/symbol,
// minimum 100 (<= 1 Msymbol/s). 34 VALUE: static byte / PRBS seed. 35 ID: "FBLG".
// PERIOD/VALUE writes are shadow settings. A keyed enable snapshots them and restarts.
// A disabled or reset generator presents high impedance, not a driven zero.
module la_loopback (
    input  wire        clk,
    input  wire        rst,
    input  wire        csr_we,
    input  wire [ 7:0] csr_waddr,
    input  wire [31:0] csr_wdata,
    input  wire [ 7:0] csr_raddr,
    output logic [31:0] csr_rdata,
    output logic       output_enable = 1'b0,
    output logic [7:0] data = 8'd0
);
  localparam logic [15:0] Key = 16'h4C47;
  logic [31:0] cfg_period = 32'd1000, period = 32'd1000, ticks = 32'd0;
  logic [7:0] cfg_value = 8'hA5;
  logic [1:0] mode = 2'd0;
  logic [3:0] walk = 4'd0;
  wire control = csr_we && csr_waddr == 8'd32 && csr_wdata[31:16] == Key;

  always_ff @(posedge clk) begin
    if (rst) begin
      output_enable <= 1'b0;
      data <= 8'd0;
      cfg_period <= 32'd1000;
      cfg_value <= 8'hA5;
      period <= 32'd1000;
      ticks <= 32'd0;
      mode <= 2'd0;
      walk <= 4'd0;
    end else begin
      if (csr_we && csr_waddr == 8'd33) cfg_period <= csr_wdata;
      if (csr_we && csr_waddr == 8'd34) cfg_value <= csr_wdata[7:0];
      if (control) begin
        output_enable <= csr_wdata[0];
        mode <= csr_wdata[2:1];
        period <= (cfg_period < 32'd100) ? 32'd100 : cfg_period;
        ticks <= ((cfg_period < 32'd100) ? 32'd100 : cfg_period) - 32'd1;
        walk <= 4'd0;
        case (csr_wdata[2:1])
          2'd0: data <= cfg_value;
          2'd1: data <= 8'd0;
          2'd2: data <= 8'd1;
          2'd3: data <= (cfg_value == 0) ? 8'hA5 : cfg_value;
          default: data <= 8'd0;
        endcase
      end else if (output_enable && mode != 0) begin
        if (ticks != 0) ticks <= ticks - 32'd1;
        else begin
          ticks <= period - 32'd1;
          case (mode)
            2'd1: data <= data + 8'd1;
            2'd2: begin
              walk <= walk + 4'd1;
              data <= (walk == 4'd15) ? 8'd1 :
                      (walk == 4'd7) ? 8'hFE :
                      ((walk < 4'd7) ? (data << 1) : ((data << 1) | 8'd1));
            end
            // x^8 + x^6 + x^5 + x^4 + 1, nonzero seed, period 255.
            2'd3: data <= {data[6:0], data[7] ^ data[5] ^ data[4] ^ data[3]};
            default: ;
          endcase
        end
      end
    end
  end

  always_comb begin
    case (csr_raddr)
      8'd32: csr_rdata = {29'd0, mode, output_enable};
      8'd33: csr_rdata = cfg_period;
      8'd34: csr_rdata = {24'd0, cfg_value};
      8'd35: csr_rdata = "FBLG";
      default: csr_rdata = 32'd0;
    endcase
  end
endmodule
