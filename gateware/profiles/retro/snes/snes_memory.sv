// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Independent SNES SDR controller, no upstream controller/vendor IP.
// clk = 4 * SNES master (nominal 85.90908 MHz). master_ce is asserted on
// the service edge coincident with each master edge. Inputs from the console
// settle after that edge and are sampled on the NEXT service edge (+1).
// Related clocks only; this interface is NOT an asynchronous CDC bridge.
// Commands are registered; external sd_clk must sample them AFTER clk.
// The test uses +2 ns sd_clk, TAc=5.4 ns, TOh=2.5 ns. NOT board signoff.
//
// Physical words {bank[1:0],row[10:0],column[7:0]}, DQM permanently zero:
// ROM 4 MiB packed: banks 0/1, word = rom_byte_addr >> 2.
// WRAM 128 KiB: bank 2, words 0..131071, byte replicated to all lanes.
// Save 128 KiB: bank 2, words 131072..262143 (row 512 onwards).
// ARAM 64 KiB: bank 3, words 0..65535. Read writable bytes from lane zero.
// No aliases, no byte-mask/RMW dependence. Host addresses physical x32 words.
//
// Core strobes are levels; detect assertion/address/direction/data changes.
// One outstanding operation per client. Writes are POSTED into its one-entry
// buffer, and same-address reads forward from that buffer until committed.
// Overrun/invalid simultaneous read+write sets explicit fault, never silent loss.
// *_valid means an ACTUAL fresh read/forward, not held old *_q. *_committed is
// the physical write completion. *_posted marks architectural write acceptance.
// Reads missing the second master edge set deadline_fault (sticky per port):
// bits 0 WRAM,1 ARAM,2 ROM,3 save. No fake completion on a deadline miss.
// Auto refresh can make this bound IMPOSSIBLE for arbitrary arrivals: tRFC6 +
// tRCD2 + CL2 > 8 fast clocks. Consumers MUST handle fault/reset; a direct
// nonstallable SNES hookup is not safe until a refresh-safe schedule is proved.
// snes_system instead gates the WHOLE console master with snes_clock_guard;
// this keeps architectural consumers stopped until core_hold deasserts.
module snes_memory #(
    parameter int unsigned InitCycles = 18000,
    parameter int unsigned RefreshCycles = 480,
    parameter int unsigned Trcd = 2,
    parameter int unsigned Trp = 2,
    parameter int unsigned Trfc = 6,
    parameter int unsigned Tras = 4,
    parameter int unsigned Trrd = 2,
    parameter int unsigned Twr = 2,
    parameter int unsigned Twtr = 2,
    parameter int unsigned Trtp = 2
) (
    input wire clk, reset, master_ce, enable,
    input wire refresh_now,
    output wire initialized,
    output wire drained,
    // Whole-master clock guard contract: requests originate only on actual
    // core edges and are sampled one fast edge later. Hold every later core
    // edge until core_hold clears; service clock/refresh MUST keep running.
    // No backpressure by driving SNES.ENABLE low (that is not a pause).
    output wire core_hold,
    output wire [4:0] request_inflight,
    output wire [3:0] needs_data,
    output wire refresh_busy,
    output logic [3:0] deadline_fault,
    output logic [3:0] overrun_fault,
    output logic protocol_fault,
    input wire [16:0] wram_addr,
    input wire [7:0] wram_data,
    input wire wram_rd, wram_wr,
    output logic [7:0] wram_q,
    output wire wram_valid, wram_posted, wram_committed,
    input wire [15:0] aram_addr,
    input wire [7:0] aram_data,
    input wire aram_rd, aram_wr,
    output logic [7:0] aram_q,
    output wire aram_valid, aram_posted, aram_committed,
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
    output logic [10:0] sd_a,
    output logic [1:0] sd_ba,
    output wire sd_ras_n, sd_cas_n, sd_we_n,
    output wire sd_cs_n, sd_cke,
    input wire [31:0] sd_dq_in,
    output logic [31:0] sd_dq_out,
    output wire sd_dq_oe
);
    localparam int Clients = 5;
    localparam logic [2:0] Nop = 3'b111, Act = 3'b011, Read = 3'b101;
    localparam logic [2:0] Write = 3'b100, Pre = 3'b010, Ref = 3'b001, Mode = 3'b000;
    typedef enum logic [2:0] {PowerWait, InitRefA, InitRefB, InitMode,
                            InitDone, Running, RefreshWait} state_t;
    typedef enum logic [1:0] {BankIdle, BankColumn, BankPre, BankRecover} bank_t;
    state_t state;
    bank_t bank_state [4];
    logic [2:0] owner [4];
    int unsigned bank_wait [4], ras_wait [4], rr_wait, write_bus_wait, read_bus_wait;
    int unsigned wait_left, refresh_left;
    logic sample_ce, configured, ref_pending;
    logic [2:0] cmd;
    logic dq_enable;
    logic [Clients-1:0] pending, queued_write, pending_next, write_next;
    logic [20:0] address [Clients], address_next [Clients];
    logic [31:0] data [Clients], data_next [Clients];
    logic [1:0] lane [Clients], lane_next [Clients];
    logic [3:0] rd_old, wr_old;
    logic [20:0] old_addr [4];
    logic [7:0] old_data [4];
    logic [3:0] rd_in, wr_in;
    logic [20:0] addr_in [4];
    logic [7:0] data_in [4];
    logic [1:0] lane_in [4];
    logic [3:0] fresh, forwarded, valid_read;
    logic [2:0] posted, physical_write;
    logic [3:0] new_overrun, new_protocol;
    int unsigned deadline_left [4];
    logic [1:0] read_pipe;
    logic [2:0] read_owner [2];
    logic [1:0] read_lane [2];
    logic write_pipe;
    logic [2:0] write_owner;
    int selected;
    logic [1:0] selected_bank;
    logic [2:0] selected_cmd;
    logic all_closed;

    assign {sd_ras_n, sd_cas_n, sd_we_n} = reset ? Nop : cmd;
    assign sd_cs_n = reset;
    assign sd_cke = 1'b1;
    assign sd_dq_oe = dq_enable && !reset;
    assign initialized = configured && !reset;
    assign request_inflight = pending;
    assign needs_data = pending[3:0] & ~queued_write[3:0];
    assign core_hold = (|pending) || (|read_pipe) || write_pipe;
    assign drained = initialized && all_closed && pending == 0 && read_pipe == 0 &&
                     !write_pipe && state == Running && !ref_pending;
    assign refresh_busy = ref_pending || state == RefreshWait;
    assign host_ready = initialized && !enable && !pending[4];
    assign {save_valid, rom_valid, aram_valid, wram_valid} = valid_read;
    assign {save_posted, aram_posted, wram_posted} = posted;
    assign {save_committed, aram_committed, wram_committed} = physical_write;

    always_comb begin
        rd_in = {save_rd, rom_rd, aram_rd, wram_rd};
        wr_in = {save_wr, 1'b0, aram_wr, wram_wr};
        addr_in[0] = {2'b10, 2'b00, wram_addr};
        addr_in[1] = {2'b11, 3'b000, aram_addr};
        addr_in[2] = {1'b0, rom_addr[21:2]};
        addr_in[3] = {2'b10, 2'b01, save_addr};
        data_in[0] = wram_data;
        data_in[1] = aram_data;
        data_in[2] = 8'h00;
        data_in[3] = save_data;
        lane_in[0] = 0;
        lane_in[1] = 0;
        lane_in[2] = rom_addr[1:0];
        lane_in[3] = 0;
        pending_next = pending;
        write_next = queued_write;
        address_next = address;
        data_next = data;
        lane_next = lane;
        fresh = 0;
        forwarded = 0;
        new_overrun = 0;
        new_protocol = 0;
        if (sample_ce && enable && initialized) begin
            for (int p = 0; p < 4; p++) begin
                if ((rd_in[p] && (!rd_old[p] || addr_in[p] != old_addr[p] ||
                                  lane_in[p] != lane[p])) ||
                    (wr_in[p] && (!wr_old[p] || addr_in[p] != old_addr[p] ||
                                  data_in[p] != old_data[p]))) begin
                    if (rd_in[p] && wr_in[p]) new_protocol[p] = 1;
                    else if (pending[p]) begin
                        if (rd_in[p] && queued_write[p] && addr_in[p] == address[p])
                            forwarded[p] = 1;
                        else new_overrun[p] = 1;
                    end else begin
                        fresh[p] = 1;
                        pending_next[p] = 1;
                        write_next[p] = wr_in[p];
                        address_next[p] = addr_in[p];
                        data_next[p] = {4{data_in[p]}};
                        lane_next[p] = lane_in[p];
                    end
                end
            end
        end
        if (host_valid && host_ready) begin
            pending_next[4] = 1;
            write_next[4] = host_write;
            address_next[4] = host_addr;
            data_next[4] = host_wdata;
            lane_next[4] = 0;
        end

        // Two simultaneous read ACTs must precede their columns: ACT at +1,+3,
        // READ at +4,+5, capture at +6,+7, before master edge +8.
        // Writes are posted, so physical write work has lower priority.
        selected = -1;
        selected_bank = 0;
        selected_cmd = Nop;
        all_closed = 1;
        for (int b = 0; b < 4; b++)
            if (bank_state[b] != BankIdle) all_closed = 0;
        if (state == Running) begin
            if (!ref_pending && rr_wait == 0) begin
                for (int p = Clients-1; p >= 0; p--) begin
                    if (pending_next[p] && !write_next[p] &&
                        bank_state[address_next[p][20:19]] == BankIdle) begin
                        selected = p;
                        selected_bank = address_next[p][20:19];
                        selected_cmd = Act;
                    end
                end
            end
            if (selected < 0) begin
                for (int b = 3; b >= 0; b--) begin
                    if (bank_state[b] == BankColumn && bank_wait[b] == 0 && read_bus_wait == 0 &&
                        !queued_write[owner[b]]) begin
                        selected = int'(owner[b]);
                        selected_bank = 2'(b);
                        selected_cmd = Read;
                    end
                end
            end
            if (selected < 0 && !ref_pending && rr_wait == 0) begin
                for (int p = Clients-1; p >= 0; p--) begin
                    if (pending_next[p] && write_next[p] &&
                        bank_state[address_next[p][20:19]] == BankIdle) begin
                        selected = p;
                        selected_bank = address_next[p][20:19];
                        selected_cmd = Act;
                    end
                end
            end
            if (selected < 0 && write_bus_wait == 0) begin
                for (int b = 3; b >= 0; b--) begin
                    if (bank_state[b] == BankColumn && bank_wait[b] == 0 &&
                        queued_write[owner[b]]) begin
                        selected = int'(owner[b]);
                        selected_bank = 2'(b);
                        selected_cmd = Write;
                    end
                end
            end
            if (selected < 0) begin
                for (int b = 3; b >= 0; b--) begin
                    if (bank_state[b] == BankPre && bank_wait[b] == 0 && ras_wait[b] == 0) begin
                        selected = int'(owner[b]);
                        selected_bank = 2'(b);
                        selected_cmd = Pre;
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        cmd <= Nop;
        dq_enable <= 0;
        valid_read <= 0;
        posted <= 0;
        physical_write <= 0;
        host_done <= 0;
        sample_ce <= master_ce;
        read_pipe <= {read_pipe[0], 1'b0};
        read_owner[1] <= read_owner[0];
        read_lane[1] <= read_lane[0];
        write_pipe <= 0;
        if (reset) begin
            state <= PowerWait;
            wait_left <= InitCycles;
            refresh_left <= RefreshCycles;
            configured <= 0;
            ref_pending <= 0;
            sample_ce <= 0;
            pending <= 0;
            queued_write <= 0;
            rd_old <= 0;
            wr_old <= 0;
            deadline_fault <= 0;
            overrun_fault <= 0;
            protocol_fault <= 0;
            read_pipe <= 0;
            write_pipe <= 0;
            rr_wait <= 0;
            write_bus_wait <= 0;
            read_bus_wait <= 0;
            sd_a <= 0;
            sd_ba <= 0;
            sd_dq_out <= 0;
            wram_q <= 0;
            aram_q <= 0;
            rom_q <= 0;
            save_q <= 0;
            host_rdata <= 0;
            for (int b = 0; b < 4; b++) begin
                bank_state[b] <= BankIdle;
                bank_wait[b] <= 0;
                ras_wait[b] <= 0;
                old_addr[b] <= 0;
                old_data[b] <= 0;
                deadline_left[b] <= 0;
            end
        end else begin
            pending <= pending_next;
            queued_write <= write_next;
            address <= address_next;
            data <= data_next;
            lane <= lane_next;
            if (rr_wait != 0) rr_wait <= rr_wait - 1;
            if (write_bus_wait != 0) write_bus_wait <= write_bus_wait - 1;
            if (read_bus_wait != 0) read_bus_wait <= read_bus_wait - 1;
            for (int b = 0; b < 4; b++) begin
                if (bank_wait[b] != 0) bank_wait[b] <= bank_wait[b] - 1;
                if (ras_wait[b] != 0) ras_wait[b] <= ras_wait[b] - 1;
                if (bank_state[b] == BankRecover && bank_wait[b] == 0)
                    bank_state[b] <= BankIdle;
                if (fresh[b]) begin
                    deadline_left[b] <= 6;
                    if (wr_in[b]) begin
                        if (b == 3) posted[2] <= 1;
                        else if (b < 2) posted[b] <= 1;
                    end
                end else if (pending[b] && !queued_write[b]) begin
                    if (deadline_left[b] == 0) deadline_fault[b] <= 1;
                    else deadline_left[b] <= deadline_left[b] - 1;
                end
            end
            if (sample_ce) begin
                rd_old <= enable ? rd_in : 4'h0;
                wr_old <= enable ? wr_in : 4'h0;
                old_addr <= addr_in;
                old_data <= data_in;
            end
            overrun_fault <= overrun_fault | new_overrun;
            if (|new_protocol) protocol_fault <= 1;
            for (int p = 0; p < 4; p++) begin
                if (forwarded[p]) begin
                    valid_read[p] <= 1;
                    case (p)
                        0: wram_q <= data[p][7:0];
                        1: aram_q <= data[p][7:0];
                        2: rom_q <= data[p][7:0];
                        3: save_q <= data[p][7:0];
                        default: ;
                    endcase
                end
            end
            if (read_pipe[1]) begin
                pending[read_owner[1]] <= 0;
                case (read_owner[1])
                    0: begin wram_q <= sd_dq_in[7:0]; valid_read[0] <= 1; end
                    1: begin aram_q <= sd_dq_in[7:0]; valid_read[1] <= 1; end
                    2: begin
                        rom_q <= sd_dq_in[read_lane[1]*8 +: 8];
                        valid_read[2] <= 1;
                    end
                    3: begin save_q <= sd_dq_in[7:0]; valid_read[3] <= 1; end
                    4: begin host_rdata <= sd_dq_in; host_done <= 1; end
                    default: ;
                endcase
            end
            if (write_pipe) begin
                if (write_owner == 4) host_done <= 1;
                else if (write_owner == 3) physical_write[2] <= 1;
                else if (write_owner < 2) physical_write[write_owner[1:0]] <= 1;
            end
            if (configured) begin
                if (refresh_left != 0) refresh_left <= refresh_left - 1;
                if (refresh_left == 0 || refresh_now) ref_pending <= 1;
            end
            if (wait_left != 0) wait_left <= wait_left - 1;
            else case (state)
                PowerWait: begin
                    cmd <= Pre;
                    sd_a <= 11'b10000000000;
                    wait_left <= Trp - 1;
                    state <= InitRefA;
                end
                InitRefA: begin cmd <= Ref; wait_left <= Trfc-1; state <= InitRefB; end
                InitRefB: begin cmd <= Ref; wait_left <= Trfc-1; state <= InitMode; end
                InitMode: begin
                    cmd <= Mode;
                    sd_ba <= 0;
                    sd_a <= 11'h020;  // BL1 sequential, CL2
                    wait_left <= 1;
                    state <= InitDone;
                end
                InitDone: begin configured <= 1; state <= Running; end
                Running: begin
                    if (ref_pending && all_closed && read_pipe == 0 && !write_pipe) begin
                        cmd <= Ref;
                        ref_pending <= 0;
                        refresh_left <= RefreshCycles;
                        wait_left <= Trfc-1;
                        state <= RefreshWait;
                    end else if (selected >= 0) begin
                        cmd <= selected_cmd;
                        sd_ba <= 2'(selected_bank);
                        case (selected_cmd)
                            Act: begin
                                sd_a <= address_next[selected][18:8];
                                owner[selected_bank] <= 3'(selected);
                                bank_state[selected_bank] <= BankColumn;
                                bank_wait[selected_bank] <= Trcd-1;
                                ras_wait[selected_bank] <= Tras-1;
                                rr_wait <= Trrd-1;
                            end
                            Read, Write: begin
                                sd_a <= {3'b000, address[selected][7:0]};
                                bank_state[selected_bank] <= BankPre;
                                bank_wait[selected_bank] <= selected_cmd == Write ? Twr-1 : Trtp-1;
                                if (selected_cmd == Write) begin
                                    sd_dq_out <= data[selected];
                                    dq_enable <= 1;
                                    write_pipe <= 1;
                                    write_owner <= 3'(selected);
                                    pending[selected] <= 0;
                                    read_bus_wait <= Twtr-1;
                                end else begin
                                    read_pipe[0] <= 1;
                                    read_owner[0] <= 3'(selected);
                                    read_lane[0] <= lane[selected];
                                    write_bus_wait <= 2;
                                end
                            end
                            Pre: begin
                                sd_a <= 0;
                                bank_state[selected_bank] <= BankRecover;
                                bank_wait[selected_bank] <= Trp-1;
                            end
                            default: ;
                        endcase
                    end
                end
                RefreshWait: state <= Running;
                default: state <= PowerWait;
            endcase
        end
    end
endmodule
`default_nettype wire
