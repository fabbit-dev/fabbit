`default_nettype none

// CSR indices (32-bit BE via profile_shell); raw readback is sample-major LE16.
// 0 ID="FBLA", 1 CTRL={0x4C41, reserved[15:2], abort[1], arm[0]},
// 2 STATUS={bad_config[3],done[2],triggered[1],busy[0]}, 3 capacity, 4 base Hz,
// 5 total, 6 post (includes trigger), 7 divider (Fs=base/(divider+1)),
// 8 mask, 9 value, 10 rising mask, 11 falling mask, 12 captured samples,
// 13 trigger position, 14 capture epoch, 15 captured divider, 16 source (0=P2,1=counter),
// 17 captured source. Config writes during capture affect the next ARM only.
// Ddr/Serdes select 200/400 MS/s; K>1 reserves one complete frame in the ring.
module la_system #(
    parameter int Depth = 131072,
    parameter bit Ddr = 1'b0,
    parameter bit Serdes = 1'b0,
    localparam int K = Serdes ? 4 : (Ddr ? 2 : 1),
    localparam int LaneBits = $clog2(K),
    localparam int Frames = Depth / K,
    localparam int Aw = $clog2(Frames),
    localparam int Capacity = Depth - ((K > 1) ? K : 0),
    localparam int FillBits = (K > 1) ? $clog2(K) : 1
) (
    input  wire        clk,
    input  wire        clk_fast,
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
  initial begin
    if (Depth < 4*K || (Depth & (Depth-1)) != 0)
      $error("la_system requires power-of-two sample depth >= 4 frames");
  end
  localparam logic [15:0] CtrlKey = 16'h4C41;
  wire control = csr_we && csr_waddr == 8'd1 && csr_wdata[31:16] == CtrlKey;
  wire abort_capture = control && csr_wdata[1];
  wire arm = control && csr_wdata[0] && !csr_wdata[1];
  logic [31:0] cfg_total, cfg_post, cfg_divider;
  logic [15:0] cfg_mask, cfg_value, cfg_rise, cfg_fall;
  logic cfg_source;
  logic [31:0] divider, divider_tail, ticks, epoch;
  logic source_counter;
  logic [15:0] counter;
  logic [16*K-1:0] sample_data, packed_samples;
  logic [FillBits-1:0] fill;
  logic sample_valid;
  wire busy, triggered, done, bad_config;
  wire [31:0] count, trigger_index, first_sample;

  wire sampler_valid;
  wire [16*K-1:0] sampler_data;
  la_sampler #(.Ddr(Ddr), .Serdes(Serdes)) u_sampler (
      .clk(clk), .clk_fast(clk_fast), .rst(rst), .probe(probe),
      .valid(sampler_valid), .samples(sampler_data));

  // Decimate the chronological sample stream, not whole frames. Odd divisors must not
  // introduce alternating intervals. Pack selected samples back into K-wide BRAM frames.
  localparam int PhaseBits = $clog2(K+1);
  localparam int StepBits = 32 + 16 + 16*K + FillBits + 16*K + 1;
  wire [31:0] next_ticks;
  wire [15:0] next_counter;
  wire [16*K-1:0] next_packed, next_data;
  wire [FillBits-1:0] next_fill;
  wire next_valid;
  function automatic logic [StepBits-1:0] decimate(
      input logic [31:0] left,
      input logic [31:0] period,
      input logic [31:0] tail,
      input logic [15:0] count_in,
      input logic [16*K-1:0] packed_in,
      input logic [16*K-1:0] data_in,
      input logic [16*K-1:0] probes,
      input logic [FillBits-1:0] fill_in,
      input logic use_counter);
    logic [31:0] ticks_out;
    logic [16*K-1:0] packed_out, data_out;
    logic [FillBits-1:0] fill_out;
    logic valid_out;
    logic [K-1:0] selected;
    logic [PhaseBits-1:0] phase, selected_count;
    // Do the wide countdown once per frame. The dense case only uses a small phase
    // counter; never cascade K 32-bit subtract/reload chains through the sample path.
    selected = '0;
    phase = PhaseBits'(left);
    if (K == 1) begin
      selected[0] = (left == 0);
      ticks_out = (left == 0) ? period : left - 32'd1;
    end else if (left >= K) begin
      ticks_out = left - K;
    end else if ((64'(period) + 64'd1) >= 64'(K)) begin
      selected[FillBits'(left)] = 1'b1;
      ticks_out = tail + left;
    end else begin
      for (int j = 0; j < K; j++) begin
        if (phase == 0) begin
          selected[j] = 1'b1;
          phase = PhaseBits'(period);
        end else phase = phase - 1'b1;
      end
      ticks_out = 32'(phase);
    end
    selected_count = '0;
    packed_out = packed_in;
    fill_out = fill_in;
    data_out = data_in;
    valid_out = 1'b0;
    for (int j = 0; j < K; j++) begin
      if (selected[j]) begin
        packed_out[16*int'(fill_out)+:16] =
            use_counter ? (count_in + 16'(selected_count)) : probes[j*16+:16];
        if (fill_out == FillBits'(K-1)) begin
          data_out = packed_out;
          valid_out = 1'b1;
          fill_out = '0;
        end else fill_out = fill_out + 1'b1;
        selected_count = selected_count + 1'b1;
      end
    end
    return {ticks_out, count_in + 16'(selected_count), packed_out, fill_out, data_out, valid_out};
  endfunction
  assign {next_ticks, next_counter, next_packed, next_fill, next_data, next_valid} =
      decimate(ticks, divider, divider_tail, counter, packed_samples, sample_data,
               sampler_data, fill, source_counter);

  always_ff @(posedge clk) begin
    sample_valid <= 1'b0;
    if (rst) begin
      cfg_total <= 32'(Capacity);
      cfg_post <= 32'(Capacity / 2);
      cfg_divider <= 32'd0;
      cfg_mask <= 16'd0;
      cfg_value <= 16'd0;
      cfg_rise <= 16'd0;
      cfg_fall <= 16'd0;
      cfg_source <= 1'b0;
      divider <= 32'd0;
      divider_tail <= 32'd0;
      source_counter <= 1'b0;
      ticks <= 32'd0;
      counter <= 16'd0;
      sample_data <= '0;
      packed_samples <= '0;
      fill <= '0;
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
        divider_tail <= cfg_divider - (K-1);
        source_counter <= cfg_source;
        ticks <= 32'd0;
        counter <= 16'd0;
        fill <= '0;
        epoch <= epoch + 32'd1;
      end else if (busy && sampler_valid && !abort_capture) begin
        sample_valid <= next_valid;
        sample_data <= next_data;
        packed_samples <= next_packed;
        fill <= next_fill;
        counter <= next_counter;
        ticks <= next_ticks;
      end
    end
  end

  always_comb begin
    case (csr_raddr)
      8'd0: csr_rdata = "FBLA";
      8'd1: csr_rdata = 32'd0;
      8'd2: csr_rdata = {28'd0, bad_config, done, triggered, busy};
      8'd3: csr_rdata = 32'(Capacity);
      8'd4: csr_rdata = 32'(100_000_000 * K);
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

  wire [Aw+LaneBits-1:0] physical_sample =
      (Aw+LaneBits)'(first_sample) + (Aw+LaneBits)'(rb_addr >> 1);
  wire [16*K-1:0] read_frame;
  wire address_valid = done && ({9'd0, rb_addr} < ({1'b0, count} << 1));
  logic read_valid, read_high;
  logic [FillBits-1:0] read_lane;
  always_ff @(posedge clk) begin
    read_valid <= address_valid && !rst && !arm && !abort_capture;
    read_high <= rb_addr[0];
    read_lane <= (K > 1) ? FillBits'(physical_sample) : '0;
  end
  assign rb_data = (done && read_valid) ?
                   read_frame[16*int'(read_lane)+8*int'(read_high)+:8] : 8'd0;
  assign capture_done = done;

  la_ring #(.FrameDepth(Frames), .SamplesPerFrame(K)) u_ring (
      .clk(clk), .rst(rst), .arm(arm), .abort_capture(abort_capture),
      .cfg_total(cfg_total), .cfg_post(cfg_post), .cfg_mask(cfg_mask), .cfg_value(cfg_value),
      .cfg_rise(cfg_rise), .cfg_fall(cfg_fall),
      .sample_valid(sample_valid), .sample_data(sample_data),
      .busy(busy), .triggered(triggered), .done(done), .bad_config(bad_config),
      .sample_count(count), .trigger_index(trigger_index), .first_sample(first_sample),
      .read_enable(address_valid), .read_frame(Aw'(physical_sample >> LaneBits)),
      .read_data(read_frame));
endmodule
