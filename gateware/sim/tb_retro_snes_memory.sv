`default_nettype none
`timescale 1ns / 1ps
module tb_retro_snes_memory;
    localparam realtime FastPeriod = 11.640ns;
    parameter realtime SdPhase = 2ns;
    logic clk = 0;
    always #(FastPeriod/2) clk = !clk;
    wire sd_clk;
    assign #(SdPhase) sd_clk = clk;
    logic reset = 1, enable = 0, master_ce;
    logic refresh_now = 0;
    int phase = 0, cycle = 0;
    always @(negedge clk) begin
        phase = (phase+1)%4;
        master_ce = phase == 0;
    end
    wire initialized, refresh_busy, drained;
    wire core_hold;
    wire [4:0] request_inflight;
    wire [3:0] needs_data;
    wire [3:0] deadline_fault, overrun_fault;
    wire protocol_fault;
    logic [16:0] wram_addr=0, save_addr=0;
    logic [15:0] aram_addr=0;
    logic [21:0] rom_addr=0;
    logic [7:0] wram_data=0, aram_data=0, save_data=0;
    logic wram_rd=0, wram_wr=0, aram_rd=0, aram_wr=0;
    logic rom_rd=0, save_rd=0, save_wr=0;
    wire [7:0] wram_q, aram_q, rom_q, save_q;
    wire wram_valid, wram_posted, wram_committed;
    wire aram_valid, aram_posted, aram_committed;
    wire rom_valid, save_valid, save_posted, save_committed;
    logic host_valid=0, host_write=0;
    logic [20:0] host_addr=0;
    logic [31:0] host_wdata=0;
    wire host_ready, host_done;
    wire [31:0] host_rdata;
    wire [10:0] sd_a;
    wire [1:0] sd_ba;
    wire sd_ras_n, sd_cas_n, sd_we_n, sd_cs_n, sd_cke, sd_dq_oe;
    wire [31:0] sd_dq_in, sd_dq_out;
    tri [31:0] sd_dq;
    assign sd_dq = sd_dq_oe ? sd_dq_out : {32{1'bz}};
    assign sd_dq_in = sd_dq;
    snes_memory #(.InitCycles(20), .RefreshCycles(480)) dut (.*);
    sdram_model model (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .ba(sd_ba), .a(sd_a), .dqm(4'b0000), .dq(sd_dq));

    int last_act[4]='{-1000,-1000,-1000,-1000};
    int last_pre[4]='{-1000,-1000,-1000,-1000};
    int last_write[4]='{-1000,-1000,-1000,-1000};
    int last_read[4]='{-1000,-1000,-1000,-1000};
    int last_ref=-1000, last_any_act=-1000, last_mrs=-1000, last_any_write=-1000;
    int refs=0, acts=0, columns=0;
    bit mode_seen=0;
    always @(posedge sd_clk) begin
        cycle++;
        if (!sd_cs_n) case ({sd_ras_n,sd_cas_n,sd_we_n})
            3'b000: begin
                assert (sd_a==11'h020) else $fatal(1,"mode not CL2 BL1");
                assert (cycle-last_ref>=6) else $fatal(1,"MRS tRFC");
                last_mrs=cycle; mode_seen=1;
            end
            3'b011: begin
                assert (mode_seen && cycle-last_mrs>=2) else $fatal(1,"ACT before MRS/tMRD");
                assert (cycle-last_ref>=6 && cycle-last_pre[sd_ba]>=2 &&
                        cycle-last_any_act>=2) else $fatal(1,"ACT tRFC/tRP/tRRD");
                last_act[sd_ba]=cycle; last_any_act=cycle; acts++;
            end
            3'b101,3'b100: begin
                assert (cycle-last_act[sd_ba]>=2) else $fatal(1,"tRCD cycles");
                if (sd_we_n) begin
                    assert (cycle-last_any_write>=2) else $fatal(1,"tWTR");
                    last_read[sd_ba]=cycle;
                end
                else begin
                    assert (sd_dq_oe) else $fatal(1,"write without DQ drive");
                    assert (!model.dq_e) else $fatal(1,"READ/WRITE DQ contention");
                    last_write[sd_ba]=cycle;
                    last_any_write=cycle;
                end
                columns++;
            end
            3'b010: begin
                for (int b=0;b<4;b++) if (sd_a[10] || sd_ba==2'(b)) begin
                    assert (cycle-last_act[b]>=4 && cycle-last_write[b]>=2 &&
                            cycle-last_read[b]>=2) else $fatal(1,"PRE tRAS/tWR/tRTP");
                    last_pre[b]=cycle;
                end
            end
            3'b001: begin
                for (int b=0;b<4;b++)
                    assert (cycle-last_pre[b]>=2) else $fatal(1,"REF tRP");
                assert (cycle-last_ref>=6) else $fatal(1,"REF tRFC");
                refs++; last_ref=cycle;
            end
            default: ;
        endcase
        if (initialized)
            assert (cycle-last_ref<540) else $fatal(1,"refresh starved");
    end

    int fast_cycle=0;
    int w_valid_cycle=-1, a_valid_cycle=-1, r_valid_cycle=-1, s_valid_cycle=-1;
    int w_post_cycle=-1, a_post_cycle=-1, s_post_cycle=-1;
    int w_commit_count=0, a_commit_count=0, s_commit_count=0;
    always @(posedge clk) begin
        fast_cycle++;
        #1ps;
        if (wram_valid) w_valid_cycle=fast_cycle;
        if (aram_valid) a_valid_cycle=fast_cycle;
        if (rom_valid) r_valid_cycle=fast_cycle;
        if (save_valid) s_valid_cycle=fast_cycle;
        if (wram_posted) w_post_cycle=fast_cycle;
        if (aram_posted) a_post_cycle=fast_cycle;
        if (save_posted) s_post_cycle=fast_cycle;
        if (wram_committed) w_commit_count++;
        if (aram_committed) a_commit_count++;
        if (save_committed) s_commit_count++;
    end
    task automatic tick;
        @(posedge clk); #1ns;
    endtask
    task automatic masters(input int count);
        repeat (count) begin
            do tick(); while (!master_ce);
        end
    endtask
    task automatic boundary;
        do tick(); while (!master_ce);
    endtask
    task automatic drain;
        wram_rd=0; wram_wr=0; aram_rd=0; aram_wr=0;
        rom_rd=0; save_rd=0; save_wr=0;
        repeat (40) tick();
    endtask
    task automatic host(input bit wr,input logic [20:0] addr,input logic [31:0] value);
        assert (!enable) else $fatal(1,"host when enabled");
        while (!host_ready) tick();
        @(negedge clk);
        host_addr=addr; host_write=wr; host_wdata=value; host_valid=1;
        tick(); host_valid=0;
        do tick(); while (!host_done);
        if (!wr) assert (host_rdata===value)
            else $fatal(1,"host read %h=%h want %h",addr,host_rdata,value);
    endtask
    task automatic cpu_aram_pair(input int kind,input int wi,input int ai,
                                 input byte wvalue,input byte avalue);
        int start_cycle;
        boundary();
        start_cycle=fast_cycle;
        aram_addr=16'(ai); aram_rd=1;
        case (kind)
            0: begin wram_addr=17'(wi); wram_rd=1; end
            1: begin rom_addr=22'(wi); rom_rd=1; end
            2: begin save_addr=17'(wi); save_rd=1; end
            default: $fatal(1,"kind");
        endcase
        masters(2);
        assert (a_valid_cycle>start_cycle && a_valid_cycle<start_cycle+8 && aram_q==avalue)
            else $fatal(1,"ARAM deadline/data latency=%0d data=%h want %h",
                        a_valid_cycle-start_cycle,aram_q,avalue);
        case (kind)
            0: assert (w_valid_cycle>start_cycle && w_valid_cycle<start_cycle+8 &&
                       wram_q==wvalue) else $fatal(1,"WRAM pair deadline/data");
            1: assert (r_valid_cycle>start_cycle && r_valid_cycle<start_cycle+8 &&
                       rom_q==wvalue) else $fatal(1,"ROM pair deadline/data");
            2: assert (s_valid_cycle>start_cycle && s_valid_cycle<start_cycle+8 &&
                       save_q==wvalue) else $fatal(1,"save pair deadline/data");
            default: ;
        endcase
        assert (deadline_fault==0 && overrun_fault==0 && !protocol_fault)
            else $fatal(1,"unexpected pair fault d=%h o=%h",deadline_fault,overrun_fault);
        $display("ok pair kind=%0d CPU=%0d ARAM=%0d fast edges",kind,
                 (kind==0 ? w_valid_cycle : kind==1 ? r_valid_cycle : s_valid_cycle)-start_cycle,
                 a_valid_cycle-start_cycle);
        drain();
    endtask

    int start_cycle, before_refs;
    initial begin
        master_ce=0;
        repeat (4) tick(); reset=0;
        do tick(); while (!initialized);
        // Packed ROM lane boundaries; all banks and independent writable windows.
        host(1,21'h000000,32'h44332211);
        host(1,21'h07ffff,32'h88776655);
        host(1,21'h080000,32'hccbbaa99);
        host(1,21'h0fffff,32'h10fedcba);
        host(1,21'h100000,32'ha1a1a1a1);
        host(1,21'h11ffff,32'hb2b2b2b2);
        host(1,21'h120000,32'hc3c3c3c3);
        host(1,21'h13ffff,32'hd4d4d4d4);
        host(1,21'h180000,32'he5e5e5e5);
        host(1,21'h18ffff,32'hf6f6f6f6);
        drain(); enable=1;
        cpu_aram_pair(0,0,0,8'ha1,8'he5);
        cpu_aram_pair(0,131071,65535,8'hb2,8'hf6);
        cpu_aram_pair(1,0,0,8'h11,8'he5);
        cpu_aram_pair(1,1,65535,8'h22,8'hf6);
        cpu_aram_pair(1,2,0,8'h33,8'he5);
        cpu_aram_pair(1,3,65535,8'h44,8'hf6);
        cpu_aram_pair(1,2097151,0,8'h88,8'he5);
        cpu_aram_pair(1,2097152,0,8'h99,8'he5);
        cpu_aram_pair(1,4194303,0,8'h10,8'he5);
        cpu_aram_pair(2,0,0,8'hc3,8'he5);
        cpu_aram_pair(2,131071,65535,8'hd4,8'hf6);
        // Dense stream at one request per two masters, alternating bank/row
        // addresses. Correct data must survive recovery even if deadline fails.
        for (int i=0;i<12;i++) begin
            boundary(); start_cycle=fast_cycle;
            wram_addr=i[0] ? 17'h1ffff : 0; wram_rd=1;
            aram_addr=i[0] ? 16'hffff : 0; aram_rd=1;
            masters(2);
            do tick(); while (w_valid_cycle<=start_cycle || a_valid_cycle<=start_cycle);
            assert (wram_q==(i[0] ? 8'hb2 : 8'ha1) &&
                    aram_q==(i[0] ? 8'hf6 : 8'he5)) else $fatal(1,"dense read lost data");
        end
        drain();
        // Parallel posted byte writes, with every adjacent lane physically overwritten.
        boundary(); wram_addr=1; wram_data=8'h17; wram_wr=1;
        aram_addr=2; aram_data=8'h28; aram_wr=1;
        save_addr=3; save_data=8'h39; save_wr=1;
        masters(2);
        assert (w_post_cycle>=0 && a_post_cycle>=0 && s_post_cycle>=0)
            else $fatal(1,"posted write lost");
        drain(); enable=0;
        host(0,21'h100001,32'h17171717);
        host(0,21'h180002,32'h28282828);
        host(0,21'h120003,32'h39393939);
        host(0,21'h100000,32'ha1a1a1a1);
        host(0,21'h120000,32'hc3c3c3c3);
        drain(); enable=1;
        // ROM->WRAM DMA ordering: destination data comes from completed ROM read.
        boundary(); rom_addr=1; rom_rd=1; masters(2);
        assert (rom_q==8'h22) else $fatal(1,"DMA source read");
        wram_addr=20; wram_data=rom_q; wram_wr=1;
        masters(1); wram_wr=0; wram_rd=1; masters(2);
        assert (wram_q==8'h22) else $fatal(1,"DMA write/read forwarding");
        drain();
        // A write posted while refresh blocks SDRAM must forward a subsequent
        // read immediately, and still physically commit after refresh.
        boundary(); before_refs=refs; refresh_now=1; tick(); refresh_now=0;
        while (refs==before_refs) tick();
        boundary(); wram_addr=30; wram_data=8'h6b; wram_wr=1;
        masters(1); start_cycle=fast_cycle; wram_wr=0; wram_rd=1;
        masters(1);
        assert (w_valid_cycle>start_cycle && w_valid_cycle<start_cycle+4 && wram_q==8'h6b)
            else $fatal(1,"posted write forwarding through refresh");
        drain(); enable=0; host(0,21'h10001e,32'h6b6b6b6b); drain(); enable=1;
        // Force REF first, issue new two-channel reads during tRFC. Completion
        // MUST be late and flagged; returning a held prior q as valid is forbidden.
        reset=1; tick(); reset=0;
        do tick(); while (!initialized);
        boundary(); before_refs=refs; refresh_now=1; tick(); refresh_now=0;
        while (refs==before_refs) tick();
        boundary(); start_cycle=fast_cycle;
        wram_addr=131071; wram_rd=1; aram_addr=65535; aram_rd=1;
        masters(2);
        assert (deadline_fault!=0) else $fatal(1,"refresh collision falsely claimed deadline");
        do tick(); while (w_valid_cycle<=start_cycle || a_valid_cycle<=start_cycle);
        assert (wram_q==8'hb2 && aram_q==8'hf6)
            else $fatal(1,"late refresh read data lost");
        assert (w_valid_cycle>=start_cycle+8 || a_valid_cycle>=start_cycle+8)
            else $fatal(1,"refresh test did not exercise failing bound");
        $display("ok expected deadline failure: REF collision WRAM=%0d ARAM=%0d fast edges",
                 w_valid_cycle-start_cycle,a_valid_cycle-start_cycle);
        // Four read clients at once, including WRAM+save sharing bank 2.
        // This is outside normal one-CPU-stream envelope; preserve all replies
        // and mark late ones instead of silently dropping lower-priority ports.
        drain(); boundary(); start_cycle=fast_cycle;
        wram_addr=0; wram_rd=1;
        aram_addr=0; aram_rd=1;
        rom_addr=3; rom_rd=1;
        save_addr=131071; save_rd=1;
        masters(2);
        assert (w_valid_cycle>start_cycle && a_valid_cycle>start_cycle)
            else $fatal(1,"primary channels starved");
        do tick(); while (r_valid_cycle<=start_cycle || s_valid_cycle<=start_cycle);
        assert (wram_q==8'ha1 && aram_q==8'he5 && rom_q==8'h44 && save_q==8'hd4)
            else $fatal(1,"maximum concurrency lost response");
        assert (s_valid_cycle>=start_cycle+8 && deadline_fault[3])
            else $fatal(1,"same-bank concurrent deadline incorrectly claimed");
        $display("ok all four clients: latency W/A/R/S=%0d/%0d/%0d/%0d; late flagged",
                 w_valid_cycle-start_cycle,a_valid_cycle-start_cycle,
                 r_valid_cycle-start_cycle,s_valid_cycle-start_cycle);
        drain(); enable=0;
        before_refs=refs;
        repeat (2000) tick();
        assert (refs>=before_refs+3 && model.errors==0 && overrun_fault==0 && !protocol_fault)
            else $fatal(1,"refresh/model/overrun errors refs=%0d model=%0d o=%h",
                        refs,model.errors,overrun_fault);
        // Faults are observable for invalid producer pressure too; do not
        // acknowledge an overwritten single-entry buffer as a valid response.
        enable=1; boundary(); before_refs=refs; refresh_now=1; tick(); refresh_now=0;
        while (refs==before_refs) tick();
        boundary(); wram_addr=0; wram_rd=1;
        masters(1); wram_addr=131071;
        masters(1);
        assert (overrun_fault[0]) else $fatal(1,"inflight request overwrite not flagged");
        drain();
        boundary(); wram_rd=1; wram_wr=1;
        masters(1);
        assert (protocol_fault) else $fatal(1,"simultaneous read/write not rejected");
        drain();
        $display("PASS SNES memory: real DQM=0 model, two-channel normal <=2 masters,");
        $display("posted writes/DMA/noalias/init/refresh; expected FAIL exposed, refs=%0d",refs);
        $finish;
    end
    initial begin
        #2ms;
        $fatal(1,"timeout");
    end
endmodule
`default_nettype wire
