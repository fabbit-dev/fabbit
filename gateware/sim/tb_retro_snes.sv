// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
`timescale 1ns / 1ps
// Portable assertion proof of actual SNES CPUs/PPU/APU -> actual SDRAM model.
// Original synthetic instructions only; no cartridge/BIOS/table dump input.
module tb_retro_snes;
    parameter realtime SdPhase = 2ns;
    parameter int unsigned RefreshInterval = 480;
    logic clk_service=0;
    always #5.820ns clk_service=!clk_service;
    logic [1:0] phase=3;
    always @(posedge clk_service) phase<=phase+1'b1;
    wire free_master=phase<2;
    wire free_master_ce=phase==3;
    wire sd_clk;
    assign #(SdPhase) sd_clk=clk_service;
    logic reset=1, console_reset=0, run=0, memory_reset=0;
    logic [1:0] cfg_map=0;
    logic [7:0] cfg_chip=0;
    logic cfg_pal=0;
    logic [21:0] cfg_rom_mask=22'h007fff;
    logic cfg_save_enable=1;
    logic [16:0] cfg_save_mask=17'h01fff;
    logic [11:0] pad1=0,pad2=0;
    logic asset_start=0, asset_valid=0, asset_last=0;
    logic [1:0] asset_channel=0;
    logic [10:0] asset_addr=0;
    logic [7:0] asset_data=0;
    wire asset_ready,asset_busy,asset_done;
    wire [2:0] asset_error;
    wire ipl_ready,coeff_ready,active,stop_ack;
    wire [4:0] unsupported;
    logic refresh_now=0;
    wire memory_initialized,memory_drained,memory_hold,refresh_busy;
    wire [4:0] request_inflight;
    wire [3:0] needs_data,deadline_fault,overrun_fault;
    wire protocol_fault,clock_permit,core_step,clk_core;
    logic host_valid=0,host_write=0;
    logic [20:0] host_addr=0;
    logic [31:0] host_wdata=0;
    wire host_ready,host_done;
    wire [31:0] host_rdata;
    wire [10:0] sd_a;
    wire [1:0] sd_ba;
    wire sd_ras_n,sd_cas_n,sd_we_n,sd_cs_n,sd_cke,sd_dq_oe;
    wire [31:0] sd_dq_in,sd_dq_out;
    tri [31:0] sd_dq;
    assign sd_dq=sd_dq_oe ? sd_dq_out : {32{1'bz}};
    assign sd_dq_in=sd_dq;
    wire [14:0] rgb;
    wire pixel_ce,dotclk,hs,vs,hde,vde,highres,field,interlace,v224;
    wire [8:0] x,y;
    wire signed [15:0] audio_l,audio_r;
    wire audio_ready;
    snes_system #(.InitCycles(20),.RefreshCycles(RefreshInterval)) dut (.*);
    wire pair_probe_done;
    snes_pair_guard_probe pair_probe (.clk_service, .free_master, .free_master_ce,
                                      .done(pair_probe_done));
    // Conditional ESMT M12L64322A(2S)-7 CL2 bounds, Rev1.0 pp6-7.
    // Ideal pins only: no PCB flight/skew or FPGA I/O timing signoff.
    sdram_model #(.TAc(8ns),.TOh(2ns),.TRcd(21ns)) model (
        .clk(sd_clk),.cke(sd_cke),.cs_n(sd_cs_n),
        .ras_n(sd_ras_n),.cas_n(sd_cas_n),.we_n(sd_we_n),
        .ba(sd_ba),.a(sd_a),.dqm(4'b0000),.dq(sd_dq));

    // Negedge-latched primitive model below is deliberately the only gating
    // logic. Product module instantiates BUFGCE, never a fabric clock AND.
    int use_hirom=0;
    int stop_probe=0;
    int unsigned boot_count=0, startup_checks=0, reset_clock_checks=0;
    realtime active_since=0;
    logic sampled_reset=1;
    int unsigned master_reset_checks=0;
    always @(posedge free_master) begin
        sampled_reset=reset;
        #1ps;
        assert (dut.console_reset_master==sampled_reset)
            else $fatal(1,"console reset not launched on ungated master");
        if (reset || dut.console_reset_master)
            assert (!dut.console_run) else $fatal(1,"run escaped master reset");
        master_reset_checks++;
    end
    always @(posedge active) active_since=$realtime;
    always @(posedge clk_core) begin
        if (!reset && active) begin
            assert ($realtime-active_since>=46.559ns)
                else $fatal(1,"execution before full master-period startup settle");
            startup_checks++;
        end
        if (!reset && dut.stop_state==2'd3) begin // Resetting
            assert (!active && !dut.console_run)
                else $fatal(1,"stale executing edge while reopening reset clocks");
            reset_clock_checks++;
        end
    end
    int unsigned master_edges=0,core_edges=0,stalls=0,frames=0,audios=0,pixels=0;
    int unsigned refreshes=0,commits=0,reads=0,core_edges_at_stop=0;
    int unsigned first_vs_master=0,first_vs_core=0,first_vs_audio=0;
    int unsigned frame_master_period=0,frame_core_period=0,frame_audio_samples=0;
    bit previous_vs=0;
    bit measuring=0, seen_wram=0,seen_save=0,seen_aram=0,seen_mailbox=0;
    logic [3:0] dma_seen=0;
    int last_ref=-1000,last_act[4]='{-1000,-1000,-1000,-1000};
    int last_pre[4]='{-1000,-1000,-1000,-1000};
    int last_wr[4]='{-1000,-1000,-1000,-1000};
    int last_rd[4]='{-1000,-1000,-1000,-1000};
    int sd_cycle=0,last_any_act=-1000,last_any_wr=-1000;
    logic [44:0] stopped_snapshot;
    logic snapshot_valid=0;
    wire [44:0] state_snapshot={
        dut.console.machine.CPU.P65_CLK_CNT,
        dut.console.machine.PPU.H_CNT,dut.console.machine.PPU.V_CNT,
        dut.console.machine.dsp.STEP_CNT,dut.console.machine.dsp.SUBSTEP_CNT,
        dut.console.machine.smp.SPC700.AddrGen.PCr
    };
    // Independent consumption deadline monitor. One intermediate core edge is
    // legal after a new read; the second may run ONLY after a real response.
    // Observe completion strobes, not the guard's own decision, and never drive RTL.
    bit [3:0] proof_pending='0;
    int unsigned proof_launched[4];
    int unsigned proof_core_edges=0;
    always @(posedge clk_service) begin
        if (reset || !measuring) proof_pending='0;
        else begin
            for (int p=0;p<4;p++) begin
                if (dut.memory.valid_read[p]) proof_pending[p]=0;
                if (core_step && proof_pending[p])
                    assert (proof_core_edges-proof_launched[p]<1)
                        else $fatal(1,"unfinished read consumed by second core edge port=%0d",p);
                if (dut.memory.fresh[p] && dut.memory.rd_in[p]) begin
                    proof_pending[p]=1;
                    proof_launched[p]=proof_core_edges;
                end
            end
        end
        if (core_step) proof_core_edges++;
    end
    // Observation only: never drives or forces internals. Covers CPU/PPU/DSP/
    // SPC700 pipeline state while the actual whole master clock is stopped.
    always @(negedge clk_service) begin
        if (measuring && !clock_permit && !clk_core) begin
            if (snapshot_valid)
                assert (state_snapshot==stopped_snapshot)
                    else $fatal(1,"whole-clock hold changed console state");
            stopped_snapshot=state_snapshot;
            snapshot_valid=1;
        end else snapshot_valid=0;
    end
    always @(posedge sd_clk) begin
        sd_cycle++;
        if (!sd_cs_n) case ({sd_ras_n,sd_cas_n,sd_we_n})
            3'b011: begin
                assert (sd_cycle-last_ref>=6 && sd_cycle-last_pre[sd_ba]>=2 &&
                        sd_cycle-last_any_act>=2) else $fatal(1,"ACT timing");
                last_act[sd_ba]=sd_cycle; last_any_act=sd_cycle;
            end
            3'b101: begin
                if (measuring) reads++;
                assert (sd_cycle-last_act[sd_ba]>=2 && sd_cycle-last_any_wr>=2)
                    else $fatal(1,"READ timing");
                last_rd[sd_ba]=sd_cycle;
            end
            3'b100: begin
                assert (sd_cycle-last_act[sd_ba]>=2 && sd_dq_oe && !model.dq_e)
                    else $fatal(1,"WRITE timing/DQ contention");
                last_wr[sd_ba]=sd_cycle; last_any_wr=sd_cycle;
                if (measuring) begin
                    commits++;
                    case ({sd_ba,model.row[sd_ba],sd_a[7:0]})
                        21'h100000: if (sd_dq==32'ha5a5a5a5) seen_wram=1;
                        21'h100001: if (sd_dq==32'h5a5a5a5a) seen_mailbox=1;
                        21'h120010: if (sd_dq==32'hc3c3c3c3) seen_save=1;
                        21'h181234: if (sd_dq==32'h5a5a5a5a) seen_aram=1;
                        default: ;
                    endcase
                    for (int i=0;i<4;i++)
                        if ({sd_ba,model.row[sd_ba],sd_a[7:0]}==21'h100100+21'(i) &&
                            sd_dq=={4{8'(17*(i+1))}}) dma_seen[i]=1;
                end
            end
            3'b010: for (int b=0;b<4;b++) if (sd_a[10] || sd_ba==2'(b)) begin
                assert (sd_cycle-last_act[b]>=4 && sd_cycle-last_wr[b]>=2 &&
                        sd_cycle-last_rd[b]>=2) else $fatal(1,"PRE timing");
                last_pre[b]=sd_cycle;
            end
            3'b001: begin
                for (int b=0;b<4;b++)
                    assert (sd_cycle-last_pre[b]>=2) else $fatal(1,"REF precharge");
                assert (sd_cycle-last_ref>=6) else $fatal(1,"tRFC");
                last_ref=sd_cycle;
                if (measuring) refreshes++;
            end
            default: ;
        endcase
        if (memory_initialized)
            assert (sd_cycle-last_ref<RefreshInterval+79) else $fatal(1,"refresh starved");
    end
    always @(posedge clk_service) begin
        if (measuring && free_master_ce) begin
            master_edges++;
            if (!core_step) stalls++;
        end
        if (measuring && core_step) begin
            // The memory guard permits only edges within the native two-edge
            // contract, or after the selected request has actually completed.
            assert (!memory_hold) else $fatal(1,"core edge during pending operation");
            core_edges++;
            if (audio_ready) audios++;
            if (pixel_ce) pixels++;
            if (vs && !previous_vs) begin
                frames++;
                if (frames==1) begin
                    first_vs_master=master_edges;
                    first_vs_core=core_edges;
                    first_vs_audio=audios;
                end else begin
                    frame_master_period=master_edges-first_vs_master;
                    frame_core_period=core_edges-first_vs_core;
                    frame_audio_samples=audios-first_vs_audio;
                end
            end
            previous_vs=vs;
        end
        if (measuring) begin
            assert (overrun_fault==0 && !protocol_fault && model.errors==0)
                else $fatal(1,"real core memory fault o=%h p=%b model=%0d",
                            overrun_fault,protocol_fault,model.errors);
        end
    end

    // Original opcode test, identical memory/DMA/APU checks to core-only proof.
    byte program_bytes [] = '{
        8'h78,8'h18,8'hfb,8'he2,8'h20,
        8'ha9,8'h0f,8'h8d,8'h00,8'h21,
        8'ha9,8'ha5,8'h8f,8'h00,8'h00,8'h7e,
        8'ha9,8'hc3,8'h8f,8'h10,8'h00,8'h70,
        8'had,8'h40,8'h21,8'hc9,8'h5a,8'hd0,8'hf9,
        8'h8f,8'h01,8'h00,8'h7e,
        8'ha9,8'h03,8'h8d,8'h33,8'h21,
        8'ha9,8'h05,8'h8d,8'h05,8'h21,
        8'ha9,8'h00,8'h8d,8'h81,8'h21,
        8'ha9,8'h01,8'h8d,8'h82,8'h21,
        8'ha9,8'h00,8'h8d,8'h83,8'h21,
        8'h8d,8'h00,8'h43,
        8'ha9,8'h80,8'h8d,8'h01,8'h43,
        8'ha9,8'h00,8'h8d,8'h02,8'h43,
        8'ha9,8'h81,8'h8d,8'h03,8'h43,
        8'ha9,8'h00,8'h8d,8'h04,8'h43,
        8'ha9,8'h04,8'h8d,8'h05,8'h43,
        8'ha9,8'h00,8'h8d,8'h06,8'h43,
        8'ha9,8'h01,8'h8d,8'h0b,8'h42,
        8'h80,8'hfe
    };
    function automatic byte rom_byte(input int addr);
        if (addr<program_bytes.size()) begin
            if (use_hirom!=0 && addr==20) return 8'h60;
            if (use_hirom!=0 && addr==21) return 8'h20;
            return program_bytes[addr];
        end
        case (addr)
            256: return 8'h11;
            257: return 8'h22;
            258: return 8'h33;
            259: return 8'h44;
            32764: return 8'h00;
            32765: return 8'h80;
            default: return 8'hea;
        endcase
    endfunction
    function automatic byte ipl_byte(input int addr);
        case (addr)
            0: return 8'he8;
            1: return 8'h5a;
            2: return 8'hc5;
            3: return 8'h34;
            4: return 8'h12;
            5: return 8'he5;
            6: return 8'h34;
            7: return 8'h12;
            8: return 8'hc4;
            9: return 8'hf4;
            10: return 8'h2f;
            11: return 8'hfe;
            62: return 8'hc0;
            63: return 8'hff;
            default: return 8'h00;
        endcase
    endfunction
    task automatic tick;
        @(posedge clk_service); #1ns;
    endtask
    task automatic master_tick;
        @(posedge free_master); #1ns;
    endtask
    task automatic reset_minimum;
        // Exactly four full free-master periods, even when assertion is off-phase.
        #(4*46.560ns);
        reset=0;
    endtask
    task automatic load_asset(input int ch);
        asset_channel=2'(ch); asset_start=1; master_tick(); asset_start=0;
        master_tick();
        for (int i=0;i<(ch==0 ? 64 : 1024);i++) begin
            while (!asset_ready) master_tick();
            asset_valid=1; asset_addr=11'(i);
            asset_data=ch==0 ? ipl_byte(i) : i[0] ? 8'((i>>9)&15) : 8'(i>>1);
            asset_last=i==(ch==0 ? 63 : 1023);
            master_tick(); asset_valid=0;
        end
        do master_tick(); while (asset_busy);
        assert (asset_done && asset_error==0) else $fatal(1,"asset backend completion");
        master_tick();
    endtask
    task automatic host_request(input bit wr,input int addr,input logic [31:0] value);
        while (!host_ready) tick();
        @(negedge clk_service);
        host_addr=21'(addr); host_write=wr; host_wdata=value; host_valid=1;
        tick(); host_valid=0;
        do tick(); while (!host_done);
        if (!wr) assert (host_rdata==value)
            else $fatal(1,"physical readback %h got %h want %h",addr,host_rdata,value);
    endtask
    task automatic boot;
        reset=1; run=0; measuring=0;
        // The public minimum is four periods, including a preceding gated hold.
        reset_minimum();
        repeat (3) master_tick();
        assert (!ipl_ready && !coeff_ready && !active) else $fatal(1,"reset default assets");
        load_asset(0); load_asset(1);
        while (!memory_initialized) tick();
        // Physical-owner handover needs memory init, but must retain user assets.
        while (!stop_ack) tick();
        memory_reset=1;
        repeat (4) tick();
        assert (ipl_ready && coeff_ready && !host_ready && !memory_initialized)
            else $fatal(1,"memory-only reset cleared assets or admitted host");
        memory_reset=0;
        while (!stop_ack) tick();
        // Only the authored program range, DMA pattern and reset vector are
        // written via actual host controller transactions, never model.mem poke.
        for (int i=0;i<(program_bytes.size()+3)/4;i++)
            host_request(1,i,{rom_byte(i*4+3),rom_byte(i*4+2),rom_byte(i*4+1),rom_byte(i*4)});
        host_request(1,64,32'h44332211);
        host_request(1,8191,32'h80008000);
        host_request(1,32'h100000,32'h96969696);
        while (!memory_drained) tick();
        master_edges=0; core_edges=0; stalls=0; frames=0; audios=0; pixels=0;
        refreshes=0; commits=0; reads=0; dma_seen=0;
        seen_wram=0; seen_save=0; seen_aram=0; seen_mailbox=0; previous_vs=0;
        // Exercise all four service launch phases across repeated boots.
        do @(negedge clk_service); while (phase!=2'(boot_count%4));
        boot_count++;
        measuring=1; run=1;
    endtask
    task automatic stop_transaction_probe(input bit write_case,input int delay_edges,
                                          input bit unsafe_asset);
        bit found;
        int old_reads,old_commits;
        found=0;
        while (!found) begin
            @(posedge clk_core); #1ps;
            found=write_case ? dut.wram_wr && dut.wram_addr==0 && dut.wram_data==8'ha5 :
                              dut.rom_rd;
        end
        old_reads=reads; old_commits=commits;
        repeat (delay_edges) tick();
        if (unsafe_asset) begin
            asset_channel=0; asset_start=1;
            // Asset misuse requests a stop while programming remains locked.
            master_tick(); asset_start=0;
        end
        run=0;
        while (!stop_ack) tick();
        assert (!active && memory_drained && !memory_hold && request_inflight==0 &&
                needs_data==0 && !host_valid && overrun_fault==0 && !protocol_fault)
            else $fatal(1,"stop acknowledgement before quiesce");
        if (write_case) assert (commits==old_commits+1)
            else $fatal(1,"last-edge write lost/duplicated phase=%0d",delay_edges);
        else assert (reads>old_reads)
            else $fatal(1,"last-edge read discarded phase=%0d",delay_edges);
        if (unsafe_asset) begin
            assert (asset_error!=0 && !asset_done) else $fatal(1,"unsafe asset accepted");
            repeat (4) master_tick();
            assert (!ipl_ready && !coeff_ready) else $fatal(1,"unsafe assets not invalidated");
        end
        old_reads=reads; old_commits=commits;
        repeat (6) master_tick();
        assert (reads==old_reads && commits==old_commits && !active)
            else $fatal(1,"memory access after stop acknowledgement");
        measuring=0;
        if (write_case) host_request(0,32'h100000,32'ha5a5a5a5);
        $display("PASS stop write=%0d service_phase=%0d unsafe_asset=%0d",
                 write_case,delay_edges,unsafe_asset);
    endtask
    initial begin
        if (!$value$plusargs("hirom=%d",use_hirom)) use_hirom=0;
        if (!$value$plusargs("stop_probe=%d",stop_probe)) stop_probe=0;
        cfg_map=use_hirom!=0 ? 1 : 0;
        boot();
        if (stop_probe!=0) begin
            for (int kind=0;kind<2;kind++)
                for (int d=0;d<4;d++) begin
                    if (kind!=0 || d!=0) boot();
                    stop_transaction_probe(1'(kind),d,0);
                end
            for (int kind=0;kind<2;kind++) begin
                boot(); stop_transaction_probe(1'(kind),0,1);
            end
            boot();
            // Global reset deliberately discards unissued work, unlike stop.
            // Sample the WRITE launch BEFORE controller's +1-service aperture.
            do begin @(posedge clk_core); #1ps; end
            while (!(dut.wram_wr && dut.wram_addr==0 && dut.wram_data==8'ha5));
            measuring=0; reset=1; run=0;
            reset_minimum();
            while (!stop_ack) tick();
            assert (!ipl_ready && !coeff_ready && !active && request_inflight==0)
                else $fatal(1,"global reset did not discard/invalidate");
            host_request(0,32'h100000,32'h96969696);
            $display("PASS global reset discards last unissued write, no proprietary defaults");
            for (int kind=0;kind<2;kind++) begin
                boot();
                do begin @(posedge clk_core); #1ps; end
                while (!(kind!=0 ? dut.wram_wr && dut.wram_addr==0 &&
                                  dut.wram_data==8'ha5 : dut.rom_rd));
                tick();  // accepted at controller +1 aperture, column not issued yet
                assert (request_inflight!=0) else $fatal(1,"reset probe not in flight");
                measuring=0; reset=1; run=0;
                reset_minimum();
                while (!stop_ack) tick();
                assert (request_inflight==0 && needs_data==0 && !memory_hold &&
                        !ipl_ready && !coeff_ready && !host_done)
                    else $fatal(1,"reset retained pending work");
                host_request(0,32'h100000,32'h96969696);
                $display("PASS global reset cancels accepted pre-column write=%0d",kind);
            end
            assert (startup_checks!=0 && reset_clock_checks!=0 && boot_count>=4 &&
                    master_reset_checks!=0 && pair_probe_done)
                else $fatal(1,"missing startup/reset-clock proof");
            $display("PASS startup full-master settle, all four launch phases; %s",
                     "reset-clock handover");
            $finish;
        end
        // Force extra refresh at different free-master phases in addition to
        // periodic collisions, without moving the console's own ENABLE/reset.
        for (int i=0;i<32;i++) begin
            repeat (37+i%4) tick(); refresh_now=1; tick(); refresh_now=0;
        end
        while (frames<2) tick();
        assert (seen_wram && seen_save && seen_aram && seen_mailbox && &dma_seen)
            else $fatal(1,"core path W/S/A/mail/DMA=%b%b%b%b/%b",
                        seen_wram,seen_save,seen_aram,seen_mailbox,dma_seen);
        assert (audios>500 && pixels>100000 && highres && unsupported[3] && !interlace)
            else $fatal(1,"native PPU/APU progress");
        assert (commits==8) else $fatal(1,"held write strobe reissued %0d commits",commits);
        assert (pair_probe_done && master_reset_checks!=0)
            else $fatal(1,"missing registered scheduler/reset boundary proof");
        $display("clock-stretched hirom=%0d free=%0d core=%0d stalls=%0d ratio=%f",
                 use_hirom,master_edges,core_edges,stalls,real'(core_edges)/real'(master_edges));
        $display("frames=%0d audio=%0d pixels=%0d refs=%0d writes=%0d wall_deadline=%h",
                 frames,audios,pixels,refreshes,commits,deadline_fault);
        $display("refresh_interval=%0d measured_wall_ms=%f audio_ready_per_s=%f",
                 RefreshInterval,real'(master_edges)*46.560/1000000.0,
                 real'(audios)/(real'(master_edges)*46.560/1000000000.0));
        $display("complete frame: free=%0d core=%0d samples=%0d fps=%f audio_ready_per_s=%f",
                 frame_master_period,frame_core_period,frame_audio_samples,
                 1000000000.0/(real'(frame_master_period)*46.560),
                 real'(frame_audio_samples)*1000000000.0/(real'(frame_master_period)*46.560));
        run=0;
        while (!stop_ack) tick();
        measuring=0;
        host_request(0,32'h100000,32'ha5a5a5a5);
        host_request(0,32'h100001,32'h5a5a5a5a);
        host_request(0,32'h120010,32'hc3c3c3c3);
        host_request(0,32'h181234,32'h5a5a5a5a);
        for (int i=0;i<4;i++) host_request(0,32'h100100+i,{4{8'(17*(i+1))}});
        core_edges_at_stop=core_edges;
        // Reset really clears validity; then reload through loader and replay
        // the same CPU/APU/DMA path, not hidden retained state.
        boot();
        while (!(seen_wram && seen_save && seen_aram && seen_mailbox && &dma_seen)) tick();
        assert (model.errors==0 && overrun_fault==0 && !protocol_fault &&
                core_edges_at_stop>100000) else $fatal(1,"reboot/fault proof");
        $display("PASS actual SNES->clock guard->SDRAM model Lo/Hi CPU/APU/DMA; reset reload");
        $display("CLOCK-STRETCHED ONLY; no game compatibility/fullspeed/physical timing claim");
        $finish;
    end
    initial begin #200ms; $fatal(1,"timeout"); end
endmodule

// Directed producer -> production memory + guard -> actual SDRAM model.
// No forced internals: prove that a reply captured AT +8 cannot authorize +8.
module snes_pair_guard_probe (
    input wire clk_service, free_master, free_master_ce,
    output logic done=0
);
    logic reset=1, enable=0, wram_rd=0, aram_rd=0;
    logic host_valid=0, host_write=1;
    logic [20:0] host_addr=0;
    logic [31:0] host_wdata=0;
    wire host_ready, host_done, initialized, drained, core_hold;
    wire core_step, clk_core, permit;
    wire [7:0] wram_q, aram_q;
    wire wram_valid, aram_valid;
    wire [3:0] deadline_fault, overrun_fault;
    wire protocol_fault;
    wire [10:0] sd_a;
    wire [1:0] sd_ba;
    wire sd_ras_n, sd_cas_n, sd_we_n, sd_cs_n, sd_cke, sd_dq_oe;
    wire [31:0] sd_dq_out;
    tri [31:0] sd_dq;
    wire sd_clk;
    assign #2ns sd_clk=clk_service;
    assign sd_dq=sd_dq_oe ? sd_dq_out : {32{1'bz}};
    snes_clock_guard guard (.clk_service, .free_master, .free_master_ce, .reset,
        .running(1'b1), .core_hold, .permit, .core_step, .clk_core);
    snes_memory #(.InitCycles(20), .RefreshCycles(480)) memory (
        .clk(clk_service), .reset, .enable, .master_ce(core_step), .refresh_now(1'b0),
        .initialized, .drained, .core_hold, .request_inflight(), .needs_data(),
        .refresh_busy(), .deadline_fault, .overrun_fault, .protocol_fault,
        .wram_addr(17'h1234), .wram_data(8'h00), .wram_rd, .wram_wr(1'b0),
        .wram_q, .wram_valid, .wram_posted(), .wram_committed(),
        .aram_addr(16'h2345), .aram_data(8'h00), .aram_rd, .aram_wr(1'b0),
        .aram_q, .aram_valid, .aram_posted(), .aram_committed(),
        .rom_addr(22'h0), .rom_rd(1'b0), .rom_q(), .rom_valid(),
        .save_addr(17'h0), .save_data(8'h00), .save_rd(1'b0), .save_wr(1'b0),
        .save_q(), .save_valid(), .save_posted(), .save_committed(),
        .host_valid, .host_write, .host_addr, .host_wdata, .host_ready, .host_done,
        .host_rdata(), .sd_a, .sd_ba, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_cs_n,
        .sd_cke, .sd_dq_in(sd_dq), .sd_dq_out, .sd_dq_oe);
    sdram_model #(.TAc(8ns), .TOh(2ns), .TRcd(21ns)) model (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(sd_dq));
    int service_cycle=0, launch_cycle=0, observed_edges=0;
    bit watching=0;
    always @(posedge clk_service) begin
        service_cycle++;
        if (watching && service_cycle==launch_cycle+8)
            assert (!core_step && !aram_valid)
                else $fatal(1,"guard allowed +8 before second actual response");
    end
    always @(posedge clk_core) begin
        if (watching) begin
            assert (service_cycle==launch_cycle+4 || service_cycle==launch_cycle+12)
                else $fatal(1,"unexpected conflict-pair consumer edge +%0d",
                            service_cycle-launch_cycle);
            if (service_cycle==launch_cycle+12)
                assert (wram_q==8'ha6 && aram_q==8'h59)
                    else $fatal(1,"resumed consumer did not see both real replies");
            observed_edges++;
        end
    end
    task automatic tick;
        @(posedge clk_service); #1ns;
    endtask
    task automatic preload(input logic [20:0] address, input logic [31:0] value);
        while (!host_ready) tick();
        @(negedge clk_service);
        host_addr=address; host_wdata=value; host_valid=1;
        tick(); host_valid=0;
        do tick(); while (!host_done);
    endtask
    initial begin
        repeat (4) tick(); reset=0;
        while (!initialized) tick();
        preload(21'h101234,32'ha6a6a6a6);
        preload(21'h182345,32'h59595959);
        while (!drained) tick();
        enable=1;
        @(posedge clk_core); #1ns;
        launch_cycle=service_cycle; watching=1; wram_rd=1; aram_rd=1;
        tick();
        assert (memory.request_inflight[1:0]==2'b11 &&
                {sd_ras_n,sd_cas_n,sd_we_n}==3'b111)
            else $fatal(1,"guarded pair lost +1 admission/registered boundary");
        repeat (6) tick();
        assert (wram_valid && wram_q==8'ha6 && !aram_valid && deadline_fault==0)
            else $fatal(1,"guarded pair first real response not +7");
        tick();
        assert (aram_valid && aram_q==8'h59 && deadline_fault==4'b0010)
            else $fatal(1,"guarded pair second real response/miss not +8");
        repeat (4) tick();
        assert (observed_edges==2 && overrun_fault==0 && !protocol_fault && model.errors==0)
            else $fatal(1,"guarded pair edge count/data/model fault");
        watching=0; wram_rd=0; aram_rd=0; done=1;
        $display("PASS registered pair: admit +1, q +7/+8, core +4/+12; +8 blocked");
    end
endmodule

// Ideal glitch-free simulation stand-in, not part of production source list.
module BUFGCE #(
    parameter string SIM_DEVICE="7SERIES"
) (input wire I,CE,output wire O);
    logic enabled=1;
    always @(negedge I) enabled<=CE;
    assign O=I && enabled;
endmodule
`default_nettype wire
