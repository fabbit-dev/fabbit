`default_nettype none
`timescale 1ns / 1ps

// profile_shell глазами ESP: ID, CSR_W/CSR_R (несколько слов подряд), STREAM (канал и байты),
// PAD (слово целиком, кадр не из 4 байт отброшен), ключ TUNE. Профиль в тесте: 16 регистров с записью и чтением, приёмник потока.
module tb_shell;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;  // 100 МГц
  initial #200ns rst = 0;

  logic sck = 0, cs_n = 1;
  logic [3:0] m_out = 0;
  logic m_oe = 0;
  wire [3:0] d_bus, s_out;
  wire s_oe;
  assign d_bus = m_oe ? m_out : (s_oe ? s_out : 4'bzzzz);

  wire csr_we, st_valid, irq, pad_stb;
  wire [31:0] pad;
  int pad_n = 0;
  always @(posedge clk) if (pad_stb) pad_n++;
  wire [7:0] csr_waddr, csr_raddr, st_chan, st_data;
  wire [31:0] csr_wdata;
  logic [31:0] regs [16];
  initial foreach (regs[i]) regs[i] = 32'hA000_0000 + i;
  always @(posedge clk) if (csr_we) regs[csr_waddr[3:0]] <= csr_wdata;
  wire [31:0] csr_rdata = regs[csr_raddr[3:0]];

  logic [7:0] st_got [$];
  logic [7:0] st_ch = 0;
  always @(posedge clk)
    if (st_valid) begin
      st_got.push_back(st_data);
      st_ch <= st_chan;
    end

  profile_shell #(.ProfileId(16'h0042)) dut (
      .clk(clk), .rst(rst), .esp_sck(sck), .esp_cs_n(cs_n), .d_in(d_bus), .d_out(s_out),
      .d_oe(s_oe), .irq(irq), .csr_we(csr_we), .csr_waddr(csr_waddr), .csr_wdata(csr_wdata),
      .csr_raddr(csr_raddr), .csr_rdata(csr_rdata), .st_valid(st_valid), .st_chan(st_chan),
      .st_data(st_data), .pad(pad), .pad_stb(pad_stb));

  // ---- ESP: quad SPI 10 МГц, 8 dummy, как fpga_link ----
  localparam time T = 100ns;
  logic [7:0] wbuf [256];
  logic [7:0] rbuf [256];
  int errors = 0;

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
  task automatic q_write(input logic [7:0] c, input logic [23:0] a, input int n);
    header(c, a);
    for (int i = 0; i < n; i++) begin
      nib_out(wbuf[i][7:4]);
      nib_out(wbuf[i][3:0]);
    end
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

  task automatic check(input bit ok, input string what);
    if (ok) $display("ok   %s", what);
    else begin
      $display("FAIL %s", what);
      errors++;
    end
  endtask

  function automatic logic [31:0] rword(input int i);
    return {rbuf[4*i], rbuf[4*i+1], rbuf[4*i+2], rbuf[4*i+3]};
  endfunction

  initial begin
    #1us;
    q_read(8'h01, 0, 8);
    check({rbuf[0], rbuf[1], rbuf[2], rbuf[3]} == "FBPR" && rbuf[6] == 8'h00 && rbuf[7] == 8'h42,
          $sformatf("ID: %s, профиль %02x%02x", {rbuf[0], rbuf[1], rbuf[2], rbuf[3]},
                    rbuf[6], rbuf[7]));

    q_read(8'h31, 24'h000002, 12);
    check(rword(0) == 32'hA000_0002 && rword(1) == 32'hA000_0003 && rword(2) == 32'hA000_0004,
          $sformatf("CSR_R 3 слова с 2: %08h %08h %08h", rword(0), rword(1), rword(2)));

    {wbuf[0], wbuf[1], wbuf[2], wbuf[3]} = 32'h1234_5678;
    {wbuf[4], wbuf[5], wbuf[6], wbuf[7]} = 32'hDEAD_BEEF;
    q_write(8'h30, 24'h000005, 8);
    check(regs[5] == 32'h1234_5678 && regs[6] == 32'hDEAD_BEEF && regs[7] == 32'hA000_0007,
          $sformatf("CSR_W 2 слова в 5: %08h %08h, соседний 7 цел", regs[5], regs[6]));
    q_read(8'h31, 24'h000005, 8);
    check(rword(0) == 32'h1234_5678 && rword(1) == 32'hDEAD_BEEF, "CSR_R читает записанное");

    for (int i = 0; i < 200; i++) wbuf[i] = 8'(i * 7 + 3);
    q_write(8'h32, 24'h000003, 200);
    begin
      bit ok;
      ok = st_got.size() == 200 && st_ch == 8'd3;
      foreach (st_got[i]) if (st_got[i] != 8'(i * 7 + 3)) ok = 0;
      check(ok, $sformatf("STREAM: %0d байт в канал %0d по порядку", st_got.size(), st_ch));
    end

    {wbuf[0], wbuf[1], wbuf[2], wbuf[3]} = 32'h0001_8011;
    q_write(8'h33, 0, 4);
    check(pad == 32'h0001_8011 && pad_n == 1,
          $sformatf("PAD: слово %08h, стробов %0d", pad, pad_n));
    {wbuf[0], wbuf[1], wbuf[2]} = 24'hFFFFFF;
    q_write(8'h33, 0, 3);
    {wbuf[0], wbuf[1], wbuf[2], wbuf[3], wbuf[4]} = 40'hFF_FFFF_FFFF;
    q_write(8'h33, 0, 5);
    check(pad == 32'h0001_8011 && pad_n == 1, "PAD из 3 и 5 байт отброшен");

    {wbuf[0], wbuf[1], wbuf[2], wbuf[3]} = "FBKZ";
    q_write(8'h07, 24'h000011, 4);
    check(dut.rd_start == 8'd16, "TUNE с неверным ключом не меняет выдачу");

    if (errors) $display("ОШИБОК %0d", errors);
    else $display("ВСЁ OK");
    $finish;
  end

endmodule
