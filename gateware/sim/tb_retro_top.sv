`timescale 1ns/1ps
// Real product top exercised through QSPI CSR/stream. Primitive clock models
// are ideal; no board timing claim. Normal QSPI tests only observe internals.
// +audio_only uses explicit console-boundary fixtures, not replacement CDC logic.
module tb_retro_top;
  logic clk=0;always #20 clk=~clk;
  wire led,uart_tx,esp_irq;
  logic esp_sck=0,esp_cs_n=1;
  wire [3:0] esp_d;
  logic [3:0] host_data=0;
  logic host_drive=0;
  assign esp_d=host_drive ? host_data : {4{1'bz}};
  wire [3:0] hdmi_p,hdmi_n;
  wire sdram_clk,sdram_ras_n,sdram_cas_n,sdram_we_n;
  wire [10:0] sdram_a;
  wire [1:0] sdram_ba;
  wire [31:0] sdram_dq;
  // Same model launch offset as legacy tb_nes (14.5ns at 64.286MHz).
  // The hardware default remains 279deg; this is NOT a board calibration.
  retro_top #(.NesSdramPhase(335.454545)) dut (.*);
  bit saw_interlace=0;
  always @(posedge dut.service) if(dut.snes_unsupported[3]) saw_interlace=1;
  sdram_model #(.DynamicCasTiming(1'b1),.TOh(2ns),.TRcd(21ns)) model (
      .clk(sdram_clk),.cke(1'b1),.cs_n(1'b0),.ras_n(sdram_ras_n),
      .cas_n(sdram_cas_n),.we_n(sdram_we_n),.ba(sdram_ba),.a(sdram_a),.dqm(4'b0),.dq(sdram_dq));
  // Pin-command timing, conditional ESMT(2S)-7 protocol; not board flight/STA.
  realtime last_act[4]='{-1us,-1us,-1us,-1us};
  realtime last_pre[4]='{-1us,-1us,-1us,-1us};
  realtime last_write[4]='{-1us,-1us,-1us,-1us};
  realtime last_ref=-1us,last_mrs=-1us,last_any_act=-1us,last_pin_edge=0;
  always @(posedge sdram_clk) begin
    automatic realtime period=dut.owner==1 ? 15.555556ns :
                              dut.owner==2 ? 18.624339ns : 11.640212ns;
    if(last_pin_edge!=0)
      assert($realtime-last_pin_edge<=1000ns) else $fatal(1,"SDRAM tCCmax handover");
    last_pin_edge=$realtime;
    case({sdram_ras_n,sdram_cas_n,sdram_we_n})
      3'b011: begin
        assert($realtime-last_pre[sdram_ba]>=21ns && $realtime-last_ref>=63ns &&
               $realtime-last_mrs>=2*period-2ps && $realtime-last_any_act>=14ns &&
               $realtime-last_act[sdram_ba]>=63ns)
            else $fatal(1,"ACT pin owner=%d rp=%0.3f rfc=%0.3f mrd=%0.3f rrd=%0.3f rc=%0.3f",
                        dut.owner,($realtime-last_pre[sdram_ba])/1ns,
                        ($realtime-last_ref)/1ns,($realtime-last_mrs)/1ns,
                        ($realtime-last_any_act)/1ns,($realtime-last_act[sdram_ba])/1ns);
        last_act[sdram_ba]=$realtime;last_any_act=$realtime;
      end
      3'b101,3'b100: begin
        assert($realtime-last_act[sdram_ba]>=21ns)
            else $fatal(1,"ACT->CAS <21ns owner=%d",dut.owner);
        if(!sdram_we_n) last_write[sdram_ba]=$realtime;
        if(sdram_a[10]) begin
          automatic realtime recovery=sdram_we_n ? period : 2*period;
          last_pre[sdram_ba]=($realtime+recovery>last_act[sdram_ba]+42ns) ?
                             $realtime+recovery : last_act[sdram_ba]+42ns;
        end
      end
      3'b010: for(int b=0;b<4;b++) if(sdram_a[10] || sdram_ba==2'(b)) begin
        assert($realtime-last_act[b]>=42ns && $realtime-last_write[b]>=2*period-2ps)
            else $fatal(1,"PRE pin tRAS/tRDL owner=%d",dut.owner);
        last_pre[b]=$realtime;
      end
      3'b001: begin
        for(int b=0;b<4;b++)
          assert($realtime-last_pre[b]>=21ns) else $fatal(1,"REF pin tRP");
        assert($realtime-last_ref>=63ns) else $fatal(1,"REF pin tRFC");
        last_ref=$realtime;
      end
      3'b000: begin
        assert($realtime-last_ref>=63ns) else $fatal(1,"MRS pin tRFC");
        last_mrs=$realtime;
      end
      default: ;
    endcase
  end
  localparam time T=100ns;
  task automatic nib(input logic[3:0] n);
    host_data=n;#(T/2) esp_sck=1;#(T/2) esp_sck=0;
  endtask
  task automatic header(input logic[7:0] op,input logic[23:0] addr);
    esp_cs_n=0;host_drive=1;#(T/2);nib(op[7:4]);nib(op[3:0]);
    for(int i=5;i>=0;i--) nib(addr[i*4+:4]);
  endtask
  task automatic finish_qspi;
    host_drive=0;#(T/2) esp_cs_n=1;#(T*2);
  endtask
  task automatic write_csr(input logic[7:0] addr,input logic[31:0] value);
    header(8'h30,{16'b0,addr});for(int i=7;i>=0;i--) nib(value[i*4+:4]);finish_qspi();
  endtask
  task automatic read_csr(input logic[7:0] addr,output logic[31:0] value);
    header(8'h31,{16'b0,addr});host_drive=0;
    repeat(8) begin #(T/2) esp_sck=1;#(T/2) esp_sck=0;end
    for(int i=7;i>=0;i--) begin
      #(T/2) esp_sck=1;value[i*4+:4]=esp_d;#(T/2) esp_sck=0;
    end
    finish_qspi();
  endtask
  task automatic wait_status(input logic[31:0] mask,input logic[31:0] wanted);
    logic[31:0] value;
    for(int i=0;i<3000;i++) begin
      read_csr(2,value);
      if((value&mask)==wanted) return;
    end
    $fatal(1,"status timeout mask=%h want=%h got=%h error=%h",mask,wanted,value,dut.error);
  endtask
  task automatic command(input logic[31:0] value);
    wait_status(32'h20,0);write_csr(1,value);wait_status(32'h20,0);
  endtask
  task automatic send_pad(input logic [31:0] value, input int bytes_count=4);
    header(8'h33,0);
    for(int i=0;i<bytes_count;i++) begin
      nib(value[31-8*i-:4]);nib(value[27-8*i-:4]);
    end
    finish_qspi();#2us;
  endtask
  task automatic check_pads;
    logic [31:0] buttons;
    logic [11:0] first,second;
    logic [7:0] nes_buttons;
    for(int bit_index=0;bit_index<32;bit_index++) begin
      buttons=32'd1<<bit_index;
      send_pad(buttons);
      // Independent per-button expectation: generic order is directions,
      // A/B/X/Y/L/R, Select/Start; NES additionally filters turbo buttons.
      first=0;second=0;nes_buttons=0;
      if(bit_index<10) first[bit_index]=1;
      if(bit_index==14) first[10]=1;
      if(bit_index==15) first[11]=1;
      if(bit_index>=16 && bit_index<26) second[bit_index-16]=1;
      if(bit_index==30) second[10]=1;
      if(bit_index==31) second[11]=1;
      case(bit_index)
        0:nes_buttons=8'h10;1:nes_buttons=8'h20;
        2:nes_buttons=8'h40;3:nes_buttons=8'h80;
        4:nes_buttons=8'h01;5:nes_buttons=8'h02;
        6:nes_buttons=dut.n_pad.turbo ? 8'h01 : 0;
        7:nes_buttons=dut.n_pad.turbo ? 8'h02 : 0;
        14:nes_buttons=8'h04;15:nes_buttons=8'h08;
        default: ;
      endcase
      assert(dut.md.pad1==first && dut.md.pad2==second &&
             dut.snes.pad1==first && dut.snes.pad2==second && dut.njoy==nes_buttons)
        else $fatal(1,"QSPI pad bit %0d mapping",bit_index);
    end
    send_pad(32'h0000000f);
    assert(dut.njoy==0) else $fatal(1,"NES opposing directions not suppressed");
    send_pad(32'hffffffff,3);
    assert(dut.pad_bus==32'h0000000f) else $fatal(1,"partial PAD changed buttons");
    send_pad(0);
    assert(dut.md.pad1==0 && dut.md.pad2==0 && dut.snes.pad1==0 &&
           dut.snes.pad2==0 && dut.njoy==0) else $fatal(1,"PAD release lost");
    $display("ok QSPI PAD all32 bits, both MD/SNES ports, NES filter, partial frame, release");
  endtask
  task automatic check_audio(input int system_id);
    int samples,packets;
    samples=0;packets=0;
    repeat(6000) begin
      @(negedge dut.clk_pix);
      if(dut.video.transmitter.sample_ce && dut.video.audio_pixel_valid) samples++;
      if(dut.video.transmitter.take_audio) packets++;
      assert(!dut.video.transmitter.overflow) else $fatal(1,"HDMI audio overflow");
    end
    assert(dut.selected_bus==2'(system_id) && dut.audio_valid_bus && samples>=8 && packets>0)
      else $fatal(1,"system %0d audio path: samples=%0d packets=%0d",system_id,samples,packets);
    $display("ok system %0d real core audio CDC -> HDMI sample packets (%0d/%0d)",
             system_id,samples,packets);
  endtask
  // Focused source-boundary fixture: retain the actual top clocks, audio CDC,
  // owner qualification and HDMI bridge, but independently vary native samples
  // and suppress framebuffer writes for a complete NTSC vertical blank.
  logic audio_fixture=0,audio_fixture_running=0,audio_fixture_nwe=0;
  logic audio_fixture_nrun=0,audio_fixture_nreset=1;
  logic [8:0] audio_fixture_line=0;
  logic [15:0] audio_fixture_sample=0;
  int audio_fixture_cycles=0;
  always @(negedge dut.nclk) if(audio_fixture) begin
    audio_fixture_cycles++;
    audio_fixture_sample=16'(audio_fixture_cycles);
    audio_fixture_nwe=audio_fixture_line<240 && audio_fixture_cycles%4==0;
  end
  task automatic check_nes_audio_blank;
    int blank_updates,reset_launches;
    logic [15:0] sample_age,pixel_sample_age;
    force dut.naudio=audio_fixture_sample;
    force dut.nwe=audio_fixture_nwe;
    force dut.nline=audio_fixture_line;
    force dut.nes_run_n=audio_fixture_nrun;
    force dut.rst_nes=audio_fixture_nreset;
    force dut.nes_rst_control=audio_fixture_nreset;
    force dut.selected_bus=2'd1;
    force dut.running_bus=audio_fixture_running;
    audio_fixture=1;audio_fixture_nreset=0;
    audio_fixture_nrun=1;audio_fixture_running=1;
    #4us;
    @(negedge dut.nclk);audio_fixture_line=240;
    blank_updates=0;
    // Sample age is measured against an independent native ramp, not against
    // the implementation's divider. Bound allows 16 native cycles + CDC latency.
    repeat(150000) begin
      @(negedge dut.bus_clk);
      sample_age=audio_fixture_sample-(dut.audio_n[15:0]^16'h8000);
      assert(sample_age<=20 && dut.audio_n[31:16]==dut.audio_n[15:0])
          else $fatal(1,"NES audio stale/torn THROUGH vblank: age=%0d sample=%h bus=%h",
                      sample_age,audio_fixture_sample,dut.audio_n);
      assert(!dut.nwe && dut.nline>=240) else $fatal(1,"NES vblank fixture wrote video");
      if(dut.video.audio_pixel_valid) begin
        pixel_sample_age=audio_fixture_sample-(16'(dut.video.audio_pixel_l)^16'h8000);
        assert(pixel_sample_age<=520 && dut.video.audio_pixel_l==dut.video.audio_pixel_r)
            else $fatal(1,"NES HDMI bridge stale/torn in vblank: age=%0d",pixel_sample_age);
      end
      if(dut.audio_strobes[0]) blank_updates++;
    end
    assert(blank_updates>1900 && dut.audio_valid_bus && dut.video.audio_pixel_valid)
        else $fatal(1,"NES vblank audio updates=%0d valid=%b/%b",blank_updates,
                    dut.audio_valid_bus,dut.video.audio_pixel_valid);
    @(negedge dut.nclk);audio_fixture_line=0;
    #4us;
    audio_fixture_nreset=1;
    reset_launches=nes_audio_launches;
    repeat(40) @(negedge dut.nclk);
    assert(nes_audio_launches==reset_launches) else $fatal(1,"reset NES launched audio");
    audio_fixture_nreset=0;
    #2us;
    audio_fixture_nrun=0;audio_fixture_running=0;
    #2us;
    assert(!dut.nes_audio.stb) else $fatal(1,"stopped NES launched audio");
    audio_fixture_nreset=1;
    release dut.naudio;release dut.nwe;release dut.nline;
    release dut.nes_run_n;release dut.rst_nes;release dut.nes_rst_control;
    release dut.selected_bus;release dut.running_bus;
    audio_fixture=0;
    $display("ok NES audio freshness THROUGH 1.5ms vblank, mono coherence, %0d captures",
             blank_updates);
  endtask
  logic audio_fixture_md_run=0;
  task automatic check_md_audio_stop;
    int held_cycles;
    force dut.md_run=audio_fixture_md_run;
    force dut.rst_md=1'b0;
    force dut.controllers_reset=1'b0;
    force dut.selected=2'd2;
    // Let the real VDP generate CE_PIX. No pixel strobe or clock is forced.
    repeat(40) @(negedge dut.md_clk);
    audio_fixture_md_run=1;
    repeat(128) @(negedge dut.md_clk);
    assert(md_audio_launches>=8) else $fatal(1,"MD running audio spacing was not exercised");
    // Request stop just before the VDP generates its next CE; the machine's
    // following Drain gate must leave that registered CE high on a stopped core.
    do @(negedge dut.md_clk);
    while(dut.md.core.machine.vdp.HV_PIXDIV!=4 || dut.mpixel);
    audio_fixture_md_run=0;
    repeat(2) @(negedge dut.md_clk);
    #1ps;
    assert(dut.mpixel && dut.md.freeze) else $fatal(1,"MD stop missed high CE_PIX");
    held_cycles=0;
    repeat(8) begin
      @(posedge dut.md_clk);
      assert(!dut.md.core_clk && dut.mpixel) else $fatal(1,"MD core did not hold CE high");
      held_cycles++;
      assert(!dut.md_audio.stb) else $fatal(1,"stopped MD repeated audio launch at held CE_PIX");
    end
    release dut.md_run;release dut.rst_md;
    release dut.controllers_reset;release dut.selected;
    $display("ok MD real clock gate held CE_PIX high for %0d free edges; no audio launch",
             held_cycles);
  endtask
  // Observe launches at actual source edges. CDC bundle updates must be at
  // least four 100-MHz destination periods apart, including stop/restart.
  realtime last_nes_audio_launch=0,last_md_audio_launch=0;
  int nes_audio_launches=0,md_audio_launches=0;
  always @(posedge dut.nclk) if(dut.nes_audio.stb) begin
    if(last_nes_audio_launch!=0)
      assert($realtime-last_nes_audio_launch>=40ns)
          else $fatal(1,"NES audio CDC source spacing <4 bus cycles");
    last_nes_audio_launch=$realtime;nes_audio_launches++;
    assert(dut.nes_run_n && !dut.rst_nes && !dut.nes_rst_control)
        else $fatal(1,"NES audio launch while stopped/reset");
  end
  always @(posedge dut.md_clk) if(dut.md_audio.stb) begin
    if(last_md_audio_launch!=0)
      assert($realtime-last_md_audio_launch>=40ns)
          else $fatal(1,"MD audio CDC source spacing <4 bus cycles");
    last_md_audio_launch=$realtime;md_audio_launches++;
    assert(dut.md_run && !dut.rst_md && !dut.controllers_reset)
        else $fatal(1,"MD audio launch while stopped/reset");
  end
  task automatic expect_load_error(input logic [7:0] expected_error);
    logic [31:0] actual_error;
    wait_status(32'h27,4);wait_status(32'h30,0);
    read_csr(11,actual_error);
    assert(actual_error==32'(expected_error) && !dut.dq_drive)
      else $fatal(1,"load error got=%h expected=%h DQ=%b",
                  actual_error,expected_error,dut.dq_drive);
    command(32'h52540004);wait_status(32'h3f,0);
    read_csr(11,actual_error);
    assert(actual_error==0) else $fatal(1,"ABORT did not clear load error");
  endtask
  task automatic check_locked_assets(input int system_id);
    logic [31:0] before_assets,after_assets,error_code,state_bits;
    read_csr(10,before_assets);
    command(32'h52540100);
    read_csr(11,error_code);read_csr(2,state_bits);read_csr(10,after_assets);
    assert(error_code==6 && (state_bits & 32'h26)==6 &&
           after_assets==before_assets && dut.selected==2'(system_id) &&
           !dut.controllers_reset)
      else $fatal(1,"locked assets interrupted system %0d or changed coverage",system_id);
    #20us;
    assert(dut.running && dut.audio_valid_bus)
      else $fatal(1,"locked asset rejection stopped running audio");
    $display("ok system %0d rejects asset mutation without stopping core/audio",system_id);
  endtask
  task automatic check_load_errors;
    // No bytes accepted: COMMIT must fail, never boot an old cartridge.
    write_csr(5,2);write_csr(6,1024);write_csr(8,1024);
    command(32'h52540001);wait_status(32'h2c,8);
    command(32'h52540002);expect_load_error(7);
    // Invalid iNES magic must reach the native loader and fail closed.
    write_csr(5,1);write_csr(6,16400);write_csr(8,16384);
    command(32'h52540001);wait_status(32'h2c,8);
    header(8'h32,0);repeat(16) begin nib(0);nib(0);end finish_qspi();
    expect_load_error(5);
    // A non-ROM STREAM channel is a transport fault, not ROM payload.
    write_csr(5,2);write_csr(6,1024);write_csr(8,1024);
    command(32'h52540001);wait_status(32'h2c,8);
    header(8'h32,1);nib(4'ha);nib(4'h5);finish_qspi();
    expect_load_error(3);
    // Length is a hard boundary even when extra bytes share the same frame.
    write_csr(5,2);write_csr(6,4);write_csr(8,4);
    command(32'h52540001);wait_status(32'h2c,8);
    header(8'h32,0);repeat(5) begin nib(4'ha);nib(4'h5);end finish_qspi();
    expect_load_error(3);
    // MD words cannot represent an odd canonical byte count.
    write_csr(5,2);write_csr(6,3);write_csr(8,3);
    command(32'h52540001);expect_load_error(2);
    $display("ok early COMMIT, invalid iNES, wrong STREAM channel: errors and ABORT recovery");
    $display("ok excess ROM byte and odd MD length rejected, ABORT recovery");
  endtask
  task automatic check_config_snapshot;
    logic [31:0] active_system;
    write_csr(5,2);write_csr(6,1024);write_csr(8,1024);
    command(32'h52540001);wait_status(32'h2c,8);
    // Shadows may prepare the next cartridge, never mutate the current one.
    write_csr(5,1);write_csr(6,16400);write_csr(7,17);
    write_csr(8,16384);write_csr(9,2048);
    read_csr(5,active_system);
    assert(active_system==2 && dut.selected==2 && dut.length==1024 &&
           dut.rom_size==1024 && dut.map_config==0 && dut.save_size==0)
      else $fatal(1,"shadow writes changed active cartridge configuration");
    stream_md_rom();wait_status(32'h6c,32'h40);
    command(32'h52540002);wait_status(32'h26,2);#150us;
    assert(md_writes>0) else $fatal(1,"snapshot MD cartridge did not execute");
    command(32'h52540004);wait_status(32'h3f,0);
    // The next BEGIN must apply those shadows as one complete snapshot.
    command(32'h52540001);wait_status(32'h2c,8);
    read_csr(5,active_system);
    assert(active_system==1 && dut.length==16400 && dut.rom_size==16384 &&
           dut.map_config==17 && dut.save_size==2048)
      else $fatal(1,"next BEGIN lost shadow configuration");
    command(32'h52540004);wait_status(32'h3f,0);
    write_csr(7,0);write_csr(9,0);
    $display("ok BEGIN snapshots configuration; shadow edits deferred to next cartridge");
  endtask
  logic inject_interlace=0;
  int nes_writes=0;
  int md_writes=0;
  int snes_writes=0;
  always @(posedge sdram_clk)
    if(dut.owner==3 && {sdram_ras_n,sdram_cas_n,sdram_we_n}==3'b100 &&
       {sdram_ba,model.row[sdram_ba],sdram_a[7:0]}==21'h100000 &&
       sdram_dq==32'ha5a5a5a5) snes_writes++;
  always @(posedge sdram_clk)
    if(dut.owner==2 && {sdram_ras_n,sdram_cas_n,sdram_we_n}==3'b100 &&
       {sdram_ba,model.row[sdram_ba],sdram_a[7:0]}==21'h100000 &&
       sdram_dq[15:0]==16'h5aa5) md_writes++;
  always @(posedge sdram_clk)
    if(dut.owner==1 && {sdram_ras_n,sdram_cas_n,sdram_we_n}==3'b100 &&
       {sdram_ba,model.row[sdram_ba],sdram_a[7:0]}==21'h0e0000 &&
       sdram_dq[7:0]==8'h5a) nes_writes++;
  byte snes_code[]='{
      8'h78,8'h18,8'hfb,8'he2,8'h20,8'ha9,8'h0f,8'h8d,8'h00,8'h21,
      8'ha9,8'ha5,8'h8f,8'h00,8'h00,8'h7e,8'h80,8'hfe};
  function automatic logic[7:0] snes_rom_byte(input int addr);
    if(inject_interlace && addr>=16 && addr<23) begin
      case(addr)
        16:return 8'ha9;17:return 8'h01;18:return 8'h8d;19:return 8'h33;
        20:return 8'h21;21:return 8'h80;22:return 8'hfe;
        default:return 0;
      endcase
    end
    if(addr<snes_code.size()) return snes_code[addr];
    if(addr==32764) return 0;
    if(addr==32765) return 8'h80;
    return 8'hea;
  endfunction
  function automatic logic[7:0] ipl_byte(input int addr);
    case(addr)
      0:return 8'he8;1:return 8'h5a;2:return 8'hc5;3:return 8'h34;4:return 8'h12;
      5:return 8'he5;6:return 8'h34;7:return 8'h12;8:return 8'hc4;9:return 8'hf4;
      10:return 8'h2f;11:return 8'hfe;62:return 8'hc0;63:return 8'hff;
      default:return 0;
    endcase
  endfunction
  task automatic program_assets;
    // Partial upload -> ABORT -> CLEAR restart WITHOUT global asset reset.
    command(32'h52540100);
    for(int i=0;i<11;i++) begin
      wait_status(32'h20,0);write_csr(12,32'(i<<8)|32'(ipl_byte(i)));wait_status(32'h20,0);
    end
    command(32'h52540004);wait_status(32'h3b,0);
    command(32'h52540100);
    for(int i=0;i<64;i++) begin
      wait_status(32'h20,0);write_csr(12,32'(i<<8)|32'(ipl_byte(i)));wait_status(32'h20,0);
    end
    command(32'h52540200);
    for(int i=0;i<512;i++) begin
      wait_status(32'h20,0);write_csr(13,32'(i<<12)|32'(i));wait_status(32'h20,0);
    end
  endtask
  task automatic stream_snes_rom;
    logic[31:0] free_bytes;
    for(int base=0;base<32768;base+=128) begin
      do read_csr(3,free_bytes);while(free_bytes<128);
      header(8'h32,0);
      for(int i=base;i<base+128;i++) begin
        automatic logic[7:0] value=snes_rom_byte(i);
        nib(value[7:4]);nib(value[3:0]);
      end
      finish_qspi();
    end
  endtask
  function automatic logic[7:0] md_rom_byte(input int addr);
    case(addr)
      0:return 8'h00;1:return 8'hff;2:return 8'h00;3:return 8'h00;
      4:return 8'h00;5:return 8'h00;6:return 8'h02;7:return 8'h00;
      512:return 8'h33;513:return 8'hfc;514:return 8'ha5;515:return 8'h5a;
      516:return 8'h00;517:return 8'hff;518:return 8'h00;519:return 8'h00;
      520:return 8'h60;521:return 8'hfe;
      default:return 0;
    endcase
  endfunction
  task automatic stream_md_rom;
    for(int base=0;base<1024;base+=128) begin
      header(8'h32,0);
      for(int i=base;i<base+128;i++) begin
        automatic logic[7:0] value=md_rom_byte(i);
        nib(value[7:4]);nib(value[3:0]);
      end
      finish_qspi();
    end
  endtask
  function automatic logic[7:0] nes_rom_byte(input int addr);
    case(addr)
      0:return 8'h4e;1:return 8'h45;2:return 8'h53;3:return 8'h1a;
      4:return 1;
      16:return 8'h78;17:return 8'ha9;18:return 8'h5a;
      19:return 8'h8d;20:return 0;21:return 0;
      22:return 8'h4c;23:return 8'h06;24:return 8'h80;
      16+16380:return 0;16+16381:return 8'h80;
      default:return 0;
    endcase
  endfunction
  task automatic stream_nes_rom;
    logic[31:0] free_bytes;
    for(int base=0;base<16400;base+=128) begin
      do read_csr(3,free_bytes);while(free_bytes<128);
      header(8'h32,0);
      for(int i=base;i<base+128 && i<16400;i++) begin
        automatic logic[7:0] value=nes_rom_byte(i);
        nib(value[7:4]);nib(value[3:0]);
      end
      finish_qspi();
    end
  endtask
  initial begin
    logic[31:0] value;
    int previous_writes;
    int nes_only=0;
    int audio_only=0;
    if (!$value$plusargs("nes_only=%d",nes_only)) nes_only=0;
    if (!$value$plusargs("audio_only=%d",audio_only)) audio_only=0;
    #10us;
    if(audio_only!=0) begin
      if(audio_only!=2) check_nes_audio_blank();
      if(audio_only!=1) check_md_audio_stop();
      $finish;
    end
    read_csr(0,value);assert(value==32'h46524554) else $fatal(1,"FRET %h",value);
    check_pads();
    check_load_errors();
    check_config_snapshot();
    if(nes_only!=0) begin
      command(32'h52540004);
      write_csr(5,1);write_csr(6,16400);write_csr(8,16384);
      command(32'h52540001);wait_status(32'h2c,8);stream_nes_rom();
      wait_status(32'h6c,32'h40);
      $display("NES precommit ROM=%h %h %h vec=%h/%h flags=%h",
        model.mem[21'd0],model.mem[21'd1],model.mem[21'd2],
        model.mem[21'd16380],model.mem[21'd16381],dut.nes.mapper_flags);
      command(32'h52540002);wait_status(32'h26,2);#300us;
      $display("NES CPU PC=%h A=%h addr=%h data=%h WRAM=%h writes=%d",
        dut.nes.u_nes.cpu.PC,dut.nes.u_nes.cpu.ABC,dut.nes.cpu_addr,dut.nes.cpu_din,
        model.mem[21'h0e0000],nes_writes);
      assert(model.mem[21'h0e0000][7:0]==8'h5a) else $fatal(1,"NES marker");
      check_audio(1);
      previous_writes=nes_writes;
      command(32'h52540008);wait_status(32'h26,2);#300us;
      assert(nes_writes>previous_writes) else $fatal(1,"NES RESET did not rerun CPU");
      command(32'h52540004);wait_status(32'h3b,0);
      previous_writes=nes_writes;
      command(32'h52540001);wait_status(32'h2c,8);stream_nes_rom();
      wait_status(32'h6c,32'h40);command(32'h52540002);wait_status(32'h26,2);#300us;
      assert(nes_writes>previous_writes) else $fatal(1,"NES reload did not rerun CPU");
      command(32'h52540004);wait_status(32'h3b,0);
      assert(model.errors==0) else $fatal(1,"NES physical model errors %0d",model.errors);
      $display("ok strict NES QSPI load/COMMIT/RESET/ABORT/reload fresh CPU writes, errors=0");
      $finish;
    end
    for(int sys=1;sys<=3;sys++) begin
      if(sys==3) break; // SNES assets/CPU fixture is separate; no fake IPL boot.
      command(32'h52540004);
      write_csr(5,32'(sys));write_csr(6,32'd16);write_csr(8,32'd16);
      command(32'h52540001);
      wait_status(32'h2c,32'h08);
      // Abort while stream/writer may own a pending write, then switch again.
      header(8'h32,0);
      for(int i=0;i<4;i++) begin nib(4'hA);nib(4'(i));end
      finish_qspi();
      command(32'h52540004);
      wait_status(32'h3b,0);
      assert(!dut.dq_drive) else $fatal(1,"DQ still driven after abort");
    end
    write_csr(5,2);write_csr(6,1024);write_csr(8,1024);
    command(32'h52540001);wait_status(32'h2c,8);stream_md_rom();
    wait_status(32'h6c,32'h40);command(32'h52540002);wait_status(32'h26,2);
    #150us;
    assert(md_writes>0) else $fatal(1,"MD initial CPU marker write absent");
    check_audio(2);
    previous_writes=md_writes;
    command(32'h52540008);wait_status(32'h26,2);#150us;
    assert(md_writes>previous_writes) else $fatal(1,"MD RESET did not rerun CPU");
    check_locked_assets(2);
    command(32'h52540004);wait_status(32'h3b,0);
    assert(model.mem[21'h100000][15:0]==16'h5aa5)
        else $fatal(1,"real MD CPU through SDRAM marker absent %h",model.mem[21'h100000]);
    $display("ok real MD canonical ROM through QSPI COMMIT CPU word write physical SDRAM");
    program_assets();
    read_csr(10,value);assert(value==3) else $fatal(1,"asset atoms coverage %h",value);
    write_csr(5,3);write_csr(6,32768);write_csr(8,32768);write_csr(9,0);write_csr(7,0);
    command(32'h52540001);wait_status(32'h2c,8);
    read_csr(10,value);assert(value==3) else $fatal(1,"BEGIN lost assets %h",value);
    stream_snes_rom();
    wait_status(32'h6c,32'h40);command(32'h52540002);
    wait_status(32'h26,2);
    #500us;
    assert(dut.snes_active) else $fatal(1,"SNES not actually active");
    check_audio(3);
    assert(snes_writes>0) else $fatal(1,"SNES initial CPU marker write absent");
    previous_writes=snes_writes;
    command(32'h52540008);wait_status(32'h26,2);
    #200us;
    assert(dut.snes_active) else $fatal(1,"running CONSOLE_RESET failed to resume");
    assert(snes_writes>previous_writes) else $fatal(1,"SNES RESET did not rerun CPU");
    check_locked_assets(3);
    command(32'h52540004);wait_status(32'h3b,0);
    assert(model.mem[21'h100000]==32'ha5a5a5a5)
        else $fatal(1,"real SNES CPU through SDRAM marker absent");
    read_csr(10,value);assert(value==3) else $fatal(1,"stop lost assets");
    $display("ok real SNES authored assets+ROM through QSPI COMMIT CPU marker physical SDRAM");
    inject_interlace=1;
    command(32'h52540001);wait_status(32'h2c,8);stream_snes_rom();
    wait_status(32'h6c,32'h40);command(32'h52540002);
    wait_status(32'h26,4);wait_status(32'h30,0);
    assert(saw_interlace) else $fatal(1,"SETINI interlace fault not observed");
    command(32'h52540004);wait_status(32'h3b,0);
    read_csr(10,value);assert(value==3) else $fatal(1,"runtime fault lost asset coverage");
    $display("ok real SNES SETINI interlace -> selected backend ERROR -> safe stop -> ABORT");
    write_csr(5,1);write_csr(6,16400);write_csr(8,16384);
    command(32'h52540001);wait_status(32'h2c,8);stream_nes_rom();
    wait_status(32'h6c,32'h40);command(32'h52540002);wait_status(32'h26,2);
    #150us;
    assert(!dut.nes.machine_reset) else $fatal(1,"NES still reset after COMMIT");
    check_audio(1);
    command(32'h52540004);wait_status(32'h3b,0);
    assert(model.mem[21'h0e0000][7:0]==8'h5a)
        else $fatal(1,"real NES CPU WRAM marker absent %h writes=%0d PC=%h",
                    model.mem[21'h0e0000],nes_writes,dut.nes.u_nes.cpu.PC);
    $display("ok real NES iNES GameLoader through QSPI COMMIT reset-vector CPU start then stop");
    command(32'h52540008);
    wait_status(32'h24,4);
    command(32'h52540004);wait_status(32'h3b,0);
    // Return to MD after both other systems: retained RAM cannot fake success.
    previous_writes=md_writes;
    write_csr(5,2);write_csr(6,1024);write_csr(8,1024);
    command(32'h52540001);wait_status(32'h2c,8);stream_md_rom();
    wait_status(32'h6c,32'h40);command(32'h52540002);wait_status(32'h26,2);#150us;
    assert(md_writes>previous_writes) else $fatal(1,"MD hot return did not rerun CPU");
    command(32'h52540004);wait_status(32'h3b,0);
    $display("ok MD RESET and hot return after SNES/NES produced fresh physical CPU writes");
    assert(model.errors==0) else $fatal(1,"physical model errors %d",model.errors);
    $display("ok real retro_top QSPI FRET BEGIN READY stream ABORT physical NES/MD handover");
    $finish;
  end
  initial begin #40ms;$fatal(1,"timeout");end
endmodule
