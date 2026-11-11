// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// SDRAM clock-phase calibration with retro_sdram_train and the MMCM fine phase shift.
// Sweeps one full period in Step-sized moves. At each point it discards one trainer pass
// (the phase just moved) and needs Passes clean passes. Then it takes the longest
// circular run of clean points, moves the clock to its middle and reports:
//   width:  run length in phase steps (window lower bound: the run spans width-Step
//           between its first and last clean point, the true edges lie within Step),
//   center: signed offset of the chosen phase from the start phase, in steps,
//   fail:   width below MinSteps (or no clean point); the phase still moves to the
//           best run so a degraded board keeps working as well as it can.
// After a full turn the clock is back at the start phase, so offsets are exact.
// ps_* follow MMCME2 fine phase shift: one ps_en pulse per step, wait ps_done.
module retro_sdram_calibrate #(
    parameter int unsigned Period = 672,         // fine steps per memory clock period
    parameter int unsigned Step = 8,             // steps between measured points
    parameter int unsigned Passes = 4,           // clean passes needed per point
    parameter int unsigned MinSteps = 216        // 5 ns at 23.09 ps per step
) (
    input wire clk, reset,
    output logic train_run = 1'b0,
    input wire train_idle, train_done, train_ok,
    output logic ps_en = 1'b0,
    output wire ps_incdec,
    input wire ps_done,
    output logic done = 1'b0,
    output logic fail = 1'b0,
    output logic [$clog2(Period+1)-1:0] width = '0,
    output logic signed [$clog2(Period)+1:0] center = '0
);
    localparam int N = Period / Step;
    localparam int IW = $clog2(2 * N + 1);
    localparam int SW = $clog2(Period + 1);
    initial assert (N * Step == Period && N >= 4) else $fatal(1, "Step must divide Period");

    typedef enum logic [2:0] {Wait, Measure, Settle, Shift, Scan, Center, Done} state_t;
    state_t state = Wait;
    logic [N-1:0] ok = '0;
    logic [IW-1:0] point = '0, scan = '0;
    logic [SW-1:0] steps_left = '0;
    logic [$clog2(Passes+2)-1:0] seen = '0, clean = '0;
    logic shifting = 1'b0;
    logic [IW-1:0] run = '0, best = '0, best_end = '0;
    assign ps_incdec = 1'b1;                     // forward only: a full turn returns home

    always_ff @(posedge clk) begin
        ps_en <= 1'b0;
        if (reset) begin
            state <= Wait; train_run <= 1'b0; done <= 1'b0; fail <= 1'b0;
            point <= '0; shifting <= 1'b0; ok <= '0;
        end else case (state)
            Wait: if (train_idle) begin
                train_run <= 1'b1; seen <= '0; clean <= '0; state <= Measure;
            end
            Measure: if (train_done) begin
                // first pass after a move is discarded
                if (seen != 0 && train_ok) clean <= clean + 1'b1;
                seen <= seen + 1'b1;
                if (seen == ($bits(seen))'(Passes)) begin
                    train_run <= 1'b0;
                    state <= Settle;
                end
            end
            Settle: if (train_idle) begin            // trainer stopped after its pass
                ok[point] <= clean == ($bits(clean))'(Passes);
                steps_left <= SW'(Step);
                state <= Shift;
            end
            Shift: begin
                if (!shifting && steps_left != 0) begin ps_en <= 1'b1; shifting <= 1'b1; end
                if (shifting && ps_done) begin
                    shifting <= 1'b0; steps_left <= steps_left - 1'b1;
                end
                if (!shifting && steps_left == 0) begin
                    if (point == IW'(N - 1)) begin
                        point <= '0; scan <= '0; run <= '0; best <= '0; best_end <= '0;
                        state <= Scan;
                    end else begin
                        point <= point + 1'b1;
                        train_run <= 1'b1; seen <= '0; clean <= '0; state <= Measure;
                    end
                end
            end
            // Longest circular run: walk 2N points, a run never counts past N.
            Scan: begin
                automatic logic [IW-1:0] r = ok[scan >= IW'(N) ? scan - IW'(N) : scan] ?
                                             (run == IW'(N) ? run : run + 1'b1) : '0;
                run <= r;
                if (r > best) begin best <= r; best_end <= scan; end
                if (scan == IW'(2 * N - 1)) state <= Center;
                else scan <= scan + 1'b1;
            end
            Center: begin
                // middle point of the run, then move there from the start phase
                automatic int unsigned mid =
                    (int'(best_end) - int'(best) / 2 + 2 * N) % N;
                width <= SW'(int'(best) * Step);
                fail <= best == 0 || int'(best) * Step < MinSteps;
                center <= mid * Step <= Period / 2 ? ($bits(center))'(mid * Step) :
                          ($bits(center))'(int'(mid * Step) - int'(Period));
                steps_left <= SW'(mid * Step);
                state <= Done;
            end
            Done: begin
                if (!shifting && steps_left != 0) begin ps_en <= 1'b1; shifting <= 1'b1; end
                if (shifting && ps_done) begin
                    shifting <= 1'b0; steps_left <= steps_left - 1'b1;
                end
                if (!shifting && steps_left == 0) done <= 1'b1;
            end
            default: state <= Wait;
        endcase
    end
endmodule
`default_nettype wire
