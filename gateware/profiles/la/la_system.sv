`default_nettype none

// CSR indices (32-bit BE via profile_shell); raw readback is sample-major LE16.
// 0 ID="FBLA", 1 CTRL={0x4C41, reserved[15:2], abort[1], arm[0]},
// 2 STATUS={bad_config[3],done[2],triggered[1],busy[0]}, 3 capacity, 4 base Hz,
// 5 total, 6 post (includes trigger), 7 divider (Fs=base/(divider+1)),
// 8 mask, 9 value, 10 rising mask, 11 falling mask, 12 captured samples,
// 13 trigger position, 14 capture epoch, 15 captured divider, 16 source (0=P2,1=counter),
// 17 captured source. Config writes during capture affect the next ARM only.
module la_system #(
    parameter int Depth = 131072,
    localparam int Aw = $clog2(Depth)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] probe,
    input  wire        csr_we,
    input  wire [ 7:0] csr_waddr,
    input  wire [31:0] csr_wdata,
    input  wire [ 7:0] csr_raddr,
    output logic [31:0] csr_rdata,
    input  wire [23:0] rb_addr,
    output wire [ 7:0] rb_data,
    output wire        capture_done
);
  localparam logic [15:0] CtrlKey = 16'h4C41;
  wire control = csr_we && csr_waddr == 8'd1 && csr_wdata[31:16] == CtrlKey;
  wire abort_capture = control && csr_wdata[1];
  wire arm = control && csr_wdata[0] && !csr_wdata[1];
  logic [31:0] cfg_total, cfg_post, cfg_divider;
  logic [15:0] cfg_mask, cfg_value, cfg_rise, cfg_fall;
  logic cfg_source;
  logic [31:0] divider, ticks, epoch;
  logic source_counter;
  logic [15:0] counter, sample_data;
  logic sample_valid;
  wire busy, triggered, done, bad_config;
  wire [31:0] count, trigger_index, first_sample;

  // First capture boundary is in the IOB. The fixed settling register is kept separate
  // from trigger/control; no glitch filtering and no combinational use of the first FF.
  (* IOB = "TRUE" *) logic [15:0] probe_iob;
  logic [15:0] probe_settled;
  always_ff @(posedge clk) begin
    probe_iob <= probe;
    probe_settled <= probe_iob;
  end

  always_ff @(posedge clk) begin
    sample_valid <= 1'b0;
    if (rst) begin
      cfg_total <= 32'(Depth);
      cfg_post <= 32'(Depth / 2);
      cfg_divider <= 32'd0;
      cfg_mask <= 16'd0;
      cfg_value <= 16'd0;
      cfg_rise <= 16'd0;
      cfg_fall <= 16'd0;
      cfg_source <= 1'b0;
      divider <= 32'd0;
      source_counter <= 1'b0;
      ticks <= 32'd0;
      counter <= 16'd0;
      sample_data <= 16'd0;
      epoch <= 32'd0;
    end else begin
      if (csr_we) begin
        case (csr_waddr)
          8'd5: cfg_total <= csr_wdata;
          8'd6: cfg_post <= csr_wdata;
          8'd7: cfg_divider <= csr_wdata;
          8'd8: cfg_mask <= csr_wdata[15:0];
          8'd9: cfg_value <= csr_wdata[15:0];
          8'd10: cfg_rise <= csr_wdata[15:0];
          8'd11: cfg_fall <= csr_wdata[15:0];
          8'd16: cfg_source <= csr_wdata[0];
          default: ;
        endcase
      end
      if (arm) begin
        divider <= cfg_divider;
        source_counter <= cfg_source;
        ticks <= 32'd0;
        counter <= 16'd0;
        epoch <= epoch + 32'd1;
      end else if (busy && !abort_capture) begin
        if (ticks == 0) begin
          sample_valid <= 1'b1;
          sample_data <= source_counter ? counter : probe_settled;
          counter <= counter + 16'd1;
          ticks <= divider;
        end else ticks <= ticks - 32'd1;
      end
    end
  end

  always_comb begin
    case (csr_raddr)
      8'd0: csr_rdata = "FBLA";
      8'd1: csr_rdata = 32'd0;
      8'd2: csr_rdata = {28'd0, bad_config, done, triggered, busy};
      8'd3: csr_rdata = 32'(Depth);
      8'd4: csr_rdata = 32'd100_000_000;
      8'd5: csr_rdata = cfg_total;
      8'd6: csr_rdata = cfg_post;
      8'd7: csr_rdata = cfg_divider;
      8'd8: csr_rdata = {16'd0, cfg_mask};
      8'd9: csr_rdata = {16'd0, cfg_value};
      8'd10: csr_rdata = {16'd0, cfg_rise};
      8'd11: csr_rdata = {16'd0, cfg_fall};
      8'd12: csr_rdata = count;
      8'd13: csr_rdata = trigger_index;
      8'd14: csr_rdata = epoch;
      8'd15: csr_rdata = divider;
      8'd16: csr_rdata = {31'd0, cfg_source};
      8'd17: csr_rdata = {31'd0, source_counter};
      default: csr_rdata = 32'd0;
    endcase
  end

  wire [Aw-1:0] physical_sample = Aw'(first_sample) + Aw'(rb_addr >> 1);
  wire [15:0] read_sample;
  wire address_valid = done && ({9'd0, rb_addr} < ({1'b0, count} << 1));
  logic read_valid, read_high;
  always_ff @(posedge clk) begin
    read_valid <= address_valid && !rst && !arm && !abort_capture;
    read_high <= rb_addr[0];
  end
  assign rb_data = (done && read_valid) ?
                   (read_high ? read_sample[15:8] : read_sample[7:0]) : 8'd0;
  assign capture_done = done;

  la_ring #(.FrameDepth(Depth)) u_ring (
      .clk(clk), .rst(rst), .arm(arm), .abort_capture(abort_capture),
      .cfg_total(cfg_total), .cfg_post(cfg_post), .cfg_mask(cfg_mask), .cfg_value(cfg_value),
      .cfg_rise(cfg_rise), .cfg_fall(cfg_fall),
      .sample_valid(sample_valid), .sample_data(sample_data),
      .busy(busy), .triggered(triggered), .done(done), .bad_config(bad_config),
      .sample_count(count), .trigger_index(trigger_index), .first_sample(first_sample),
      .read_enable(address_valid), .read_frame(physical_sample), .read_data(read_sample));
endmodule
