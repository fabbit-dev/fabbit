// SPDX-License-Identifier: GPL-3.0-or-later
`default_nettype wire
package retro_regs_pkg;
  // FBP ProfileId=4, one static image. CSR numbers are word indices.
  localparam logic [31:0] RetroMagic = 32'h46524554;  // FRET
  localparam logic [15:0] RetroKey = 16'h5254;        // RT in CSR1[31:16]
  localparam logic [7:0] RegId=0, RegControl=1, RegStatus=2, RegFree=3, RegReceived=4;
  localparam logic [7:0] RegSystem=5, RegLength=6, RegMap=7, RegRomSize=8, RegSaveSize=9;
  localparam logic [7:0] RegAssets=10, RegError=11, RegIpl=12, RegCoeff=13;
  localparam logic [7:0] RegAbi=15, RegCaps=16;
  localparam int BeginBit=0, CommitBit=1, AbortBit=2, ConsoleResetBit=3;
  localparam int ClearIplBit=8, ClearCoeffBit=9;
  localparam int LoadingBit=0, RunningBit=1, ErrorBit=2, ReadyBit=3;
  localparam int SwitchingBit=4, CommandBusyBit=5, PayloadDoneBit=6;
  // RegError low byte, zero means no error. RegCaps bits 0 NES,1 MD,2 SNES.
  localparam logic [7:0] ErrNone=0, ErrCommand=1, ErrConfig=2, ErrStream=3;
  localparam logic [7:0] ErrLength=4, ErrBackend=5, ErrAssets=6, ErrCommit=7;
  // Config writes modify shadows. BEGIN snapshots CSR5..9 atomically. CSR5 reads
  // ACTIVE system (0 before first BEGIN), not the editable system shadow.
  // CSR7 bit0 HiROM, bit4 FastROM metadata (not cartridge chip type).
  // CSR8 canonical ROM bytes; CSR6 whole iNES length for NES, raw bytes MD/SNES.
  // CSR12 IPL atom: [13:8] address, [7:0] byte; CSR13 coefficient atom:
  // [20:12] address, [11:0] signed-container coefficient. CLEAR opens a sequential
  // programming session. Command/atom writes while CMD_BUSY fail closed.
  // CLEAR_IPL -> 64 IPL atoms, then CLEAR_COEFF -> 512 coefficient atoms.
  // Simultaneous CLEAR bits are rejected without clearing asset coverage.
  // MCU waits CMD_BUSY=0 before AND after each CSR1/12/13 write. CLEAR/atoms only
  // after ABORT acknowledgement; BEGIN preserves assets. STAT PAYLOAD_DONE means
  // exact byte count physically drained + native loader ready, not RUNNING.
endpackage
