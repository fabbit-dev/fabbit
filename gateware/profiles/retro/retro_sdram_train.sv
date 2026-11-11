// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// SDRAM read-window trainer for a pad PHY (retro_sdram_phy). One pass:
//   PRE all, MODE (CL2 BL1), ACT row, WRITE columns 0..Words-1 on consecutive clocks,
//   PRE, ACT, READ columns 0..Words-1 on consecutive clocks, PRE, AUTO REFRESH.
// The mode register is rewritten every pass: at a bad clock phase the chip can take a
// command transition (e.g. ACT 011 -> WRITE 100) as MODE 000 with a garbage address.
// Back-to-back BL1 reads put a new word on DQ every clock, so a capture one clock
// early or late reads a neighbour word and fails. A tester with idle clocks between
// reads cannot see that: the DQ lines keep the last level on their capacitance after
// the chip releases them (measured on the board: capture at READ+4 passes everywhere).
// Words come in pairs g, ~g (g = hash of pair index and pass seed): neighbours differ
// in every bit inside a pair and in about half of the bits across pairs.
// Commands, addresses and write data use the same clock phase as reads, so a pass
// also checks command and write timing. Data loss is fine: run before loading data.
// Timing (ESMT M12L64322A -7 at 15.52 ns): tRCD 2, tRP 2, tRAS 3, tRDL 2, tRFC 5,
// tMRD 2. One REF per pass (~170 clocks) is far above 4096 per 64 ms.
// Read latency: a READ registered at edge E is captured in the pad at E+PinCapture
// and seen on dq_in at E+PinCapture+1 (as snes_memory).
module retro_sdram_train #(
    parameter int unsigned Words = 64,           // columns per pass, power of two <= 256
    parameter int unsigned PinCapture = 3,
    parameter int unsigned InitCycles = 13000,   // >= 200 us; 0: the chip is already set up
    // Every address and bank pin toggles during a pass (row 0x555, columns up to 0xFF,
    // bank 3), so no output register is a constant and all stay in the IOB.
    parameter logic [1:0] Bank = 2'd3,
    parameter logic [10:0] Row = 11'h555
) (
    input wire clk, reset,
    input wire run,                       // passes repeat while high, stop after a pass
    output logic idle,                    // initialized and no pass in progress
    output logic pass_done,               // one-clock strobe at the end of each pass
    output logic pass_ok,                 // valid with pass_done
    output logic [10:0] sd_a = '0,
    output logic [1:0] sd_ba = '0,
    output wire sd_ras_n, sd_cas_n, sd_we_n,
    output wire [31:0] sd_dq_out,         // sampled by the pad ODDR at the WRITE edge
    output wire sd_dq_oe_next,
    input wire [31:0] sd_dq_in
);
    localparam int CW = $clog2(Words);
    localparam logic [2:0] Nop = 3'b111, Act = 3'b011, Read = 3'b101, Write = 3'b100;
    localparam logic [2:0] Pre = 3'b010, Ref = 3'b001, Mode = 3'b000;
    initial assert (Words >= 4 && Words <= 256 && (Words & (Words - 1)) == 0)
        else $fatal(1, "Words must be a power of two in 4..256");

    typedef enum logic [3:0] {Power, InitRef, InitMode, Ready, WMode, WAct, WData,
                              WPre, RAct, RData, RDrain, RPre, Refresh} state_t;
    state_t state = Power;
    logic [$clog2(InitCycles + 2)-1:0] wait_left = '0;
    logic [CW:0] col = '0;
    logic [1:0] init_refs = '0;
    logic [15:0] seed = '0;
    logic [2:0] cmd = Nop;
    logic bad = 1'b0;

    function automatic logic [31:0] word(input logic [CW-1:0] c, input logic [15:0] s);
        logic [31:0] h;
        h = ({24'd0, 8'(c >> 1)} ^ {s, s}) * 32'h9E37_79B1;
        h = h ^ (h >> 15) ^ {s[7:0], 8'(c >> 1), s};
        return c[0] ? ~h : h;
    endfunction

    // Command registered at this edge; write data goes to the pad ODDR with it.
    wire writing = state == WData && wait_left == 0;
    assign sd_dq_oe_next = writing && !reset;
    assign sd_dq_out = writing ? word(col[CW-1:0], seed) : 32'h0;
    assign {sd_ras_n, sd_cas_n, sd_we_n} = cmd;

    // Read return: column of each READ, delayed to the clock where its word is on dq_in.
    localparam int L = PinCapture + 1;
    logic [L-1:0] rv = '0;
    logic [CW-1:0] rc [L];
    always_ff @(posedge clk) begin
        rv <= {rv[L-2:0], state == RData && wait_left == 0 && !col[CW]};
        rc[0] <= col[CW-1:0];
        for (int i = 1; i < L; i++) rc[i] <= rc[i-1];
    end
    wire check = rv[L-1];
    wire mismatch = check && sd_dq_in != word(rc[L-1], seed);

    always_ff @(posedge clk) begin
        cmd <= Nop;
        pass_done <= 1'b0;
        if (mismatch) bad <= 1'b1;
        if (reset) begin
            state <= InitCycles == 0 ? Ready : Power;
            wait_left <= $bits(wait_left)'(InitCycles);
            idle <= 1'b0;
            bad <= 1'b0;
            seed <= '0;
        end else if (wait_left != 0) wait_left <= wait_left - 1'b1;
        else case (state)
            Power: begin
                cmd <= Pre; sd_a <= 11'h400; sd_ba <= 0;        // A10: all banks
                wait_left <= 1; state <= InitRef; init_refs <= 0;
            end
            InitRef: begin
                cmd <= Ref; wait_left <= 4;
                init_refs <= init_refs + 1'b1;
                if (init_refs == 1) state <= InitMode;
            end
            InitMode: begin
                cmd <= Mode; sd_ba <= 0; sd_a <= 11'h020;       // CL2, BL1
                wait_left <= 1; state <= Ready;
            end
            Ready: begin
                idle <= !run;
                if (run) begin
                    idle <= 1'b0; bad <= 1'b0;
                    cmd <= Pre; sd_a <= 11'h400; wait_left <= 1; state <= WMode;
                end
            end
            WMode: begin
                cmd <= Mode; sd_ba <= 0; sd_a <= 11'h020; wait_left <= 1; state <= WAct;
            end
            WAct: begin
                cmd <= Act; sd_ba <= Bank; sd_a <= Row;
                wait_left <= 1; col <= 0; state <= WData;
            end
            WData: begin
                cmd <= Write; sd_ba <= Bank;
                sd_a <= {3'b000, 8'(col[CW-1:0])};              // A10 low: row stays open
                // A8/A9 are don't-care for an 8-bit column: drive them so they toggle.
                sd_a[9:8] <= col[1:0];
                col <= col + 1'b1;
                if (col == (CW+1)'(Words - 1)) begin wait_left <= 2; state <= WPre; end
            end
            WPre: begin                                          // after tRDL 2
                cmd <= Pre; sd_a <= 11'h400; wait_left <= 1; state <= RAct;
            end
            RAct: begin
                cmd <= Act; sd_ba <= Bank; sd_a <= Row;
                wait_left <= 1; col <= 0; state <= RData;
            end
            RData: begin
                cmd <= Read; sd_ba <= Bank;
                sd_a <= {3'b000, 8'(col[CW-1:0])};
                sd_a[9:8] <= ~col[1:0];
                col <= col + 1'b1;
                if (col == (CW+1)'(Words - 1)) begin wait_left <= 3; state <= RPre; end
            end
            RPre: begin                                          // last data out (CL2)
                cmd <= Pre; sd_a <= 11'h400; wait_left <= 1; state <= Refresh;
            end
            Refresh: begin
                cmd <= Ref; wait_left <= 4; state <= RDrain;     // tRFC 5
            end
            RDrain: if (rv == 0 && !check) begin                 // every word compared
                pass_done <= 1'b1;
                pass_ok <= !bad && !mismatch;
                seed <= seed + 1'b1;
                state <= Ready;
            end
            default: state <= Power;
        endcase
    end
endmodule
`default_nettype wire
