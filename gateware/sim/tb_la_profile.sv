`default_nettype none
`timescale 1ns / 1ps

// Capture/readback through the real 10 MHz QSPI receiver, not direct register pokes.
module tb_la_profile #(
    parameter bit Ddr = 1'b0,
    parameter bit Serdes = 1'b0,
    localparam int K = Serdes ? 4 : (Ddr ? 2 : 1),
    localparam int Samples = 2048-((K > 1) ? K : 0),
    localparam int Post = Samples/2,
    localparam int First = 5000 - (Samples-Post)
);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic clk_fast = 1;
  always #2500ps clk_fast = ~clk_fast;
  initial #200ns rst = 0;
  logic sck = 0, cs_n = 1;
  logic [3:0] m_out = 0;
  logic m_oe = 0;
  wire [3:0] d_bus, s_out;
  wire s_oe;
  assign d_bus = m_oe ? m_out : (s_oe ? s_out : 4'bzzzz);
  wire csr_we;
  wire [7:0] csr_waddr, csr_raddr, rb_data;
  wire [23:0] rb_addr;
  wire [31:0] csr_wdata, csr_rdata;
  logic [15:0] probe = 0;
  int cycles = 0, last_sample_cycle = -1, expected_spacing = 0;
  always @(posedge clk) begin
    cycles++;
    if (dut.sample_valid && dut.busy && expected_spacing != 0) begin
      if (last_sample_cycle >= 0 && cycles-last_sample_cycle != expected_spacing)
        $fatal(1, "sample divider spacing %0d expected %0d",
               cycles-last_sample_cycle, expected_spacing);
      last_sample_cycle = cycles;
    end
  end
  profile_shell #(.ProfileId(16'h4C41), .Readback(1'b1)) u_shell (
      .clk(clk), .rst(rst), .esp_sck(sck), .esp_cs_n(cs_n), .d_in(d_bus), .d_out(s_out),
      .d_oe(s_oe), .irq(), .csr_we(csr_we), .csr_waddr(csr_waddr), .csr_wdata(csr_wdata),
      .csr_raddr(csr_raddr), .csr_rdata(csr_rdata), .st_valid(), .st_chan(), .st_data(),
      .pad(), .pad_stb(), .rb_addr(rb_addr), .rb_data(rb_data));
  la_system #(.Depth(2048), .Ddr(Ddr), .Serdes(Serdes)) dut (
      .clk(clk), .clk_fast(clk_fast), .rst(rst),
      .probe(probe), .csr_we(csr_we), .csr_waddr(csr_waddr),
      .csr_wdata(csr_wdata), .csr_raddr(csr_raddr), .csr_rdata(csr_rdata),
      .rb_addr(rb_addr), .rb_data(rb_data), .capture_done());

  localparam time T = 100ns;
  logic [7:0] rbuf [8192];
  task automatic nib_out(input logic [3:0] n);
    m_out = n;
    #(T / 2) sck = 1;
    #(T / 2) sck = 0;
  endtask
  task automatic header(input logic [7:0] c, input logic [23:0] a);
    cs_n = 0;
    m_oe = 1;
    #(T / 2);
    nib_out(c[7:4]);
    nib_out(c[3:0]);
    for (int i = 5; i >= 0; i--) nib_out(a[i*4+:4]);
  endtask
  task automatic fin();
    m_oe = 0;
    #(T / 2) cs_n = 1;
    #(T * 2);
  endtask
  task automatic write_csr(input logic [7:0] index, input logic [31:0] data);
    header(8'h30, {16'd0, index});
    for (int i = 7; i >= 0; i--) nib_out(data[4*i+:4]);
    fin();
  endtask
  task automatic q_read(input logic [7:0] c, input logic [23:0] a, input int n);
    header(c, a);
    m_oe = 0;
    for (int i = 0; i < 8; i++) begin
      #(T / 2) sck = 1;
      #(T / 2) sck = 0;
    end
    for (int i = 0; i < n; i++) begin
      #(T / 2) sck = 1;
      rbuf[i][7:4] = d_bus;
      #(T / 2) sck = 0;
      #(T / 2) sck = 1;
      rbuf[i][3:0] = d_bus;
      #(T / 2) sck = 0;
    end
    fin();
  endtask
  function automatic logic [31:0] rword(input int i);
    return {rbuf[4*i], rbuf[4*i+1], rbuf[4*i+2], rbuf[4*i+3]};
  endfunction
  task automatic expect_counter(input int byte_offset, input int n, input int first);
    for (int i = 0; i < n; i++) begin
      int expected;
      expected = (first + (byte_offset+i)/2) & 65535;
      if (((byte_offset+i) % 2) != 0) expected >>= 8;
      if (rbuf[i] !== 8'(expected))
        $fatal(1, "byte[%0d]=%02x expected %02x", byte_offset+i, rbuf[i], 8'(expected));
    end
  endtask

  initial begin
    #1us;
    q_read(8'h01, 0, 8);
    if (rword(0) != "FBPR" || {rbuf[6], rbuf[7]} != 16'h4C41) $fatal(1, "profile ID");
    q_read(8'h31, 0, 20);
    if (rword(0) != "FBLA" || rword(3) != Samples ||
        rword(4) != 100_000_000*K)
      $fatal(1, "LA capabilities");
    q_read(8'h34, 0, 32);
    foreach (rbuf[i]) if (i < 32 && rbuf[i] != 0) $fatal(1, "read before freeze leaked RAM");
    write_csr(16, 1);  // counter source
    write_csr(5, 32'(Samples));
    write_csr(6, 32'(Post));
    write_csr(8, 65535);
    write_csr(9, 5000);  // wrap ring twice before trigger
    write_csr(1, 32'hDEAD_0001);
    q_read(8'h31, 14, 4);
    if (rword(0) != 0) $fatal(1, "bad control key accepted");
    write_csr(1, 32'h4C41_0001);
    #100us;
    q_read(8'h31, 12, 24);
    if (rword(0) != Samples || rword(1) != Samples-Post ||
        rword(2) != 1 || rword(3) != 0 ||
        rword(5) != 1) $fatal(1, "snapshot metadata");
    q_read(8'h34, 0, 4096);
    expect_counter(0, Samples*2, First);
    for (int i = Samples*2; i < 4096; i++) if (rbuf[i] != 0) $fatal(1, "tail RAM leak");
    $display("ok   QSPI: DDR=%0d, samples=%0d, wrap, LE16, 4096-byte burst", Ddr, Samples);
    q_read(8'h34, 1023, 2031);
    expect_counter(1023, 2031, First);
    q_read(8'h34, 24'(Samples*2-3), 11);
    expect_counter(Samples*2-3, 3, First);
    for (int i = 3; i < 11; i++) if (rbuf[i] != 0) $fatal(1, "out-of-range RAM leak");
    q_read(8'h34, 24'hFF_FFFF, 4);
    if (rword(0) != 0) $fatal(1, "24-bit address range check/wrap");
    $display("ok   QSPI: unaligned random reads, repeat, end boundary, invalid addresses");
    // Real probe source and divider, single-sample trigger without prehistory.
    write_csr(16, 0);
    write_csr(5, 1);
    write_csr(6, 1);
    write_csr(7, 3);
    write_csr(8, 65535);
    write_csr(9, 32'h0000_A55A);
    probe = 16'hA55A;
    write_csr(1, 32'h4C41_0001);
    #1us;
    q_read(8'h34, 0, 4);
    if ({rbuf[1], rbuf[0]} != 16'hA55A || rbuf[2] != 0 || rbuf[3] != 0)
      $fatal(1, "physical probe sample");
    q_read(8'h31, 14, 8);
    if (rword(0) != 2 || rword(1) != 3) $fatal(1, "capture epoch/divider");
    write_csr(1, 32'h4C41_0002);
    q_read(8'h34, 0, 4);
    if (rword(0) != 0) $fatal(1, "abort did not invalidate data");
    write_csr(5, 0);
    write_csr(1, 32'h4C41_0001);
    q_read(8'h31, 2, 4);
    if (rword(0) != 8) $fatal(1, "invalid config status");
    // Change shadow config while armed: current capture must retain all original settings.
    write_csr(5, 16);
    write_csr(6, 8);
    write_csr(16, 1);
    write_csr(9, 10000);
    expected_spacing = 4;
    write_csr(1, 32'h4C41_0001);
    write_csr(5, 1);
    write_csr(6, 1);
    write_csr(7, 9);
    write_csr(9, 0);
    write_csr(16, 0);
    #500us;
    expected_spacing = 0;
    q_read(8'h31, 12, 24);
    if (rword(0) != 16 || rword(1) != 8 || rword(3) != 3 || rword(5) != 1)
      $fatal(1, "shadow config changed active capture");
    q_read(8'h34, 0, 32);
    expect_counter(0, 32, 9992);
    $display("ok   QSPI: shadow config isolated, sample interval exactly divider+1 clocks");
    $display("ok   QSPI: probe capture, divider snapshot, control key, abort/rearm, bad config");
    $display("ВСЁ OK");
    $display("ALL LA OK");
    $finish;
  end
  initial begin
    #10ms;
    $fatal(1, "TIMEOUT");
  end
endmodule
