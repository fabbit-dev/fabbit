`default_nettype none
`timescale 1ns / 1ps

module tb_la_plane;
  import video_pkg::*;
  logic clk = 0, clk_pix = 0, rst = 1;
  always #5 clk = ~clk;
  always #19.85 clk_pix = ~clk_pix;
  logic sck = 0, cs_n = 1;
  logic [3:0] master = 0;
  wire [3:0] dout;
  wire oe, header, wr, fin, shown;
  wire [7:0] command, data;
  wire [23:0] address, rb_addr;
  wire csr_we;
  wire [7:0] csr_waddr, csr_raddr, rb_data;
  wire [31:0] csr_wdata, csr_rdata;
  la_system #(.Depth(2048)) capture (
      .clk(clk), .clk_fast(clk), .rst(rst), .probe(16'hA55A),
      .csr_we(csr_we), .csr_waddr(csr_waddr), .csr_wdata(csr_wdata),
      .csr_raddr(csr_raddr), .csr_rdata(csr_rdata), .rb_addr(rb_addr),
      .rb_data(rb_data), .capture_done());
  profile_shell #(.Readback(1'b1)) shell (
      .clk(clk), .rst(rst), .esp_sck(sck), .esp_cs_n(cs_n), .d_in(master),
      .d_out(dout), .d_oe(oe), .irq(), .csr_we(csr_we), .csr_waddr(csr_waddr),
      .csr_wdata(csr_wdata), .csr_raddr(csr_raddr), .csr_rdata(csr_rdata),
      .st_valid(), .st_chan(), .st_data(), .pad(), .pad_stb(),
      .rb_addr(rb_addr), .rb_data(rb_data),
      .bus_header(header), .bus_command(command), .bus_address(address),
      .bus_write(wr), .bus_data(data), .bus_end(fin));
  vpx_t timing_px, px;
  video_timing timing (.clk(clk_pix), .rst(rst), .ce(1'b1), .px(timing_px));
  la_plane dut (.clk(clk), .rst(rst), .header(header), .command(command), .address(address),
                .write_valid(wr), .data(data), .frame_end(fin), .shown(shown),
                .clk_pix(clk_pix), .px_in(timing_px), .px_out(px));
  byte unsigned bytes_out[];
  task automatic nib(input logic [3:0] value);
    master = value;
    #50ns sck = 1;
    #50ns sck = 0;
  endtask
  task automatic start(input logic [7:0] cmd, input logic [23:0] addr);
    cs_n = 0;
    #50ns;
    nib(cmd[7:4]); nib(cmd[3:0]);
    for (int i = 5; i >= 0; i--) nib(addr[i*4+:4]);
  endtask
  task automatic finish_frame();
    #50ns cs_n = 1;
    #300ns;
  endtask
  task automatic write_frame(input logic [7:0] cmd, input logic [23:0] addr);
    start(cmd, addr);
    foreach (bytes_out[i]) begin nib(bytes_out[i][7:4]); nib(bytes_out[i][3:0]); end
    finish_frame();
  endtask
  task automatic csr(input logic [7:0] index, input logic [31:0] value);
    bytes_out = new[4];
    {bytes_out[0],bytes_out[1],bytes_out[2],bytes_out[3]} = value;
    write_frame(8'h30,{16'd0,index});
  endtask
  bit expected [480][640];
  task automatic rect(input int x, input int y, input int w, input int h, input int seed);
    int k = 4;
    bytes_out = new[4+w/8*h];
    {bytes_out[0], bytes_out[1], bytes_out[2], bytes_out[3]} = {16'(w),16'(h)};
    for (int yy = 0; yy < h; yy++) begin
      for (int xx = 0; xx < w; xx += 8) begin
        bytes_out[k] = 8'(xx*7+yy*13+seed);
        for (int b = 0; b < 8; b++)
          if (x%8 == 0 && w%8 == 0 && x+xx+b < 640 && y+yy < 480)
            expected[y+yy][x+xx+b] = bytes_out[k][7-b];
        k++;
      end
    end
    write_frame(8'h44, {12'(y),12'(x)});
  endtask
  logic [23:0] shot [480][640];
  int frames = 0;
  always @(posedge clk_pix) begin
    if (px.de) shot[px.y[8:0]][px.x[9:0]] <= {px.r, px.g, px.b};
    if (px.de && px.x == 639 && px.y == 479) frames++;
  end
  task automatic compare(input bit visible);
    int f = frames;
    wait (frames == f+2);
    #100ns;
    for (int y = 0; y < 480; y++)
      for (int x = 0; x < 640; x++)
        if (shot[y][x] !== {24{visible && expected[y][x]}})
          $fatal(1, "pixel %0d,%0d got %h expected %b", x,y,shot[y][x],expected[y][x]);
  endtask
  initial begin
    #200ns rst = 0;
    csr(5,2048);
    csr(6,1024);
    csr(16,1);
    csr(1,32'h4C41_0001);
    compare(0);
    rect(0,0,640,480,0);
    rect(0,0,640,1,240);
    rect(632,479,24,3,71);
    rect(4095,0,8,1,255);  // unaligned, rejected
    rect(4096-8,0,16,1,255);  // outside, no wrap
    rect(0,4095,8,2,255);
    bytes_out = new[3];
    {bytes_out[0],bytes_out[1],bytes_out[2]} = "FBK";
    write_frame(8'h43,1);
    if (shown) $fatal(1,"short control key");
    bytes_out = new[5];
    {bytes_out[0],bytes_out[1],bytes_out[2],bytes_out[3],bytes_out[4]} = {"FBKY",8'd0};
    write_frame(8'h43,1);
    if (shown) $fatal(1,"long control key");
    bytes_out = new[4];
    {bytes_out[0],bytes_out[1],bytes_out[2],bytes_out[3]} = "FBKY";
    write_frame(8'h43,1);
    if (!shown) $fatal(1,"control key rejected");
    compare(1);
    start(8'h34,24'h000013);
    repeat (8) begin #50ns sck = 1; #50ns sck = 0; end
    for (int i = 0; i < 37; i++) begin
      logic [7:0] value;
      #50ns sck = 1; value[7:4] = dout;
      #50ns sck = 0;
      #50ns sck = 1; value[3:0] = dout;
      #50ns sck = 0;
      if (!oe || value != (((19+i)%2 != 0) ? 8'(((19+i)/2)>>8) : 8'((19+i)/2)))
        $fatal(1,"readback with plane");
    end
    finish_frame();
    if (capture.epoch != 1 || !capture.done || capture.count != 2048 ||
        capture.trigger_index != 1024) $fatal(1,"plane traffic changed frozen capture");
    write_frame(8'h43,0);
    if (shown) $fatal(1,"disable");
    compare(0);
    write_frame(8'h43,1);
    #30ns rst = 1;
    #40ns;
    if (shown) $fatal(1,"reset must hide uninitialized plane");
    $display("LA PLANE PASS: QSPI, all pixels, clipping, key, capture readback, reset");
    $finish;
  end
  initial begin #250ms; $fatal(1,"TIMEOUT"); end
endmodule
