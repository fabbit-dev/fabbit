// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Synchronous stream -> snes_console asset programming pins, no firmware data.
// start with run=0 and channel 0 IPL (64 bytes) or 1 Gaussian (1024 bytes).
// Byte address must be exactly sequential from zero; last ONLY on final byte.
// Gaussian wire encoding little-endian unsigned container for signed 12-bit:
// first byte bits7:0, second byte bits11:8, high nibble MUST be zero.
// start clears that asset's coverage. done waits until the last REGISTERED
// backend write is applied and corresponding backend_ready is actually true.
// Error aborts and clears selected asset; never starts the console itself.
// A stopped START is an explicit restart: abandon an incomplete upload, clear
// only the newly selected coverage, and reset address/error state. This permits
// retry after host ABORT without global reset or losing the other completed asset.
module snes_asset_loader (
    input wire clk, reset, run,
    input wire start,
    input wire [1:0] channel,
    input wire byte_valid,
    output wire byte_ready,
    input wire [10:0] byte_addr,
    input wire [7:0] byte_data,
    input wire byte_last,
    input wire backend_ipl_ready, backend_coeff_ready,
    output wire busy,
    output logic done,
    output logic [2:0] error,
    output logic ipl_clear, ipl_we,
    output logic [5:0] ipl_addr,
    output logic [7:0] ipl_data,
    output logic coeff_clear, coeff_we,
    output logic [8:0] coeff_addr,
    output logic [11:0] coeff_data
);
    typedef enum logic [1:0] {Idle, Clear, Receive, Commit} state_t;
    state_t state;
    logic selected;
    logic [10:0] next_addr;
    logic [7:0] low_byte;
    logic [1:0] commit_wait;
    logic invalidate_pending;
    wire final_byte = next_addr == (selected ? 11'd1023 : 11'd63);
    assign byte_ready = state == Receive && !run && !reset && !start;
    assign busy = state != Idle || invalidate_pending;
    always_ff @(posedge clk) begin
        done <= 0;
        ipl_clear <= 0;
        coeff_clear <= 0;
        ipl_we <= 0;
        coeff_we <= 0;
        if (reset) begin
            state <= Idle;
            selected <= 0;
            next_addr <= 0;
            low_byte <= 0;
            commit_wait <= 0;
            error <= 0;
            invalidate_pending <= 0;
            ipl_clear <= 1;
            coeff_clear <= 1;
            ipl_addr <= 0;
            ipl_data <= 0;
            coeff_addr <= 0;
            coeff_data <= 0;
        end else if (invalidate_pending && !run) begin
            // Backend ignores programming while run=1; defer invalidation.
            ipl_clear <= 1;
            coeff_clear <= 1;
            invalidate_pending <= 0;
            state <= Clear;
        end else if (start) begin
            if (run || channel > 1) begin
                error <= 1;  // unsafe start/channel
                state <= Idle;
                // Caller must stop on error; deferred clear executes on stop.
                ipl_clear <= 1;
                coeff_clear <= 1;
                invalidate_pending <= run;
            end else begin
                selected <= channel[0];
                ipl_clear <= !channel[0];
                coeff_clear <= channel[0];
                next_addr <= 0;
                low_byte <= 0;
                commit_wait <= 0;
                error <= 0;
                invalidate_pending <= 0;
                state <= Clear;
            end
        end else if (state != Idle && run) begin
            error <= 2;
            state <= Idle;
            ipl_clear <= !selected;
            coeff_clear <= selected;
            invalidate_pending <= 1;
        end else case (state)
            Idle: ;
            Clear: state <= error != 0 ? Idle : Receive;
            Receive: if (byte_valid && byte_ready) begin
                if (byte_addr != next_addr || byte_last != final_byte ||
                    (selected && next_addr[0] && byte_data[7:4] != 0)) begin
                    error <= byte_addr != next_addr ? 3 :
                             byte_last != final_byte ? 4 : 5;
                    ipl_clear <= !selected;
                    coeff_clear <= selected;
                    state <= Idle;
                end else begin
                    next_addr <= next_addr + 1;
                    if (!selected) begin
                        ipl_we <= 1;
                        ipl_addr <= next_addr[5:0];
                        ipl_data <= byte_data;
                    end else if (!next_addr[0]) low_byte <= byte_data;
                    else begin
                        coeff_we <= 1;
                        coeff_addr <= next_addr[9:1];
                        coeff_data <= {byte_data[3:0],low_byte};
                    end
                    if (final_byte) begin
                        state <= Commit;
                        commit_wait <= 0;
                    end
                end
            end
            Commit: begin
                // First edge applies final backend write. Observe ready one
                // edge later; old ready from a prior image cannot finish us.
                commit_wait <= commit_wait + 1;
                if (commit_wait != 0 &&
                    (selected ? backend_coeff_ready : backend_ipl_ready)) begin
                    done <= 1;
                    state <= Idle;
                end else if (commit_wait == 3) begin
                    error <= 6;  // backend did not cover the complete image
                    ipl_clear <= !selected;
                    coeff_clear <= selected;
                    state <= Idle;
                end
            end
            default: state <= Idle;
        endcase
    end
endmodule
`default_nettype wire
