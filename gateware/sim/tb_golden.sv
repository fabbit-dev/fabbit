`default_nettype none
`timescale 1ns / 1ps

// qspi_slave + golden_core + модель флеша. ESP-master по QIO, SCK 10 МГц, 8 dummy.
module tb_golden;
  logic clk = 0;
  always #5 clk = ~clk;  // 100 МГц

  logic sck = 0, cs_n = 1;
  logic [3:0] m_out = 0;
  logic m_oe = 0;
  wire [3:0] d_bus;
  logic [3:0] s_out;
  logic s_oe;
  assign d_bus = m_oe ? m_out : (s_oe ? s_out : 4'bzzzz);

  logic hdr_valid, wr_valid, rd_req, frame_end, busy;
  logic [7:0] cmd, wr_data, rd_data, err, dbg_cmd;
  logic [23:0] addr;
  logic [31:0] bootsts;
  logic dbg_valid;
  wire f_cs, f_mosi, f_miso, f_wp, f_hold;

  logic [7:0] rd_start;
  logic rd_fall;
  qspi_slave u_q (
      .clk(clk), .rd_start(rd_start), .rd_fall(rd_fall), .sck(sck), .cs_n(cs_n), .d_in(d_bus), .d_out(s_out), .d_oe(s_oe),
      .hdr_valid(hdr_valid), .cmd(cmd), .addr(addr), .wr_valid(wr_valid), .wr_data(wr_data),
      .rd_req(rd_req), .rd_data(rd_data), .frame_end(frame_end));
  golden_core #(
      .PorBits(14)
  ) u_c (
      .clk(clk), .hdr_valid(hdr_valid), .cmd(cmd), .addr(addr), .wr_valid(wr_valid),
      .wr_data(wr_data), .rd_req(rd_req), .rd_data(rd_data), .frame_end(frame_end),
      .osd_busy(1'b0), .osd_shown(1'b0), .frames(16'h1234), .busy(busy), .err(err), .boot_status(bootsts), .dbg_cmd(dbg_cmd),
      .rd_start(rd_start), .rd_fall(rd_fall),
      .dbg_cmd_valid(dbg_valid), .flash_cs_n(f_cs), .flash_mosi(f_mosi), .flash_miso(f_miso),
      .flash_wp_n(f_wp), .flash_hold_n(f_hold));
  flash_model u_f (
      .sck(u_c.u_fe.u_phy.sck), .cs_n(f_cs), .mosi(f_mosi), .miso(f_miso));

  localparam real T = 100.0;  // период SCK, нс
  logic [7:0] buf_w[8192];
  logic [7:0] buf_r[8192];
  integer errors = 0;

  task automatic nib_out(input logic [3:0] n);
    m_out = n;
    #(T / 2) sck = 1;
    #(T / 2) sck = 0;
  endtask
  task automatic header(input logic [7:0] c, input logic [23:0] a);
    cs_n = 0;
    m_oe = 1;
    #(T / 2);
    nib_out(c[7:4]); nib_out(c[3:0]);
    for (int i = 5; i >= 0; i--) nib_out(a[i*4+:4]);
  endtask
  task automatic frame_end_t;
    m_oe = 0;
    #(T / 2) cs_n = 1;
    #(T * 2);
  endtask
  task automatic q_write(input logic [7:0] c, input logic [23:0] a, input integer n);
    header(c, a);
    for (int i = 0; i < n; i++) begin
      nib_out(buf_w[i][7:4]);
      nib_out(buf_w[i][3:0]);
    end
    frame_end_t();
  endtask
  task automatic q_read(input logic [7:0] c, input logic [23:0] a, input integer n);
    header(c, a);
    m_oe = 0;
    for (int i = 0; i < 8; i++) begin  // dummy
      #(T / 2) sck = 1;
      #(T / 2) sck = 0;
    end
    for (int i = 0; i < n; i++) begin
      #(T / 2) sck = 1;
      buf_r[i][7:4] = d_bus;
      #(T / 2) sck = 0;
      #(T / 2) sck = 1;
      buf_r[i][3:0] = d_bus;
      #(T / 2) sck = 0;
    end
    frame_end_t();
  endtask
  task automatic keyed(input logic [7:0] c, input logic [23:0] a);
    buf_w[0] = "F"; buf_w[1] = "B"; buf_w[2] = "K"; buf_w[3] = "Y";
    q_write(c, a, 4);
  endtask
  task automatic wait_idle;
    #(T * 4);
    while (busy) #(T);
  endtask
  task automatic param(input integer len, input integer off);
    buf_w[0] = 0; buf_w[1] = len[23:16]; buf_w[2] = len[15:8]; buf_w[3] = len[7:0];
    buf_w[4] = 0; buf_w[5] = 0; buf_w[6] = off[15:8]; buf_w[7] = off[7:0];
    q_write(8'h05, 0, 8);
  endtask
  function automatic logic [31:0] crc_upd(input logic [31:0] c, input logic [7:0] d);
    logic [31:0] x;
    x = c ^ {24'd0, d};
    for (int k = 0; k < 8; k++) x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
    crc_upd = x;
  endfunction
  task automatic check(input string what, input logic ok);
    if (!ok) begin
      errors++;
      $display("FAIL %s", what);
    end else $display("ok   %s", what);
  endtask

  logic [31:0] crc;
  logic [7:0] pat[300];
  initial begin
    $dumpfile("build/tb_golden.vcd");
    $dumpvars(0, tb_golden);
    wait_idle();
    // ID
    q_read(8'h01, 0, 8);
    check("ID FBGL", {buf_r[0], buf_r[1], buf_r[2], buf_r[3]} == "FBGL");
    // буфер
    for (int i = 0; i < 256; i++) buf_w[i] = 8'(i * 7 + 3);
    q_write(8'h03, 24'h000100, 256);
    q_read(8'h04, 24'h000100, 256);
    begin
      logic ok = 1;
      for (int i = 0; i < 256; i++) if (buf_r[i] !== buf_w[i]) ok = 0;
      check("BUF_W/BUF_R 256", ok);
    end
    // флеш: ID
    q_write(8'h14, 0, 0);
    wait_idle();
    q_read(8'h06, 0, 4);
    check("FL_ID C22018", {buf_r[1], buf_r[2], buf_r[3]} == 24'hC22018);
    // стирание, запись 300 байт через границу страницы
    for (int i = 0; i < 300; i++) pat[i] = 8'(i ^ 8'h5A);
    for (int i = 0; i < 300; i++) buf_w[i] = pat[i];
    q_write(8'h03, 24'h000000, 300);
    param(300, 0);
    check("PARAM err=0", err == 0);
    q_write(8'h10, 24'h400000, 0);
    #(T * 4);
    check("ERASE без ключа -> ErrKey", err == 5);
    keyed(8'h10, 24'h400000);
    wait_idle();
    check("ERASE err=0", err == 0);
    for (int i = 0; i < 300; i++) buf_w[i] = pat[i];
    q_write(8'h03, 24'h000000, 300);
    keyed(8'h11, 24'h4000F0);
    wait_idle();
    check("PROG err=0", err == 0);
    param(300, 24'h1000);
    q_write(8'h12, 24'h4000F0, 0);
    wait_idle();
    q_read(8'h04, 24'h001000, 300);
    begin
      logic ok = 1;
      for (int i = 0; i < 300; i++)
        if (buf_r[i] !== pat[i]) begin
          if (ok) $display("  READ @%0d got %h want %h", i, buf_r[i], pat[i]);
          ok = 0;
        end
      check("READ = записанное", ok);
    end
    q_write(8'h13, 24'h4000F0, 0);
    wait_idle();
    q_read(8'h06, 0, 4);
    crc = 32'hFFFFFFFF;
    for (int i = 0; i < 300; i++) crc = crc_upd(crc, pat[i]);
    crc = ~crc;
    check("CRC32", {buf_r[0], buf_r[1], buf_r[2], buf_r[3]} == crc);
    // WRSR: BP=0111 (нижние 4 МБ), CR=0F
    keyed(8'h16, 24'h000F1C);
    wait_idle();
    check("WRSR err=0", err == 0);
    keyed(8'h16, 24'h000F80);
    #(T * 4);
    check("WRSR SRWD -> ErrParam", err == 2);
    q_write(8'h15, 24'h000001, 0);
    wait_idle();
    check("RDCR err=0", err == 0);
    // защита golden
    keyed(8'h10, 24'h100000);
    #(T * 4);
    check("ERASE 0x100000 -> ErrProt", err == 1);
    // STATUS
    q_read(8'h02, 0, 8);
    check("STATUS err=1", buf_r[1] == 1);
    // BOOT
    keyed(8'h20, 24'h640000);
    #(T * 20);
    check("BOOT -> IPROG WBSTAR 0x640000",
          u_c.u_icap.u_icap.iprog && u_c.u_icap.u_icap.wbstar == 32'h640000);
    if (errors == 0) $display("ВСЁ OK");
    else $display("ОШИБОК: %0d", errors);
    $finish;
  end
  initial begin
    #50_000_000;
    $display("TIMEOUT");
    $finish;
  end
endmodule
