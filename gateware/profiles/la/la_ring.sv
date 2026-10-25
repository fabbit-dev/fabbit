`default_nettype none

// Raw capture: sample 0 is the oldest lane in each frame. Post includes the trigger sample.
// ARM snapshots configuration; prefill completes before a trigger is eligible. A spare frame
// at K>1 protects the oldest partial frame from the final full-frame BRAM write.
module la_ring #(
    parameter int Channels = 16,
    parameter int SamplesPerFrame = 1,  // power of two
    parameter int FrameDepth = 131072,  // power of two, >= 4
    localparam int FrameAw = $clog2(FrameDepth),
    localparam int LaneBits = $clog2(SamplesPerFrame),
    localparam int PointerBits = FrameAw + LaneBits,
    localparam int FrameWidth = Channels * SamplesPerFrame,
    localparam int Capacity = (FrameDepth - ((SamplesPerFrame > 1) ? 1 : 0)) * SamplesPerFrame
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  arm,
    input  wire                  abort_capture,
    input  wire [31:0]           cfg_total,
    input  wire [31:0]           cfg_post,
    input  wire [Channels-1:0]   cfg_mask,
    input  wire [Channels-1:0]   cfg_value,
    input  wire [Channels-1:0]   cfg_rise,
    input  wire [Channels-1:0]   cfg_fall,
    input  wire                  sample_valid,
    input  wire [FrameWidth-1:0] sample_data,
    output logic                 busy,
    output logic                 triggered,
    output logic                 done,
    output logic                 bad_config,
    output wire [31:0]           sample_count,
    output wire [31:0]           trigger_index,
    output logic [31:0]          first_sample,
    // Physical frame read, one clock latency. Only frozen captures are readable.
    input  wire                  read_enable,
    input  wire [FrameAw-1:0]    read_frame,
    output wire [FrameWidth-1:0] read_data
);
  initial begin
    if (Channels < 1 || FrameDepth < 4 || (FrameDepth & (FrameDepth-1)) != 0 ||
        SamplesPerFrame < 1 || (SamplesPerFrame & (SamplesPerFrame-1)) != 0)
      $error("la_ring requires positive width and power-of-two frame depth/lane count");
  end
  logic [31:0] total, post, pre_needed, pre_seen, remaining;
  logic [Channels-1:0] mask, value, rise_mask, fall_mask, previous;
  logic previous_valid;
  logic [FrameAw-1:0] write_frame;
  wire take = busy && sample_valid && !rst && !arm && !abort_capture;
  assign sample_count = done ? total : 32'd0;
  assign trigger_index = done ? total - post : 32'd0;

  ram_sdp #(.Width(FrameWidth), .Depth(FrameDepth)) u_mem (
      .wclk(clk), .we(take), .waddr(write_frame), .wdata(sample_data),
      .rclk(clk), .re(read_enable && done && !arm && !abort_capture && !rst),
      .raddr(read_frame), .rdata(read_data));

  logic hit;
  logic [31:0] hit_lane;
  always_comb begin
    hit = 1'b0;
    hit_lane = 32'd0;
    for (int j = 0; j < SamplesPerFrame; j++) begin : lane_match
      logic [Channels-1:0] current_sample, prior_sample;
      logic prior_valid, edges_match;
      current_sample = sample_data[j*Channels+:Channels];
      prior_sample = (j == 0) ? previous : sample_data[(j-1)*Channels+:Channels];
      prior_valid = (j != 0) || previous_valid;
      edges_match = ((rise_mask | fall_mask) == '0) ||
          (prior_valid && ((~prior_sample & current_sample & rise_mask) == rise_mask) &&
           ((prior_sample & ~current_sample & fall_mask) == fall_mask));
      if (!hit && (pre_seen + 32'(j) >= pre_needed) && edges_match &&
          (((current_sample ^ value) & mask) == '0)) begin
        hit = 1'b1;
        hit_lane = 32'(j);
      end
    end
  end

  // Number of samples up to the end of this frame's valid capture prefix.
  wire [31:0] end_count = triggered ? remaining : hit_lane + post;
  wire finish_frame = triggered ? (remaining <= SamplesPerFrame) :
                                  (hit && (post <= SamplesPerFrame - hit_lane));
  wire [31:0] frame_base = 32'(write_frame) << LaneBits;

  always_ff @(posedge clk) begin
    if (rst || abort_capture) begin
      busy <= 1'b0;
      triggered <= 1'b0;
      done <= 1'b0;
      bad_config <= 1'b0;
      first_sample <= 32'd0;
      previous_valid <= 1'b0;
    end else if (arm) begin
      busy <= 1'b0;
      triggered <= 1'b0;
      done <= 1'b0;
      bad_config <= (cfg_total == 0) || (cfg_total > Capacity) ||
                    (cfg_post == 0) || (cfg_post > cfg_total) || ((cfg_rise & cfg_fall) != '0);
      if ((cfg_total != 0) && (cfg_total <= Capacity) && (cfg_post != 0) &&
          (cfg_post <= cfg_total) && ((cfg_rise & cfg_fall) == '0)) busy <= 1'b1;
      total <= cfg_total;
      post <= cfg_post;
      pre_needed <= cfg_total - cfg_post;
      pre_seen <= 32'd0;
      remaining <= 32'd0;
      mask <= cfg_mask;
      value <= cfg_value;
      rise_mask <= cfg_rise;
      fall_mask <= cfg_fall;
      previous_valid <= 1'b0;
      previous <= '0;
      write_frame <= '0;
      first_sample <= 32'd0;
    end else if (take) begin
      write_frame <= write_frame + 1'b1;
      previous <= sample_data[(SamplesPerFrame-1)*Channels+:Channels];
      previous_valid <= 1'b1;
      if (pre_seen < pre_needed)
        pre_seen <= ((pre_needed - pre_seen) <= SamplesPerFrame) ? pre_needed :
                    pre_seen + SamplesPerFrame;
      if (!triggered && hit) begin
        triggered <= 1'b1;
        remaining <= post - (SamplesPerFrame - hit_lane);
      end else if (triggered) remaining <= remaining - SamplesPerFrame;
      if (finish_frame) begin
        busy <= 1'b0;
        done <= 1'b1;
        // Modulo is a power-of-two truncation, including wrap before physical address zero.
        first_sample <= 32'(PointerBits'(frame_base + end_count - total));
      end
    end
  end
endmodule
