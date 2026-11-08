// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Independent SNES SDR controller, no upstream controller/vendor IP.
// clk = 3 * SNES master (64.43 MHz, 15.52 ns). Rising edges coincide; the edge
// coincident with a master edge is s0. master_ce marks an EXECUTED master edge
// (sampled 1 at s0), free_ce every master edge (same, ungated).
//
// Request sampling: console outputs launch at s0 and are captured at s2 (two
// service periods, multicycle in the physical top). One cycle later (s3) the
// request is compared with the previous sample and ACT may issue.
// Read: ACT s3, READ+autoprecharge s5 (tRCD 2 = 31 ns), CL2, pin captured in the
// pad at READ+PinCapture (s8), q at s9 (a master s0 edge: age 7 service cycles).
// q registers change only on s0/s1 edges, never s2: q -> console is a two service
// period path to the next master edge. Measured core tolerance (simulation of the
// SNESTang core with idealised memory, LoROM game + FastROM/DMA stress): data
// updated at master edge +4 (s12) is consumed correctly, +5 is not. Hard bound
// here: q no later than s12; deadline_fault reports a miss. No clock holds.
//
// Concurrency: at most one CPU-side read per master edge (DMA pairs one read with
// one write). ARAM is in block RAM (snes_aram), not here. Physical words
// {bank[1:0],row[10:0],column[7:0]}, DQM permanently zero:
// ROM 4 MiB packed: banks 0/1, word = rom_byte_addr >> 2.
// WRAM 128 KiB: bank 2, words 0..131071, byte replicated to all lanes.
// Save 128 KiB: bank 2, words 131072..262143 (row 512 onwards).
// Reads take priority over posted writes. A same-address read of the port's last
// write is answered from that register (committed or not).
// Writes: posted, committed later (*_committed).
// Core strobes are levels; detect assertion/address/direction/data changes.
// ESMT M12L64322A(2S)-7, Rev1.0 pp6-7: tRCD/tRP 21, tRAS 42, tRC/tRFC 63,
// tRRD 14 ns, tRDL 2 clk; at 15.52 ns: tRCD 2, tRP 2, tRFC 5, tRRD 1.
//
// Refresh by construction. 4096 AUTO REFRESH per 64 ms: one owed every 15.625 us
// (RefreshInterval). They are paid only where they cannot delay the console:
//  - the S-CPU's own DRAM refresh pause (cpu.v REFS_EXEC: 5 CPU steps x 8 masters =
//    40 masters once per 1364-master line, CPU and DMA stopped);
//  - any time the console clock is stopped or the console is not running.
// Last safe REF in the pause: the first request after the pause is launched at master
// edge P0+40 (P0 = first quiet edge) and wants ACT at its s3 = 3*(P0+40)+3. quiet_edges
// = k holds until cycle 3*(P0+k)+3; a REF there frees ACT tRFC = 5 cycles later:
// 3*(P0+k)+3+5 <= 3*(P0+40)+3  =>  k <= QuietLast = (3*40-5)/3 = 38. Reads still keep
// 3 cycles of slack (q at s9, deadline s12) for a one-master error in the pause edge.
// Debt per line: 4092 cycles / 1006 = at most 5 owed, the pause pays up to 38/2 = 19
// (REF + 4 tRFC wait = 5 cycles = 1.7 masters each). So while the console runs the debt
// never reaches DebtLimit; if it does (pause missing, e.g. a core change), REF goes
// first, refresh_forced latches and a read may be late (deadline_fault). Data safety
// keeps priority over latency. ESMT allows 8 postponed REF; DebtLimit = 7.
module snes_memory #(
    parameter int unsigned InitCycles = 13000,   // >= 200 us at 64.43 MHz
    parameter int unsigned ClockPs = 15520,      // service clock period
    // One AUTO REFRESH per 15.625 us (4096 / 64 ms). Benches may refresh faster.
    parameter int unsigned RefreshInterval = 15_625_000 / ClockPs,
    // Pin capture edge after READ (pad IDDR): the command is taken by the SDRAM clock
    // edge 11.5 ns after launch (clock 4.04 ns early, retro_snes_clocks), CL2 data
    // reaches the pad before READ+3. Board window: diag retro_sdram_eye_snes3_prod.
    parameter int unsigned PinCapture = 3
) (
    input wire clk, reset, master_ce, free_ce, enable,
    // Console's own DRAM refresh pause (SNES_REFRESH, CPU/DMA bus idle 40 masters/line).
    input wire cpu_refresh,
    output wire initialized,
    output wire drained,
    output wire core_hold,                  // always 0: no clock holds
    output logic [3:0] request_inflight,    // {host, save, ROM, WRAM}
    output wire [2:0] needs_data,
    output wire refresh_busy,
    output logic refresh_forced,            // debt reached DebtLimit while running
    output logic [2:0] deadline_fault,      // {save, ROM, WRAM}
    output logic [2:0] overrun_fault,
    output logic protocol_fault,
    output logic [3:0] max_latency,         // worst sample->q service cycles seen
    input wire [16:0] wram_addr,
    input wire [7:0] wram_data,
    input wire wram_rd, wram_wr,
    output logic [7:0] wram_q,
    output wire wram_valid, wram_posted, wram_committed,
    input wire [21:0] rom_addr,
    input wire rom_rd,
    output logic [7:0] rom_q,
    output wire rom_valid,
    input wire [16:0] save_addr,
    input wire [7:0] save_data,
    input wire save_rd, save_wr,
    output logic [7:0] save_q,
    output wire save_valid, save_posted, save_committed,
    // Stopped-console loader/debug port. valid/ready then exactly one done.
    input wire host_valid, host_write,
    input wire [20:0] host_addr,
    input wire [31:0] host_wdata,
    output wire host_ready,
    output logic host_done,
    output logic [31:0] host_rdata,
    output logic [10:0] sd_a = '0,
    output logic [1:0] sd_ba = '0,
    output wire sd_ras_n, sd_cas_n, sd_we_n,
    output wire sd_cs_n, sd_cke,
    // Pad PHY: sd_dq_in is the pin captured at the previous edge (IDDR Q1).
    // sd_dq_out/sd_dq_oe_next are sampled by the pad ODDRs at the WRITE edge.
    input wire [31:0] sd_dq_in,
    output wire [31:0] sd_dq_out,
    output wire sd_dq_oe_next,
    output logic sd_dq_oe                    // registered copy for a fabric tristate
);
    localparam int P = 3;                    // CPU ports: 0 WRAM, 1 ROM, 2 save
    localparam int Host = 3;
    localparam int C = 4;                    // CPU ports + host
    localparam logic [2:0] Nop = 3'b111, Act = 3'b011, Read = 3'b101;
    localparam logic [2:0] Write = 3'b100, Pre = 3'b010, Ref = 3'b001, Mode = 3'b000;
    localparam int Trfc = 5;                 // 63 ns
    localparam int PauseMasters = 40;        // cpu.v REFS_EXEC
    localparam int QuietLast = (3 * PauseMasters - Trfc) / 3;
    localparam int DebtLimit = 7;
    localparam int Deadline = 10;            // s2 sample -> q at s12 (master +4)
    initial begin
        assert (RefreshInterval * ClockPs <= 15_625_000) else $fatal(1, "refresh too slow");
        assert (QuietLast == 38) else $fatal(1, "pause arithmetic changed");
    end
    typedef enum logic [2:0] {PowerWait, InitPre, InitRefA, InitRefB, InitMode,
                              Running} state_t;
    state_t state;
    logic [$clog2(InitCycles+1)-1:0] wait_left;
    logic [$clog2(RefreshInterval+1)-1:0] refresh_left;
    logic [3:0] ref_owed;
    logic configured;
    logic s_quiet;
    logic [5:0] quiet_edges;
    logic [2:0] since_step;
    wire idle_clock = since_step == 3'd7;
    logic [2:0] cmd = 3'b111;               // NOP from configuration on

    // ---- phase and sampling ----
    logic c1, c2, f1, f2, proc;
    logic [P-1:0] s_rd, s_wr, o_rd, o_wr;
    logic [20:0] s_addr [P], o_addr [P];
    logic [7:0] s_data [P], o_data [P];
    logic [1:0] s_lane, o_lane;

    // ---- per client queues ----
    logic [C-1:0] rp, wp;                    // read / write waiting for ACT
    logic [20:0] ra [C], wa [C];
    logic [31:0] wd [C];
    logic [1:0] rl [C];
    logic [3:0] rage [C];                    // read age since sample (CPU ports)
    // Last write per port (only this port writes its addresses while running):
    // a same-address read is answered from here, committed or not.
    logic [P-1:0] lw_v;
    logic [20:0] lw_a [P];
    logic [7:0] lw_d [P];
    // ---- banks ----
    typedef enum logic [1:0] {BIdle, BActed, BRecover} bank_t;
    bank_t bs [4];
    logic [2:0] bcnt [4];
    logic [1:0] bclient [4];
    logic bwrite [4];
    logic [7:0] bcol [4];
    logic [31:0] bdata [4];
    logic [1:0] blane [4];
    logic [3:0] bage [4];
    logic [2:0] ref_wait;
    logic [1:0] since_read;                  // clocks since last READ command (sat 3)
    // ---- read return pipeline ----
    localparam int RP = PinCapture + 1;
    logic [RP-1:0] rpv;
    logic [1:0] rpc [RP];
    logic [1:0] rpl [RP];
    logic [3:0] rpa [RP];
    logic [P-1:0] stage_v;
    logic [7:0] stage_d [P];
    logic [3:0] stage_a [P];
    logic [P-1:0] valid_read;
    logic [P-1:0] posted, physical_write;   // ROM bit unused

    // ---- request detection (combinational, uses s2 sample at proc edge) ----
    logic [P-1:0] fresh, fresh_rd, fresh_wr, forwarded, new_overrun, new_protocol;
    always_comb begin
        fresh = 0; fresh_rd = 0; fresh_wr = 0; forwarded = 0;
        new_overrun = 0; new_protocol = 0;
        if (proc) begin
            for (int p = 0; p < P; p++) begin
                if ((s_rd[p] && (!o_rd[p] || s_addr[p] != o_addr[p] ||
                                 (p == 1 && s_lane != o_lane))) ||
                    (s_wr[p] && (!o_wr[p] || s_addr[p] != o_addr[p] ||
                                 s_data[p] != o_data[p]))) begin
                    if (s_rd[p] && s_wr[p]) new_protocol[p] = 1;
                    else if (s_rd[p]) begin
                        if (lw_v[p] && lw_a[p] == s_addr[p]) forwarded[p] = 1;
                        else if (rp[p] || reading(p)) new_overrun[p] = 1;
                        else begin fresh[p] = 1; fresh_rd[p] = 1; end
                    end else begin
                        if (wp[p]) new_overrun[p] = 1;
                        else begin fresh[p] = 1; fresh_wr[p] = 1; end
                    end
                end
            end
        end
    end
    // A client read already ACTed / in flight.
    function automatic bit reading(input int p);
        bit r = 0;
        for (int b = 0; b < 4; b++)
            if (bs[b] == BActed && !bwrite[b] && bclient[b] == 2'(p)) r = 1;
        for (int i = 0; i < RP; i++) if (rpv[i] && rpc[i] == 2'(p)) r = 1;
        if (stage_v[p]) r = 1;
        return r;
    endfunction

    // ---- next-cycle request view: queued plus fresh ----
    logic [C-1:0] rq, wq;
    logic [20:0] rqa [C], wqa [C];
    logic [31:0] wqd [C];
    logic [1:0] rql [C];
    logic host_take;
    assign host_ready = configured && !reset && !enable && !rp[Host] && !wp[Host] &&
                        !host_busy();
    function automatic bit host_busy();
        bit r = 0;
        for (int b = 0; b < 4; b++) if (bs[b] == BActed && bclient[b] == 2'(Host)) r = 1;
        for (int i = 0; i < RP; i++) if (rpv[i] && rpc[i] == 2'(Host)) r = 1;
        return r;
    endfunction
    assign host_take = host_valid && host_ready;
    always_comb begin
        rq = rp; wq = wp; rqa = ra; wqa = wa; wqd = wd; rql = rl;
        for (int p = 0; p < P; p++) begin
            if (fresh_rd[p]) begin
                rq[p] = 1; rqa[p] = s_addr[p]; rql[p] = p == 1 ? s_lane : 2'd0;
            end
            if (fresh_wr[p]) begin
                wq[p] = 1; wqa[p] = s_addr[p]; wqd[p] = {4{s_data[p]}};
            end
        end
    end

    wire ref_pend = ref_owed != 0;
    // ---- scheduler ----
    logic all_idle;
    int col_bank, act_client;
    logic act_write;
    always_comb begin
        all_idle = ref_wait == 0;
        for (int b = 0; b < 4; b++) if (bs[b] != BIdle || bcnt[b] != 0) all_idle = 0;
        // 1. column command for an ACTed bank (oldest first: lowest bcnt done first)
        col_bank = -1;
        for (int b = 3; b >= 0; b--)
            if (bs[b] == BActed && bcnt[b] == 0 && (!bwrite[b] || since_read == 3))
                col_bank = b;
        // 2. ACT for a read, 3. ACT for a write (reads first). ROM/WRAM/save before
        // host; CPU port order is irrelevant (one CPU read per edge).
        act_client = -1; act_write = 0;
        if (state == Running && col_bank < 0 && ref_wait == 0 && ref_owed < 4'(DebtLimit)) begin
            for (int p = C-1; p >= 0; p--)
                if (rq[p] && bs[rqa[p][20:19]] == BIdle && bcnt[rqa[p][20:19]] == 0)
                    act_client = p;
            if (act_client < 0)
                for (int p = C-1; p >= 0; p--)
                    if (wq[p] && bs[wqa[p][20:19]] == BIdle && bcnt[wqa[p][20:19]] == 0) begin
                        act_client = p; act_write = 1;
                    end
        end
    end
    // Safe windows (header): console not running, its clock stopped (no executed master
    // edge for 4 cycles), or inside the S-CPU pause up to QuietLast. At DebtLimit the
    // REF goes before queued requests (ACTs wait above).
    wire forced = ref_owed >= 4'(DebtLimit);
    wire ref_window = !enable || forced || idle_clock ||
                      (quiet_edges != 0 && quiet_edges <= 6'(QuietLast));
    wire issue_ref;
    wire do_ref = state == Running && col_bank < 0 && act_client < 0 && ref_owed != 0 &&
                  ref_window && all_idle && (rq == 0 && wq == 0 || forced);
    assign issue_ref = do_ref && wait_left == 0;
    // Refresh debt: +1 per interval, -1 per issued REF.
    logic [3:0] owed_next;
    always_comb begin
        logic [4:0] owed;
        owed = 5'(ref_owed) + 5'(refresh_left == 0) - 5'(issue_ref);
        owed_next = owed > 15 ? 4'hf : 4'(owed);
    end
    assign sd_dq_oe_next = col_bank >= 0 && bwrite[col_bank] && !reset;
    assign sd_dq_out = col_bank >= 0 ? bdata[col_bank] : 32'h0;

    assign {sd_ras_n, sd_cas_n, sd_we_n} = cmd;
    assign sd_cs_n = reset;
    assign sd_cke = 1'b1;
    assign core_hold = 1'b0;
    assign initialized = configured && !reset;
    assign refresh_busy = ref_pend || ref_wait != 0;
    always_comb begin
        request_inflight = rp | wp;
        for (int b = 0; b < 4; b++) if (bs[b] == BActed) request_inflight[bclient[b]] = 1;
        for (int i = 0; i < RP; i++) if (rpv[i]) request_inflight[rpc[i]] = 1;
        for (int p = 0; p < P; p++) if (stage_v[p]) request_inflight[p] = 1;
    end
    assign needs_data = request_inflight[P-1:0] & ~wp[P-1:0];
    // Refresh debt does not block a drain: it is paid in idle cycles later.
    assign drained = initialized && state == Running && request_inflight == 0 &&
                     all_idle && !proc;
    assign {save_valid, rom_valid, wram_valid} = valid_read;
    assign {save_posted, wram_posted} = {posted[2], posted[0]};
    assign {save_committed, wram_committed} = {physical_write[2], physical_write[0]};

    function automatic logic [20:0] in_addr(input int p);
        case (p)
            0: return {2'b10, 2'b00, wram_addr};
            1: return {1'b0, rom_addr[21:2]};
            default: return {2'b10, 2'b01, save_addr};
        endcase
    endfunction

    task automatic deliver(input int p, input logic [7:0] d, input logic [3:0] age);
        case (p)
            0: wram_q <= d; 1: rom_q <= d; default: save_q <= d;
        endcase
        valid_read[p] <= 1;
        if (int'(age) > Deadline) deadline_fault[p] <= 1;
        if (age > max_latency) max_latency <= age;
    endtask

    always_ff @(posedge clk) begin
        cmd <= Nop;
        sd_dq_oe <= 0;
        valid_read <= 0;
        posted <= 0;
        physical_write <= 0;
        host_done <= 0;
        c1 <= master_ce; c2 <= c1; f1 <= free_ce; f2 <= f1;
        proc <= c2 && enable && configured;
        if (c2) begin
            s_rd <= enable ? {save_rd, rom_rd, wram_rd} : 3'b0;
            s_wr <= enable ? {save_wr, 1'b0, wram_wr} : 3'b0;
            for (int p = 0; p < P; p++) s_addr[p] <= in_addr(p);
            s_data[0] <= wram_data; s_data[1] <= 8'h00; s_data[2] <= save_data;
            s_lane <= rom_addr[1:0];
            s_quiet <= cpu_refresh;
        end
        if (reset) begin
            state <= PowerWait;
            wait_left <= $bits(wait_left)'(InitCycles);
            refresh_left <= $bits(refresh_left)'(RefreshInterval - 1);
            refresh_forced <= 0;
            ref_owed <= 0; ref_wait <= 0; quiet_edges <= 0; since_step <= 0;
            configured <= 0;
            proc <= 0; c1 <= 0; c2 <= 0;
            rp <= 0; wp <= 0; rpv <= 0; stage_v <= 0; lw_v <= 0;
            o_rd <= 0; o_wr <= 0;
            deadline_fault <= 0; overrun_fault <= 0; protocol_fault <= 0;
            max_latency <= 0;
            since_read <= 3;
            sd_a <= 0; sd_ba <= 0;
            wram_q <= 0; rom_q <= 0; save_q <= 0; host_rdata <= 0;
            for (int b = 0; b < 4; b++) begin bs[b] <= BIdle; bcnt[b] <= 0; end
        end else begin
            // ---- bookkeeping ----
            if (since_read != 3) since_read <= since_read + 1'b1;
            if (ref_wait != 0) ref_wait <= ref_wait - 1'b1;
            for (int b = 0; b < 4; b++) begin
                if (bcnt[b] != 0) bcnt[b] <= bcnt[b] - 1'b1;
                if (bs[b] == BRecover && bcnt[b] <= 1) bs[b] <= BIdle;
                if (bage[b] != 4'hf) bage[b] <= bage[b] + 1'b1;
            end
            for (int p = 0; p < C; p++) if (rage[p] != 4'hf) rage[p] <= rage[p] + 1'b1;
            for (int p = 0; p < P; p++)
                if (stage_a[p] != 4'hf) stage_a[p] <= stage_a[p] + 1'b1;
            if (!enable) lw_v <= 0;
            if (proc) begin
                o_rd <= s_rd; o_wr <= s_wr; o_addr <= s_addr; o_data <= s_data;
                o_lane <= s_lane;
            end
            overrun_fault <= overrun_fault | new_overrun;
            if (|new_protocol) protocol_fault <= 1;
            // queues take fresh requests
            rp <= rq; wp <= wq; ra <= rqa; wa <= wqa; wd <= wqd; rl <= rql;
            for (int p = 0; p < P; p++) begin
                if (fresh_rd[p]) rage[p] <= 4'd1;          // sampled at s2 (age 0), now s3
                if (fresh_wr[p]) begin
                    posted[p] <= 1;
                    lw_v[p] <= 1; lw_a[p] <= s_addr[p]; lw_d[p] <= s_data[p];
                end
            end
            if (host_take) begin
                if (host_write) begin
                    wp[Host] <= 1; wa[Host] <= host_addr; wd[Host] <= host_wdata;
                end else begin
                    rp[Host] <= 1; ra[Host] <= host_addr; rl[Host] <= 0; rage[Host] <= 0;
                end
            end
            // forwarded reads deliver at once (allowed phase) or via stage
            for (int p = 0; p < P; p++) if (forwarded[p]) begin
                if (!f2) deliver(p, lw_d[p], 4'd1);
                else begin stage_v[p] <= 1; stage_d[p] <= lw_d[p]; stage_a[p] <= 4'd1; end
            end
            // ---- read return ----
            rpv <= {rpv[RP-2:0], 1'b0};
            for (int i = 1; i < RP; i++) begin
                rpc[i] <= rpc[i-1]; rpl[i] <= rpl[i-1]; rpa[i] <= rpa[i-1];
            end
            for (int p = 0; p < P; p++)
                if (stage_v[p] && !f2) begin
                    deliver(p, stage_d[p], stage_a[p] + 1'b1);
                    stage_v[p] <= 0;
                end
            // READ at E0 (rpv[0]); the pad captures the pin at E0+PinCapture and
            // the word is taken here one edge later.
            if (rpv[RP-1]) begin
                if (rpc[RP-1] == 2'(Host)) begin host_rdata <= sd_dq_in; host_done <= 1; end
                else if (!f2)
                    deliver(int'(rpc[RP-1]), sd_dq_in[rpl[RP-1]*8 +: 8], rpa[RP-1] + 4'(RP));
                else begin
                    stage_v[rpc[RP-1]] <= 1;
                    stage_d[rpc[RP-1]] <= sd_dq_in[rpl[RP-1]*8 +: 8];
                    stage_a[rpc[RP-1]] <= rpa[RP-1] + 4'(RP);
                end
            end
            // ---- refresh debt: one every RefreshInterval, paid in safe windows ----
            if (configured) begin
                // Counts RefreshInterval-1..0: one owed every RefreshInterval cycles.
                if (refresh_left != 0) refresh_left <= refresh_left - 1'b1;
                else refresh_left <= $bits(refresh_left)'(RefreshInterval - 1);
                ref_owed <= owed_next;
                if (enable && !idle_clock && forced) refresh_forced <= 1;
            end
            if (master_ce) since_step <= 0;
            else if (since_step != 3'd7) since_step <= since_step + 1'b1;
            if (proc) quiet_edges <= !s_quiet ? 6'd0 :
                                     quiet_edges == 6'h3f ? quiet_edges : quiet_edges + 1'b1;
            // ---- command issue ----
            if (wait_left != 0) wait_left <= wait_left - 1'b1;
            else case (state)
                PowerWait: begin
                    cmd <= Pre; sd_a <= 11'b100_0000_0000; wait_left <= 1;
                    state <= InitRefA;
                end
                InitRefA: begin cmd <= Ref; wait_left <= 4; state <= InitRefB; end
                InitRefB: begin cmd <= Ref; wait_left <= 4; state <= InitMode; end
                InitMode: begin
                    cmd <= Mode; sd_ba <= 0; sd_a <= 11'h020;  // BL1 sequential, CL2
                    wait_left <= 1; state <= Running;
                end
                Running: begin
                    configured <= 1;
                    if (col_bank >= 0) begin
                        sd_ba <= 2'(col_bank);
                        sd_a <= {3'b100, bcol[col_bank]};        // A10: autoprecharge
                        bs[col_bank] <= BRecover;
                        if (bwrite[col_bank]) begin
                            cmd <= Write;
                            sd_dq_oe <= 1;
                            bcnt[col_bank] <= 5;                 // tRDL 2 + tRP 2 (+1)
                            if (bclient[col_bank] == 2'(Host)) host_done <= 1;
                            else physical_write[bclient[col_bank]] <= 1;
                        end else begin
                            cmd <= Read;
                            since_read <= 0;
                            bcnt[col_bank] <= 4;                 // BL1, tRP 2 (+1)
                            rpv[0] <= 1;
                            rpc[0] <= bclient[col_bank];
                            rpl[0] <= blane[col_bank];
                            rpa[0] <= bage[col_bank] + 1'b1;
                        end
                    end else if (act_client >= 0) begin
                        automatic logic [20:0] a = act_write ? wqa[act_client] : rqa[act_client];
                        automatic logic [1:0] b = a[20:19];
                        cmd <= Act;
                        sd_ba <= b; sd_a <= a[18:8];
                        bs[b] <= BActed; bcnt[b] <= 1;           // column at +2
                        bclient[b] <= 2'(act_client);
                        bwrite[b] <= act_write;
                        bcol[b] <= a[7:0];
                        bdata[b] <= wqd[act_client];
                        blane[b] <= rql[act_client];
                        bage[b] <= (act_client < P && fresh_rd[act_client]) ? 4'd1 :
                                   rage[act_client] + 1'b1;
                        if (act_write) wp[act_client] <= 0; else rp[act_client] <= 0;
                    end else if (do_ref) begin
                        cmd <= Ref;
                        ref_wait <= 4;                            // tRFC 63 ns = 5 clk
                    end
                end
                default: state <= PowerWait;
            endcase
        end
    end
endmodule
`default_nettype wire
