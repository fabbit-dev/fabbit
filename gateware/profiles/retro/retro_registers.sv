// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
module retro_registers #(
    // Systems present in THIS image: bits 0 NES, 1 MD, 2 SNES.
    parameter logic [2:0] Caps = 3'b111
) (
    input wire clk, rst, csr_we,
    input wire [7:0] csr_waddr, csr_raddr,
    input wire [31:0] csr_wdata,
    output logic [31:0] csr_rdata,
    output logic command_send=0,
    output logic [159:0] command_data=0,
    input wire command_busy,
    input wire [95:0] status,
    input wire [12:0] fifo_level,
    input wire st_valid,
    input wire [7:0] st_chan,
    input wire fifo_ready,
    output wire stream_write,
    output logic transport_fault=0
);
  import retro_regs_pkg::*;
  logic [1:0] system_shadow=0;
  logic [23:0] length_shadow=0, rom_shadow=0;
  logic [17:0] save_shadow=0;
  logic [4:0] map_shadow=0;
  logic command_pending=0;
  logic [23:0] streamed=0,stream_limit=0;
  wire busy=command_busy || command_pending || command_send;
  logic clear_status_wait=0;
  wire ready=status[ReadyBit] && !busy && !transport_fault && !clear_status_wait &&
             streamed<stream_limit;
  assign stream_write=st_valid && st_chan==0 && ready && fifo_ready;
  // Payload layout stable until acknowledged: opcode,addressed value,BEGIN snapshot.
  always_ff @(posedge clk) begin
    command_send<=0;
    if (command_busy) command_pending<=0;
    if (!status[ReadyBit]) clear_status_wait<=0;
    if (st_valid && (st_chan!=0 || !ready || !fifo_ready)) transport_fault<=1;
    if (stream_write) streamed<=streamed+1'b1;
    if (csr_we) case (csr_waddr)
      RegSystem: system_shadow<=csr_wdata[1:0];
      RegLength: length_shadow<=csr_wdata[23:0];
      RegMap: map_shadow<=csr_wdata[4:0];
      RegRomSize: rom_shadow<=csr_wdata[23:0];
      RegSaveSize: save_shadow<=csr_wdata[17:0];
      RegControl,RegIpl,RegCoeff: begin
        if (busy || (csr_waddr==RegControl && csr_wdata[31:16]!=RetroKey))
          transport_fault<=1;
        else begin
          command_data<={21'b0,save_shadow,rom_shadow,map_shadow,length_shadow,
                         system_shadow,26'b0,csr_wdata,csr_waddr};
          command_send<=1;
          command_pending<=1;
          if (csr_waddr==RegControl && csr_wdata[AbortBit]) transport_fault<=0;
          if (csr_waddr==RegControl && csr_wdata[BeginBit]) begin
            streamed<=0;stream_limit<=length_shadow;clear_status_wait<=1;
          end
        end
      end
      default: ;
    endcase
    if (rst) begin
      command_send<=0; command_pending<=0; command_data<=0; transport_fault<=0;
      system_shadow<=0; length_shadow<=0; rom_shadow<=0; save_shadow<=0; map_shadow<=0;
      streamed<=0;stream_limit<=0;clear_status_wait<=0;
    end
  end
  always_comb begin
    csr_rdata=0;
    case (csr_raddr)
      RegId: csr_rdata=RetroMagic;
      RegStatus: begin
        csr_rdata[15:0]=status[15:0];
        csr_rdata[CommandBusyBit]=busy;
        csr_rdata[ErrorBit]=status[ErrorBit] || transport_fault;
        csr_rdata[ReadyBit]=ready;
      end
      RegFree: csr_rdata=ready && fifo_level<4080 ? 32'd4080-32'(fifo_level) : 0;
      RegReceived: csr_rdata={8'b0,status[39:16]};
      RegSystem: csr_rdata={30'b0,status[41:40]};
      RegLength: csr_rdata={8'b0,length_shadow};
      RegMap: csr_rdata={27'b0,map_shadow};
      RegRomSize: csr_rdata={8'b0,rom_shadow};
      RegSaveSize: csr_rdata={14'b0,save_shadow};
      RegAssets: csr_rdata={30'b0,status[43:42]};
      RegError: csr_rdata=transport_fault ? 32'(ErrStream) : {24'b0,status[51:44]};
      RegAbi: csr_rdata=1;
      RegCaps: csr_rdata={29'b0,Caps};
      default: ;
    endcase
  end
endmodule
`default_nettype wire
