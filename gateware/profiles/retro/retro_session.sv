// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype none
// Management in free MD-master domain. Bundled command/config stable through
// mailbox ack. BEGIN/ABORT do not reset a live memory operation.
module retro_session (
    input wire clk,rst,command_valid,
    input wire [159:0] command,
    output logic command_complete=0,
    input wire transport_fault,
    output logic [1:0] selected=0,owner_request=0,
    input wire [1:0] owner,
    input wire owner_busy,
    output logic controllers_reset=1,
    output wire running,loading,ready,payload_done,switching,
    output wire nes_freeze,nes_run,md_run,snes_run,
    input wire md_stopped,snes_stopped,writer_idle,md_memory_idle,
    input wire nes_done,nes_fail,nes_memory_ready,md_memory_ready,snes_memory_ready,
    input wire [1:0] assets_ready,
    output logic [23:0] length=0,rom_size=0,
    output logic [17:0] save_size=0,
    output logic [4:0] map_config=0,
    output logic flush=0,nes_load=0,writer_start=0,writer_abort=0,
    input wire stream_valid,
    output wire stream_ready,
    input wire backend_ready,backend_done,backend_fail,
    output logic [23:0] received=0,
    output logic [7:0] error=0,
    output wire [95:0] status,
    output wire asset_command,
    input wire asset_complete,asset_failed
);
  import retro_regs_pkg::*;
  typedef enum logic [3:0] {Idle,Stop,ResetOld,SelectOwner,Reinit,Flush,StartLoad,
                           Receive,DrainPayload,Loaded,Running,Asset,Reply,WaitRelease} state_t;
  state_t state=Idle;
  logic [15:0] timer=0;
  logic [1:0] action=0; // 0 abort/error,1 BEGIN,2 console restart
  logic [1:0] next_system=0;
  logic [23:0] next_length=0,next_rom=0;
  logic [17:0] next_save=0;
  logic [4:0] next_map=0;
  logic pending_reply=0;
  logic command_seen=0;
  logic stopped_running=0;
  logic [7:0] payload_quiet=0;
  logic image_valid=0;
  // Rejecting a locked asset command must not quiesce/reset a running core.
  // Retain run while replying to misuse; the sticky error remains visible.
  assign running=state==Running;
  assign loading=state==Receive || state==DrainPayload || state==Loaded;
  assign ready=state==Receive && received<length && !transport_fault;
  assign payload_done=state==Loaded;
  assign switching=state==Stop || state==ResetOld || state==SelectOwner || state==Reinit ||
                   state==Flush || state==StartLoad;
  assign nes_freeze=selected==1 && state==Stop;
  // NES clock freezes while old run remains asserted until drain window expires.
  assign nes_run=selected==1 && (state==Running || (state==Stop && stopped_running));
  assign md_run=selected==2 && state==Running;
  assign snes_run=selected==3 && state==Running;
  assign stream_ready=ready && backend_ready;
  assign asset_command=state==Asset;
  wire old_stopped=controllers_reset || (selected==1 ? timer>=64 : selected==2 ?
                    md_stopped && timer>=32 : selected==3 ? snes_stopped && timer>=32 : 1'b1);
  wire [7:0] index=command[7:0];
  wire [31:0] value=command[39:8];
  wire clear_asset=index==RegControl && (value[ClearIplBit] || value[ClearCoeffBit]);
  assign status={44'b0,error,assets_ready,selected,received,9'b0,payload_done,
                 1'b0,switching,ready,error!=0,running,loading};
  always_ff @(posedge clk) begin
    command_complete<=0;flush<=0;nes_load<=0;writer_start<=0;writer_abort<=0;
    if (rst) begin
      state<=Idle;controllers_reset<=1;selected<=0;owner_request<=0;received<=0;
      length<=0;rom_size<=0;save_size<=0;map_config<=0;timer<=0;error<=0;pending_reply<=0;
      command_seen<=0;stopped_running<=0;payload_quiet<=0;image_valid<=0;
    end else begin
      if (!command_valid) command_seen<=0;
      if (timer!=16'hFFFF) timer<=timer+1'b1;
      case (state)
        Idle,Running,Receive,DrainPayload,Loaded: begin
          if (state==Receive && stream_valid && stream_ready) begin
            received<=received+1'b1;
            if (received+1'b1==length) state<=DrainPayload;
          end
          if (state==DrainPayload && backend_done) begin
            if (payload_quiet==127 || selected!=1) begin state<=Loaded;image_valid<=1;end
            else payload_quiet<=payload_quiet+1'b1;
          end else payload_quiet<=0;
          if ((transport_fault || backend_fail) && (state==Running || loading)) begin
            error<=transport_fault ? ErrStream : ErrBackend;action<=0;state<=Stop;
            timer<=0;writer_abort<=1;stopped_running<=state==Running;image_valid<=0;
          end else if (command_valid && !command_seen) begin
            command_seen<=1;
            pending_reply<=1;
            if (index==RegIpl || index==RegCoeff || clear_asset) begin
              if (state!=Idle || owner_busy ||
                  (clear_asset && value[ClearIplBit] && value[ClearCoeffBit])) begin
                error<=ErrAssets;command_complete<=1;pending_reply<=0;
              end
              else state<=Asset;
            end else if (index!=RegControl) begin error<=ErrCommand;state<=Reply;end
            else if (value[ConsoleResetBit] && !value[AbortBit] && !value[BeginBit] &&
                     (state!=Running || selected==0 || controllers_reset || !image_valid)) begin
              error<=ErrCommand;command_complete<=1;pending_reply<=0;
            end
            else if (value[AbortBit] || value[BeginBit] || value[ConsoleResetBit]) begin
              action<=value[BeginBit] ? 1 : value[ConsoleResetBit] ? 2 : 0;
              // Config shadows are sampled ONLY by BEGIN; RESET/ABORT cannot
              // tear the currently running cartridge configuration.
              if (value[BeginBit]) begin
                next_system<=command[67:66];next_length<=command[91:68];
                next_map<=command[96:92];next_rom<=command[120:97];next_save<=command[138:121];
              end
              state<=Stop;timer<=0;writer_abort<=1;
              stopped_running<=state==Running;
              if (value[BeginBit] || value[AbortBit]) image_valid<=0;
              if (value[BeginBit]) error<=0;
              if (value[AbortBit]) error<=0;
            end else if (value[CommitBit]) begin
              if (state==Loaded && error==0 && (!transport_fault) &&
                  (selected!=3 || assets_ready==3)) begin
                state<=Running;command_complete<=1;pending_reply<=0;
              end
              else begin error<=ErrCommit;action<=0;state<=Stop;timer<=0;
                         writer_abort<=1;stopped_running<=state==Running;end
            end else begin error<=ErrCommand;state<=Reply;end
          end
        end
        Stop: if (old_stopped && writer_idle && md_memory_idle) begin
          if (action==2) begin state<=Reinit;timer<=0;end
          else begin controllers_reset<=1;state<=ResetOld;timer<=0;end
        end
        ResetOld: if (timer>=64) begin
          if (action==0) state<=Reply;
          else if (next_system==0 || next_length==0 || next_length>24'd4194320 ||
                   (next_system!=1 && (next_length>24'd4194304 || next_rom!=next_length)) ||
                   (next_system==2 && next_length[0]) ||
                   (next_system==3 && (assets_ready!=3 || next_map[3:1]!=0 || next_save>131072 ||
                    next_rom<32768 || (next_rom & (next_rom-1'b1))!=0 ||
                    (next_save!=0 && (next_save<2048 ||
                                     (next_save & (next_save-1'b1))!=0)))))
            begin error<=ErrConfig;state<=Reply;end
          else begin
            selected<=next_system;owner_request<=next_system;
            length<=next_length;rom_size<=next_rom;save_size<=next_save;map_config<=next_map;
            state<=SelectOwner;error<=0;received<=0;timer<=0;
          end
        end
        SelectOwner: if (!owner_busy && owner==selected && timer>=64) begin
          controllers_reset<=0;state<=Reinit;timer<=0;
        end
        Reinit: if (timer>=32768 && (selected==1 ? nes_memory_ready :
                    selected==2 ? md_memory_ready : snes_memory_ready)) begin
          if (action==2) begin state<=Running;command_complete<=1;pending_reply<=0;end
          else begin flush<=1;state<=Flush;timer<=0;end
        end
        Flush: if (timer>=64) begin
          if (selected==1) nes_load<=1;else writer_start<=1;
          state<=StartLoad;timer<=0;
        end
        StartLoad: if (timer>=64) state<=Reply;
        Asset: if (asset_complete) begin
          if (asset_failed) error<=ErrAssets;
          state<=Reply;
        end
        Reply: begin
          if (pending_reply) command_complete<=1;
          pending_reply<=0;
          if (action==1 && selected!=0 && error==0) state<=WaitRelease;
          else begin state<=Idle;action<=0;end
        end
        WaitRelease: if (!command_valid) begin state<=Receive;action<=0;end
        default: state<=Idle;
      endcase
    end
  end
endmodule
`default_nettype wire
