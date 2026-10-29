// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Static FBP profile 4. Real cores, common physical SDRAM, one presentation
// backend. ABI in retro_regs_pkg. No game/BIOS defaults. Never flash without
// passing implementation, board I/O timing and CDC gates.
// Audio snapshots feed one 48kHz bridge and HDMI packet backend, also CSR17.
// Per-console images: define RETRO_NO_NES / RETRO_NO_MD / RETRO_NO_SNES to omit
// a console at compile time (macros keep instance names stable for XDC and
// tests). RegCaps reports what remains. With exactly one console, its own
// SDRAM clock drives the pins directly: no BUFGCTRL owner tree. The MD
// management domain (session, writer, video bus) is always present.
`ifdef RETRO_NO_NES
`define RETRO_CAP_NES 1'b0
`else
`define RETRO_CAP_NES 1'b1
`endif
`ifdef RETRO_NO_MD
`define RETRO_CAP_MD 1'b0
`else
`define RETRO_CAP_MD 1'b1
`endif
`ifdef RETRO_NO_SNES
`define RETRO_CAP_SNES 1'b0
`else
`define RETRO_CAP_SNES 1'b1
`endif
`ifdef RETRO_NO_NES
`ifdef RETRO_NO_MD
`define RETRO_SINGLE
`elsif RETRO_NO_SNES
`define RETRO_SINGLE
`endif
`elsif RETRO_NO_MD
`ifdef RETRO_NO_SNES
`define RETRO_SINGLE
`endif
`endif
module retro_top #(
    // Hardware baseline from nes_clocks; model-only fixtures may override to
    // match tb_nes's documented 14.5ns launch phase, not board calibration.
    parameter real NesSdramPhase = 279.0
) (
    input wire clk,
    output wire led,uart_tx,
    input wire esp_sck,esp_cs_n,
    inout wire [3:0] esp_d,
    output wire esp_irq,
    output wire [3:0] hdmi_p,hdmi_n,
    output wire sdram_clk,
    output wire [10:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_ras_n,sdram_cas_n,sdram_we_n,
    inout wire [31:0] sdram_dq
);
  import retro_regs_pkg::*;
  localparam logic [2:0] Systems={`RETRO_CAP_SNES,`RETRO_CAP_MD,`RETRO_CAP_NES};
  localparam bit Single=Systems==3'b001 || Systems==3'b010 || Systems==3'b100;
  if (Systems==0) begin : g_no_console
    $error("retro_top: at least one console must remain");
  end
  wire bus_clk,bus_rst,csr_we,st_valid,pad_stb;
  wire [7:0] csr_waddr,csr_raddr,st_chan,st_data;
  wire [31:0] csr_wdata,pad_bus,csr_read;
  wire [31:0] csr_rdata=csr_raddr==17 ? audio_bus : csr_read;
  profile_bus #(.ProfileId(16'h0004),.UseIcap(1'b1)) u_bus (
      .clk_25m(clk),.esp_sck,.esp_cs_n,.esp_d,.esp_irq,.clk_bus(bus_clk),.rst_bus(bus_rst),
      .csr_we,.csr_waddr,.csr_wdata,.csr_raddr,.csr_rdata,.st_valid,.st_chan,.st_data,
      .pad(pad_bus),.pad_stb);
  // Three MMCM references cannot all use the clock pin's dedicated local path.
  // Distribute their reference globally; the bus PLL keeps its original input.
  wire clk_25m_reference;
  BUFG reference_buffer (.I(clk),.O(clk_25m_reference));
  wire md_clk,z80_clk,snes_source,md_sd_clock,md_locked;
  retro_clocks #(.Compensation("BUF_IN")) u_retroclk (
      .clk_25m(clk_25m_reference),.reset(bus_rst),.clk_md(md_clk),.clk_z80(z80_clk),
      .clk_snes(snes_source),.locked(md_locked),.clk_memory(md_sd_clock));
`ifndef RETRO_NO_NES
  wire nclk,nfclk,nes_sd_clock,nlocked;
  nes_clocks #(.SdramPhase(NesSdramPhase),.Compensation("BUF_IN")) u_nesclk (
      .clk_25m(clk_25m_reference),.psclk(bus_clk),.psen(1'b0),.psincdec(1'b0),
      .psdone(),.clk(nclk),.fclk(nfclk),.sdram_clk(nes_sd_clock),.locked(nlocked));
`else
  wire nclk=0,nfclk=0,nes_sd_clock=0,nlocked=0;
`endif
`ifndef RETRO_NO_SNES
  wire service,snes_master,snes_sd_clock,slocked,snes_master_ce;
  retro_snes_clocks u_snesclk (.clk_source(snes_source),.reset(!md_locked),
      .service,.master(snes_master),.memory_clock(snes_sd_clock),.locked(slocked),
      .master_ce(snes_master_ce));
`else
  wire service=0,snes_master=0,snes_sd_clock=0,slocked=0,snes_master_ce=0;
`endif
  wire clk_pix,clk_5x,rst_pix,vlocked;
  video_clocks #(.BufferedReference(1'b1)) u_vclk (
      .clk_25m(clk_25m_reference),.clk_pix,.clk_5x,.locked(vlocked),.rst_pix);
  wire rst_md,rst_nes,rst_service;
  reset_sync reset_md (.clk(md_clk),.rst_in(bus_rst || !md_locked),.rst_out(rst_md));
`ifndef RETRO_NO_NES
  reset_sync reset_nes (.clk(nclk),.rst_in(bus_rst || !nlocked),.rst_out(rst_nes));
`else
  assign rst_nes=1;
`endif
`ifndef RETRO_NO_SNES
  reset_sync reset_service (.clk(service),.rst_in(bus_rst || !slocked),.rst_out(rst_service));
`else
  assign rst_service=1;
`endif

  wire command_send,command_busy,command_valid,command_complete;
  wire [159:0] command_bus,command;
  wire [95:0] status,status_bus;
  wire [12:0] fifo_level;
  wire fifo_write,fifo_space,transport_bus,transport_md;
  retro_registers #(.Caps(Systems)) registers (
      .clk(bus_clk),.rst(bus_rst),.csr_we,.csr_waddr,.csr_raddr,
      .csr_wdata,.csr_rdata(csr_read),.command_send,.command_data(command_bus),.command_busy,
      .status(status_bus),.fifo_level,.st_valid,.st_chan,.fifo_ready(fifo_space),
      .stream_write(fifo_write),.transport_fault(transport_bus));
  retro_mailbox #(.Width(160)) commands (.sclk(bus_clk),.srst(bus_rst),.send(command_send),
      .data(command_bus),.busy(command_busy),.dclk(md_clk),.drst(rst_md),
      .valid(command_valid),.received(command),.complete(command_complete));
  cdc_word #(.Width(96)) status_transfer (.sclk(md_clk),.stb(status_tick),.d(status),
      .dclk(bus_clk),.q(status_bus),.q_stb());
  logic [3:0] status_divider=0;
  wire status_tick=status_divider==0;
  always_ff @(posedge md_clk) status_divider<=status_divider+1'b1;
  sync_bit fault_transfer (.clk(md_clk),.d(transport_bus),.q(transport_md));
  wire [31:0] pad_md,pad_nes,pad_snes;
`ifndef RETRO_NO_MD
  cdc_word #(.Width(32)) pads_md (.sclk(bus_clk),.stb(pad_stb),.d(pad_bus),.dclk(md_clk),
      .q(pad_md),.q_stb());
`else
  assign pad_md=0;
`endif
`ifndef RETRO_NO_NES
  cdc_word #(.Width(32)) pads_nes (.sclk(bus_clk),.stb(pad_stb),.d(pad_bus),.dclk(nclk),
      .q(pad_nes),.q_stb());
`else
  assign pad_nes=0;
`endif
`ifndef RETRO_NO_SNES
  cdc_word #(.Width(32)) pads_snes (.sclk(bus_clk),.stb(pad_stb),.d(pad_bus),.dclk(snes_master),
      .q(pad_snes),.q_stb());
`else
  assign pad_snes=0;
`endif
  function automatic logic [11:0] generic_pad(input logic [15:0] p);
    return {p[15],p[14],p[9:8],p[7:4],p[3:0]};
  endfunction

  wire [1:0] selected,owner_request,owner;
  wire controllers_reset,owner_busy,running,loading,ready,payload_done,switching;
  wire nes_freeze,nes_run,md_run,snes_run;
  wire md_stopped,snes_stopped,writer_idle,md_cdc_idle;
  wire [23:0] length,rom_size,received;
  wire [17:0] save_size;
  wire [4:0] map_config;
  wire flush,nes_load,writer_start,writer_abort;
  wire stream_valid,stream_ready,backend_ready,backend_done,backend_fail;
  wire [7:0] stream_data,error;
  wire [1:0] assets_md;
  wire asset_command,asset_complete,asset_failed;
  wire nes_done_md,nes_fail_md,nes_ready_md,md_memory_ready,snes_ready_md;
  retro_session #(.Caps(Systems)) session (
      .clk(md_clk),.rst(rst_md),.command_valid,.command,.command_complete,
      .transport_fault(transport_md),.selected,.owner_request,.owner,.owner_busy,
      .controllers_reset,.running,.loading,.ready,.payload_done,.switching,
      .nes_freeze,.nes_run,.md_run,.snes_run,.md_stopped,.snes_stopped,
      .writer_idle,.md_memory_idle(md_cdc_idle),.nes_done(nes_done_md),.nes_fail(nes_fail_md),
      .nes_memory_ready(nes_ready_md),.md_memory_ready,.snes_memory_ready(snes_ready_md),
      .assets_ready(assets_md),.length,.rom_size,.save_size,.map_config,.flush,.nes_load,
      .writer_start,.writer_abort,.stream_valid,.stream_ready,.backend_ready,.backend_done,
      .backend_fail,.received,.error,.status,.asset_command,.asset_complete,.asset_failed);
  wire flush_bus,flush_nes,flush_service;
  sync_bit flush_bus_sync (.clk(bus_clk),.d(flush_hold!=0),.q(flush_bus));
`ifndef RETRO_NO_NES
  sync_bit flush_nes_sync (.clk(nclk),.d(flush_hold!=0),.q(flush_nes));
`else
  assign flush_nes=0;
`endif
`ifndef RETRO_NO_SNES
  sync_bit flush_service_sync (.clk(service),.d(flush_hold!=0),.q(flush_service));
`else
  assign flush_service=0;
`endif
  logic [5:0] flush_hold=0;
  always_ff @(posedge md_clk)
    if (flush) flush_hold<=63;else if (flush_hold!=0) flush_hold<=flush_hold-1'b1;
  // One ROM FIFO write port, MD-domain reader; byte delivery to NES is acknowledged.
  fifo_async #(.Width(8),.Depth(4096)) rom_fifo (.wclk(bus_clk),.wrst(bus_rst || flush_bus),
      .in_valid(fifo_write),.in_ready(fifo_space),.in_data(st_data),.wlevel(fifo_level),
      .rclk(md_clk),.rrst(rst_md || flush_hold!=0),.out_valid(stream_valid),
      .out_ready(stream_ready),.out_data(stream_data));

  // Console boundary nets; an omitted console ties its side idle below.
  wire nes_rst_control,nes_freeze_n,nes_run_n;
  wire byte_busy;
  wire nloading,ndone,nfail,nreset,nmemory_busy,nwe;
  wire [7:0] nx,ny,njoy;
  wire [8:0] nindex,nline;
  wire [15:0] naudio;
  wire [31:0] dq_in,n_dq_out,m_dq_out,s_dq_out;
  wire n_dq_oe,m_dq_oe,s_dq_oe,m_dq_oe_next;
  wire [31:0] md_dq_in;
  wire [10:0] n_a,m_a,s_a;
  wire [1:0] n_ba,m_ba,s_ba;
  wire [2:0] n_cmd,m_cmd,s_cmd;
`ifndef RETRO_NO_NES
  sync_bit nreset_sync (.clk(nclk),.d(controllers_reset),.q(nes_rst_control));
  sync_bit nfreeze_sync (.clk(nclk),.d(nes_freeze),.q(nes_freeze_n));
  sync_bit nrun_sync (.clk(nclk),.d(nes_run),.q(nes_run_n));
  wire nload;
  cdc_word #(.Width(1)) load_nes (.sclk(md_clk),.stb(nes_load),.d(1'b1),.dclk(nclk),
      .q(),.q_stb(nload));
  wire nbyte_valid;
  wire [7:0] nbyte;
  wire nbyte_ready;
  retro_mailbox #(.Width(8)) nes_stream (.sclk(md_clk),.srst(rst_md),
      .send(selected==1 && stream_valid && stream_ready),.data(stream_data),.busy(byte_busy),
      .dclk(nclk),.drst(rst_nes),.valid(nbyte_valid),.received(nbyte),
      .complete(nbyte_ready || !nloading));
  wire unused_nclock;
  nes_pad n_pad (.clk(nclk),.frame(nwe && nx==0 && ny==0),.pad(pad_nes[15:0]),.joy(njoy));
  nes_system #(.Managed(1'b1),.SplitDq(1'b1)) nes (
      .nclk,.fclk(nfclk),.sdram_clk_in(nes_sd_clock),.rst(rst_nes || nes_rst_control),
      .load_go(nload),.reset_go(1'b0),.rom_valid(nbyte_valid),.rom_ready(nbyte_ready),
      .rom_data(nbyte),.joy(njoy),.loading(nloading),.loader_done(ndone),.loader_fail(nfail),
      .reset_nes(nreset),.fb_we(nwe),.fb_x(nx),.fb_y(ny),.fb_d(nindex),.sample(naudio),
      .scanline(nline),.sdram_clk(unused_nclock),.sdram_a(n_a),.sdram_ba(n_ba),
      .sdram_ras_n(n_cmd[2]),.sdram_cas_n(n_cmd[1]),.sdram_we_n(n_cmd[0]),.sdram_dq(),
      .core_freeze(nes_freeze_n),.run_enable(nes_run_n),.memory_busy(nmemory_busy),
      .dq_input(dq_in),.dq_output(n_dq_out),.dq_drive(n_dq_oe));
  sync_bit ndone_sync (.clk(md_clk),.d(ndone),.q(nes_done_md));
  sync_bit nfail_sync (.clk(md_clk),.d(nfail),.q(nes_fail_md));
  sync_bit nready_sync (.clk(md_clk),.d(!nmemory_busy && !nes_rst_control),.q(nes_ready_md));
`else
  assign nes_rst_control=1;assign nes_freeze_n=0;assign nes_run_n=0;assign byte_busy=0;
  assign nloading=0;assign ndone=0;assign nfail=0;assign nreset=0;assign nmemory_busy=0;
  assign nwe=0;assign nx=0;assign ny=0;assign njoy=0;assign nindex=0;assign nline=0;
  assign naudio=0;assign n_dq_out=0;assign n_dq_oe=0;assign n_a=0;assign n_ba=0;
  assign n_cmd=3'b111;
  assign nes_done_md=0;assign nes_fail_md=0;assign nes_ready_md=0;
`endif

  wire md_req,md_write,md_req_ready,md_rsp,md_rsp_ready,md_fault;
  wire [20:0] md_addr;
  wire [31:0] md_data,md_rdata;
  wire [3:0] md_mask,mr,mg,mb;
  wire mpixel,mhs,mvs,mhde,mvde,minterlace;
  wire [1:0] mresolution;
  wire [15:0] maudio_l,maudio_r;
`ifndef RETRO_NO_MD
  retro_md_machine md (.clk(md_clk),.z80_clk,.rst(rst_md || controllers_reset),.run(md_run),
      .loading(!controllers_reset && selected==2 && md_stopped && !md_run),
      .pad1(generic_pad(pad_md[15:0])),.pad2(generic_pad(pad_md[31:16])),
      .rom_words({1'b0,rom_size[23:1]}),.stopped(md_stopped),.req_valid(md_req),
      .req_write(md_write),.req_addr(md_addr),.req_wdata(md_data),.req_mask(md_mask),
      .req_ready(md_req_ready),.rsp_valid(md_rsp),.rsp_ready(md_rsp_ready),.rsp_rdata(md_rdata),
      .fault(md_fault),.red(mr),.green(mg),.blue(mb),.pixel_ce(mpixel),.hs_n(mhs),.vs_n(mvs),
      .hde(mhde),.vde(mvde),.interlace(minterlace),.resolution(mresolution),
      .audio_l(maudio_l),.audio_r(maudio_r));
`else
  assign md_req=0;assign md_write=0;assign md_addr=0;assign md_data=0;assign md_mask=0;
  assign md_rsp_ready=0;assign md_fault=0;assign mr=0;assign mg=0;assign mb=0;
  assign mpixel=0;assign mhs=1;assign mvs=1;assign mhde=0;assign mvde=0;assign minterlace=0;
  assign mresolution=0;assign maudio_l=0;assign maudio_r=0;assign md_stopped=1;
`endif

  wire writer_ready,writer_in_ready,writer_done,writer_fail,w_valid,w_ready,w_rsp,w_rsp_ready;
  wire [20:0] w_addr;
  wire [31:0] w_data;
  retro_rom_writer writer (.clk(md_clk),.rst(rst_md),.start_valid(writer_start),
      .start_ready(writer_ready),.length,.base_word(21'b0),.abort_load(writer_abort),
      .in_valid(selected!=1 && stream_valid && ready),.in_ready(writer_in_ready),
      .in_data(stream_data),.idle(writer_idle),.done(writer_done),.failed(writer_fail),
      .received(),.mem_valid(w_valid),.mem_ready(w_ready),.mem_addr(w_addr),.mem_wdata(w_data),
      .mem_rsp_valid(w_rsp),.mem_rsp_ready(w_rsp_ready));
  assign backend_ready=selected==1 ? !byte_busy : writer_in_ready;
  assign backend_done=selected==1 ? nes_done_md && !byte_busy : writer_done;
  assign backend_fail=selected==1 ? nes_fail_md && received!=0 :
                      ((loading && writer_fail) || (selected==2 && md_fault)) ||
                      (selected==3 && snes_failure_md && running);

`ifndef RETRO_NO_MD
  wire [1:0] fabric_ready,fabric_rsp;
  wire [31:0] fabric_rdata;
  wire fabric_valid,fabric_mem_ready,fabric_write,fabric_response,fabric_response_ready;
  wire [20:0] fabric_addr;
  wire [31:0] fabric_data;
  wire [3:0] fabric_mask;
  wire fabric_idle;
  retro_mem_mux fabric (.clk(md_clk),.rst(rst_md),.owner(!writer_idle ? 2'd2 : 2'd1),
      .idle(fabric_idle),.req_valid({w_valid && selected==2,md_req}),.req_ready(fabric_ready),
      .req_write({1'b1,md_write}),.req_addr('{md_addr,w_addr}),.req_wdata('{md_data,w_data}),
      .req_mask('{md_mask,4'b1111}),.rsp_valid(fabric_rsp),
      .rsp_ready({w_rsp_ready,md_rsp_ready}),.rsp_rdata(fabric_rdata),
      .mem_valid(fabric_valid),.mem_ready(fabric_mem_ready),.mem_write(fabric_write),
      .mem_addr(fabric_addr),.mem_wdata(fabric_data),.mem_mask(fabric_mask),
      .mem_rsp_valid(fabric_response),.mem_rsp_ready(fabric_response_ready),
      .mem_rdata(physical_rdata));
  assign md_req_ready=fabric_ready[0];assign md_rsp=fabric_rsp[0];assign md_rdata=fabric_rdata;
  wire physical_valid,physical_ready,physical_write,physical_rsp,physical_rsp_ready;
  wire [20:0] physical_addr;
  wire [31:0] physical_data,physical_rdata;
  retro_mem_lanes lanes (.clk(md_clk),.rst(rst_md || controllers_reset),
      .req_valid(fabric_valid),.req_ready(fabric_mem_ready),.req_write(fabric_write),
      .req_addr(fabric_addr),.req_wdata(fabric_data),.req_mask(fabric_mask),
      .rsp_valid(fabric_response),.rsp_ready(fabric_response_ready),.rsp_rdata(physical_rdata),
      .mem_valid(physical_valid),.mem_ready(physical_ready),.mem_write(physical_write),
      .mem_addr(physical_addr),.mem_wdata(physical_data),.mem_rsp_valid(physical_rsp),
      .mem_rsp_ready(physical_rsp_ready),.mem_rdata(memory_read));
  wire [31:0] memory_read;
  // Conditional ESMT(2S) -7 protocol budget: RCD/RP21ns, RFC63ns,
  // RAS42ns, write-to-PRE two FULL clocks. Fitted grade/board eye unknown.
  retro_sdram #(.InitCycles(10740),.RefreshCycles(375),.Trcd(2),.Trp(2),.Trfc(4),
      .Tras(3),.Twr(2),.Tmrd(2),.Cas(3),.PadPhy(Systems==3'b010)) md_memory (
      .clk(md_clk),.rst(rst_md || controllers_reset || selected!=2),
      .initialized(md_memory_ready),.req_valid(physical_valid),.req_ready(physical_ready),
      .req_write(physical_write),.req_addr(physical_addr),.req_wdata(physical_data),
      .rsp_valid(physical_rsp),.rsp_ready(physical_rsp_ready),.rsp_rdata(memory_read),
      .sd_a(m_a),.sd_ba(m_ba),.sd_ras_n(m_cmd[2]),.sd_cas_n(m_cmd[1]),.sd_we_n(m_cmd[0]),
      .sd_dq_in(md_dq_in),.sd_dq_out(m_dq_out),.sd_dq_oe(m_dq_oe),.sd_dq_oe_next(m_dq_oe_next));
`else
  wire [1:0] fabric_ready=0,fabric_rsp=0;
  wire fabric_idle=1;
  assign md_req_ready=0;assign md_rsp=0;assign md_rdata=0;assign md_memory_ready=0;
  assign m_a=0;assign m_ba=0;assign m_cmd=3'b111;assign m_dq_out=0;assign m_dq_oe=0;
  assign m_dq_oe_next=0;
`endif
  assign md_cdc_idle=fabric_idle && host_bridge_idle && !byte_busy;

`ifndef RETRO_NO_SNES
  wire snes_run_s,controller_reset_s;
  sync_bit srun_sync (.clk(service),.d(snes_run),.q(snes_run_s));
  sync_bit sreset_sync (.clk(service),.d(controllers_reset || selected!=3),.q(controller_reset_s));
  wire snes_stop_s,snes_initialized_s,snes_active,snes_hold,snes_ipl,snes_coeff;
  wire [4:0] snes_unsupported;
  wire [3:0] snes_overrun;
  wire snes_protocol,snes_failure_md;
  // Deadline is a wall-clock diagnostic, not fatal under legitimate clock hold.
  sync_bit snes_failure_sync (.clk(md_clk),
      .d((|snes_unsupported) || (|snes_overrun) || snes_protocol),.q(snes_failure_md));
  wire [4:0] snes_map_config;
  wire [41:0] snes_memory_config;
  cdc_word #(.Width(5)) snes_config_map (.sclk(md_clk),.stb(flush),.d(map_config),
      .dclk(snes_master),.q(snes_map_config),.q_stb());
  cdc_word #(.Width(42)) snes_config_memory (.sclk(md_clk),.stb(flush),
      .d({rom_size,save_size}),.dclk(snes_master),.q(snes_memory_config),.q_stb());
  wire [14:0] srgb;
  wire spixel,sdot,shs,svs,shde,svde,shigh,sfield,sinterlace,sv224;
  wire [8:0] sx,sy;
  wire [15:0] saudio_l,saudio_r;
  wire saudio_ready;
  wire host_valid_s,host_write_s,host_ready_s,host_done_s;
  wire [20:0] host_addr_s;
  wire [31:0] host_data_s,host_read_s;
  wire host_bridge_ready,host_bridge_rsp,host_bridge_idle;
  retro_memory_cdc host_bridge (.sclk(md_clk),.srst(rst_md),
      .req_valid(w_valid && selected==3),.req_write(1'b1),.req_addr(w_addr),.req_wdata(w_data),
      .req_mask(4'b1111),.req_ready(host_bridge_ready),.rsp_valid(host_bridge_rsp),
      .rsp_ready(w_rsp_ready),.rsp_rdata(),.idle(host_bridge_idle),
      .dclk(service),.drst(rst_service),
      .mem_valid(host_valid_s),.mem_write(host_write_s),.mem_addr(host_addr_s),
      .mem_wdata(host_data_s),.mem_mask(),.mem_ready(host_ready_s),.mem_rsp_valid(host_done_s),
      .mem_rsp_ready(),.mem_rdata(host_read_s));
  assign w_ready=selected==3 ? host_bridge_ready : fabric_ready[1];
  assign w_rsp=selected==3 ? host_bridge_rsp : fabric_rsp[1];
  wire atom_valid,atom_busy,atom_done;
  wire [39:0] atom_data;
  logic atom_launched=0;
  always_ff @(posedge md_clk)
    if (rst_md || !asset_command) atom_launched<=0;
    else if (!atom_launched && !atom_busy) atom_launched<=1;
  retro_mailbox #(.Width(40)) atom_transfer (.sclk(md_clk),.srst(rst_md),
      .send(asset_command && !atom_launched && !atom_busy),.data(command[39:0]),.busy(atom_busy),
      .dclk(snes_master),.drst(rst_service),.valid(atom_valid),.received(atom_data),
      .complete(atom_done));
  wire atom_error;
  wire asset_start_s,asset_valid_s,asset_last_s,asset_ready_s,asset_busy_s,asset_done_s;
  wire [1:0] asset_channel_s;
  wire [10:0] asset_addr_s;
  wire [7:0] asset_data_s;
  wire [2:0] asset_error_s;
  retro_asset_atoms atoms (.clk(snes_master),.rst(rst_service),.valid(atom_valid),
      .command(atom_data),.complete(atom_done),.stopped(!snes_active && !snes_run_s),
      .error(atom_error),.start(asset_start_s),.channel(asset_channel_s),
      .byte_valid(asset_valid_s),.byte_ready(asset_ready_s),.byte_addr(asset_addr_s),
      .byte_data(asset_data_s),.byte_last(asset_last_s),.asset_busy(asset_busy_s),
      .asset_done(asset_done_s),.asset_error(asset_error_s));
  logic atom_was_busy=0;
  always_ff @(posedge md_clk) atom_was_busy<=atom_busy;
  assign asset_complete=atom_was_busy && !atom_busy;
  sync_bit atom_error_sync (.clk(md_clk),.d(atom_error),.q(asset_failed));
  snes_system snes (.clk_service(service),.free_master(snes_master),.free_master_ce(snes_master_ce),
      .reset(rst_service),.memory_reset(controller_reset_s),.console_reset(1'b0),.run(snes_run_s),
      .cfg_map({1'b0,snes_map_config[0]}),.cfg_chip(8'b0),.cfg_pal(1'b0),
      .cfg_rom_mask(snes_memory_config[39:18]-1'b1),
      .cfg_save_enable(snes_memory_config[17:0]!=0),
      .cfg_save_mask(snes_memory_config[16:0]-1'b1),.pad1(generic_pad(pad_snes[15:0])),
      .pad2(generic_pad(pad_snes[31:16])),.asset_start(asset_start_s),
      .asset_channel(asset_channel_s),.asset_valid(asset_valid_s),.asset_ready(asset_ready_s),
      .asset_addr(asset_addr_s),.asset_data(asset_data_s),.asset_last(asset_last_s),
      .asset_busy(asset_busy_s),.asset_done(asset_done_s),.asset_error(asset_error_s),
      .ipl_ready(snes_ipl),.coeff_ready(snes_coeff),.active(snes_active),.stop_ack(snes_stop_s),
      .unsupported(snes_unsupported),.refresh_now(1'b0),.memory_initialized(snes_initialized_s),
      .memory_drained(),.memory_hold(snes_hold),.refresh_busy(),.request_inflight(),
      .needs_data(),.deadline_fault(),.overrun_fault(snes_overrun),.protocol_fault(snes_protocol),
      .clock_permit(),.core_step(),.clk_core(),.host_valid(host_valid_s),.host_write(host_write_s),
      .host_addr(host_addr_s),.host_wdata(host_data_s),.host_ready(host_ready_s),
      .host_done(host_done_s),.host_rdata(host_read_s),.sd_a(s_a),.sd_ba(s_ba),
      .sd_ras_n(s_cmd[2]),.sd_cas_n(s_cmd[1]),.sd_we_n(s_cmd[0]),.sd_cs_n(),.sd_cke(),
      .sd_dq_in(dq_in),.sd_dq_out(s_dq_out),.sd_dq_oe(s_dq_oe),.rgb(srgb),
      .pixel_ce(spixel),.dotclk(sdot),.hs(shs),.vs(svs),.hde(shde),.vde(svde),
      .highres(shigh),.field(sfield),.interlace(sinterlace),.v224(sv224),.x(sx),.y(sy),
      .audio_l(saudio_l),.audio_r(saudio_r),.audio_ready(saudio_ready));
  sync_bit sstop_sync (.clk(md_clk),.d(snes_stop_s),.q(snes_stopped));
  sync_bit sready_sync (.clk(md_clk),.d(snes_initialized_s),.q(snes_ready_md));
  sync_bit ipl_sync (.clk(md_clk),.d(snes_ipl),.q(assets_md[0]));
  sync_bit coeff_sync (.clk(md_clk),.d(snes_coeff),.q(assets_md[1]));
`else
  wire host_bridge_ready=0,host_bridge_rsp=0,host_bridge_idle=1,snes_failure_md=0;
  wire [14:0] srgb=0;
  wire spixel=0,shde=0,svde=0,sinterlace=0,sv224=0;
  wire [8:0] sx=0,sy=0;
  wire [15:0] saudio_l=0,saudio_r=0;
  wire saudio_ready=0;
  assign s_a=0;assign s_ba=0;assign s_cmd=3'b111;assign s_dq_out=0;assign s_dq_oe=0;
  assign snes_stopped=1;assign snes_ready_md=0;assign assets_md=0;
  assign asset_complete=0;assign asset_failed=0;
  assign w_ready=fabric_ready[1];assign w_rsp=fabric_rsp[1];
`endif

  wire physical_clock;
  wire [31:0] dq_out;
  wire dq_drive;
`ifndef RETRO_SINGLE
  retro_sdram_owner owner_switch (.clk(md_clk),.rst(rst_md),.requested(owner_request),
      .safe(controllers_reset),.owner,.busy(owner_busy),.nes_clock(nes_sd_clock),
      .md_clock(md_sd_clock),.snes_clock(snes_sd_clock),.memory_clock(physical_clock),
      .a('{n_a,m_a,s_a}),.ba('{n_ba,m_ba,s_ba}),.command('{n_cmd,m_cmd,s_cmd}),
      .data('{n_dq_out,m_dq_out,s_dq_out}),.drive({s_dq_oe,m_dq_oe,n_dq_oe}),
      .sd_a(sdram_a),.sd_ba(sdram_ba),.sd_ras_n(sdram_ras_n),.sd_cas_n(sdram_cas_n),
      .sd_we_n(sdram_we_n),.dq_out,.dq_oe(dq_drive));
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) memory_clock_forward (
      .C(physical_clock),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0),.Q(sdram_clk));
`else
  // One console: its controller and its own SDRAM clock, no clock multiplexer.
  wire [10:0] single_a=Systems[0] ? n_a : Systems[1] ? m_a : s_a;
  wire [1:0] single_ba=Systems[0] ? n_ba : Systems[1] ? m_ba : s_ba;
  wire [2:0] single_cmd=Systems[0] ? n_cmd : Systems[1] ? m_cmd : s_cmd;
  wire [31:0] single_data=Systems[0] ? n_dq_out : Systems[1] ? m_dq_out : s_dq_out;
  wire single_drive=Systems[0] ? n_dq_oe : Systems[1] ? m_dq_oe : s_dq_oe;
  // retro_sdram (MD) resets its command/address registers itself: no gate, IOB-packable.
  // The NES controller may keep a stale command through reset: keep it gated.
  retro_sdram_single #(.System(Systems[0] ? 2'd1 : Systems[1] ? 2'd2 : 2'd3),
      .GateCommand(Systems!=3'b010)) owner_switch (
      .clk(md_clk),.rst(rst_md),.requested(owner_request),.safe(controllers_reset),
      .owner,.busy(owner_busy),.a(single_a),.ba(single_ba),.command(single_cmd),
      .data(single_data),.drive(single_drive),.sd_a(sdram_a),.sd_ba(sdram_ba),
      .sd_ras_n(sdram_ras_n),.sd_cas_n(sdram_cas_n),.sd_we_n(sdram_we_n),
      .dq_out,.dq_oe(dq_drive));
`ifndef RETRO_NO_NES
  assign physical_clock=nes_sd_clock;
`elsif RETRO_NO_MD
  assign physical_clock=snes_sd_clock;
`else
  assign physical_clock=md_sd_clock;
`endif
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) memory_clock_forward (
      .C(physical_clock),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0),.Q(sdram_clk));
`endif
  // MD-only: every DQ register sits in the pad (retro_sdram_phy), clocked by the MD
  // controller clock. The controller holds dq_oe_next low in reset, so a foreign owner
  // request (controller held in reset by selected!=2) never drives DQ. Other images keep
  // the owner-gated fabric path.
  if (Systems==3'b010) begin : g_pad_dq
    retro_sdram_phy physical_io (.clk(md_clk),.dq_out(m_dq_out),.dq_oe_d(m_dq_oe_next),
        .dq_in(md_dq_in),.sd_dq(sdram_dq));
    assign dq_in=md_dq_in;
  end else begin : g_fabric_dq
    retro_sdram_io physical_io (.dq_in,.dq_out,.dq_oe(dq_drive),.sd_dq(sdram_dq));
    assign md_dq_in=dq_in;
  end
  wire video_fault;
  wire [1:0] selected_bus=status_bus[41:40];
  wire running_bus=status_bus[RunningBit];
  retro_video video (.bus_clk,.rst(bus_rst),.selected(selected_bus),.running(running_bus),
      .audio_valid(audio_valid_bus),.audio_l(audio_bus[31:16]),.audio_r(audio_bus[15:0]),
      .nes_clk(nclk),.nes_we(nwe),
      .nes_x(nx),.nes_y(ny),.nes_index(nindex),.md_clk,.md_pixel(mpixel),.md_hs(mhs),
      .md_vs(mvs),.md_hde(mhde),.md_vde(mvde),.md_interlace(minterlace),
      .md_r(mr),.md_g(mg),.md_b(mb),.md_resolution(mresolution),.snes_clk(service),
      .snes_pixel(spixel),.snes_hde(shde),.snes_vde(svde),.snes_interlace(sinterlace),
      .snes_v224(sv224),.snes_x(sx),.snes_y(sy),.snes_rgb(srgb),.clk_pix,.clk_5x,.rst_pix,
      .hdmi_p,.hdmi_n,.fault(video_fault));
  wire [31:0] audio_n,audio_m,audio_s;
  wire [31:0] audio_bus=selected_bus==1 ? audio_n : selected_bus==2 ? audio_m : audio_s;
  wire [2:0] audio_strobes;
  logic [2:0] qualified_audio=0;
  logic [3:0] audio_flush_guard=0;
  always_ff @(posedge bus_clk)
    if (bus_rst || !running_bus) begin qualified_audio<=0;audio_flush_guard<=0;end
    else if (audio_flush_guard!=15) begin audio_flush_guard<=audio_flush_guard+1'b1;
      qualified_audio<=0;end
    else qualified_audio<=qualified_audio | audio_strobes;
  wire audio_valid_bus=running_bus && selected_bus!=0 && qualified_audio[selected_bus-1'b1];
  wire [15:0] nes_signed_audio={~naudio[15],naudio[14:0]};
  // Audio must keep advancing through PPU blanking. Use the ungated nclk,
  // with >74 bus periods between launches, not framebuffer write enable.
  logic [3:0] nes_audio_divider=0;
  always_ff @(posedge nclk) nes_audio_divider<=nes_audio_divider+1'b1;
  wire nes_audio_capture=nes_audio_divider==0 && nes_run_n && !rst_nes && !nes_rst_control;
`ifndef RETRO_NO_NES
  cdc_word #(.Width(32)) nes_audio (.sclk(nclk),.stb(nes_audio_capture),
      .d({nes_signed_audio,nes_signed_audio}),.dclk(bus_clk),.q(audio_n),.q_stb(audio_strobes[0]));
`else
  assign audio_n=0;assign audio_strobes[0]=0;
`endif
  // Drain gates the core clock and can hold CE_PIX high; never recount that
  // held pulse on the free MD clock after execution has been revoked.
`ifndef RETRO_NO_MD
  cdc_word #(.Width(32)) md_audio (.sclk(md_clk),
      .stb(md_run && mpixel && !rst_md && !controllers_reset),.d({maudio_l,maudio_r}),
      .dclk(bus_clk),.q(audio_m),.q_stb(audio_strobes[1]));
`else
  assign audio_m=0;assign audio_strobes[1]=0;
`endif
`ifndef RETRO_NO_SNES
  cdc_word #(.Width(32)) snes_audio (.sclk(service),.stb(saudio_ready),.d({saudio_l,saudio_r}),
      .dclk(bus_clk),.q(audio_s),.q_stb(audio_strobes[2]));
`else
  assign audio_s=0;assign audio_strobes[2]=0;
`endif
  assign led=running && !video_fault;
  assign uart_tx=1'b1;
endmodule
`undef RETRO_CAP_NES
`undef RETRO_CAP_MD
`undef RETRO_CAP_SNES
`ifdef RETRO_SINGLE
`undef RETRO_SINGLE
`endif
`default_nettype wire
