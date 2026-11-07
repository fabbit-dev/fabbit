// Source: nand2mario/snestang 5f0ef193145f67bded7f73f2c477ac8da4d85f7e, src/dsp.vh
// Upstream project license: GPL-3.0 (see snes/LICENSE upstream copy).
// Fabbit adaptations: unverified-origin Gaussian coefficients removed; audio CE restored to nominal 4.096 MHz.

// parameter MCLK_NTSC_FREQ = 2147727;
// parameter MCLK_PAL_FREQ = 2128137;
// parameter ACLK_FREQ = 409600;            // original snes frequency, 533.33 samples per frame
// parameter ACLK_FREQ = 412674;           // 537.33 samples per frame
parameter ACLK_FREQ = 409600;           // 536.33 samples per frame


parameter V0VOLL = 8'h00;
parameter V1VOLL = 8'h10;
parameter V2VOLL = 8'h20;
parameter V3VOLL = 8'h30;
parameter V4VOLL = 8'h40;
parameter V5VOLL = 8'h50;
parameter V6VOLL = 8'h60;
parameter V7VOLL = 8'h70;

parameter V0VOLR = 8'h01;
parameter V1VOLR = 8'h11;
parameter V2VOLR = 8'h21;
parameter V3VOLR = 8'h31;
parameter V4VOLR = 8'h41;
parameter V5VOLR = 8'h51;
parameter V6VOLR = 8'h61;
parameter V7VOLR = 8'h71;

parameter V0PITCHL = 8'h02;
parameter V1PITCHL = 8'h12;
parameter V2PITCHL = 8'h22;
parameter V3PITCHL = 8'h32;
parameter V4PITCHL = 8'h42;
parameter V5PITCHL = 8'h52;
parameter V6PITCHL = 8'h62;
parameter V7PITCHL = 8'h72;

parameter V0PITCHH = 8'h03;
parameter V1PITCHH = 8'h13;
parameter V2PITCHH = 8'h23;
parameter V3PITCHH = 8'h33;
parameter V4PITCHH = 8'h43;
parameter V5PITCHH = 8'h53;
parameter V6PITCHH = 8'h63;
parameter V7PITCHH = 8'h73;

parameter V0SRCN = 8'h04;
parameter V1SRCN = 8'h14;
parameter V2SRCN = 8'h24;
parameter V3SRCN = 8'h34;
parameter V4SRCN = 8'h44;
parameter V5SRCN = 8'h54;
parameter V6SRCN = 8'h64;
parameter V7SRCN = 8'h74;

parameter V0ADSR1 = 8'h05;
parameter V1ADSR1 = 8'h15;
parameter V2ADSR1 = 8'h25;
parameter V3ADSR1 = 8'h35;
parameter V4ADSR1 = 8'h45;
parameter V5ADSR1 = 8'h55;
parameter V6ADSR1 = 8'h65;
parameter V7ADSR1 = 8'h75;

parameter V0ADSR2 = 8'h06;
parameter V1ADSR2 = 8'h16;
parameter V2ADSR2 = 8'h26;
parameter V3ADSR2 = 8'h36;
parameter V4ADSR2 = 8'h46;
parameter V5ADSR2 = 8'h56;
parameter V6ADSR2 = 8'h66;
parameter V7ADSR2 = 8'h76;

parameter V0GAIN = 8'h07;
parameter V1GAIN = 8'h17;
parameter V2GAIN = 8'h27;
parameter V3GAIN = 8'h37;
parameter V4GAIN = 8'h47;
parameter V5GAIN = 8'h57;
parameter V6GAIN = 8'h67;
parameter V7GAIN = 8'h77;

parameter V0ENVX = 8'h08;
parameter V1ENVX = 8'h18;
parameter V2ENVX = 8'h28;
parameter V3ENVX = 8'h38;
parameter V4ENVX = 8'h48;
parameter V5ENVX = 8'h58;
parameter V6ENVX = 8'h68;
parameter V7ENVX = 8'h78;

parameter V0OUTX = 8'h09;
parameter V1OUTX = 8'h19;
parameter V2OUTX = 8'h29;
parameter V3OUTX = 8'h39;
parameter V4OUTX = 8'h49;
parameter V5OUTX = 8'h59;
parameter V6OUTX = 8'h69;
parameter V7OUTX = 8'h79;

parameter MVOLL = 8'h0C;
parameter MVOLR = 8'h1C;
parameter EVOLL = 8'h2C;
parameter EVOLR = 8'h3C;
parameter KON = 8'h4C;
parameter KOFF = 8'h5C;
parameter FLG = 8'h6C;
// parameter ENDX = 8'h7C;     // nand2mario: this is shadowed by register of the same name 

parameter EFB = 8'h0D;
parameter PMON = 8'h2D;
parameter NON = 8'h3D;
parameter EON = 8'h4D;
parameter DIR = 8'h5D;
parameter ESA = 8'h6D;
parameter EDL = 8'h7D;

parameter FIR0 = 8'h0F;
parameter FIR1 = 8'h1F;
parameter FIR2 = 8'h2F;
parameter FIR3 = 8'h3F;
parameter FIR4 = 8'h4F;
parameter FIR5 = 8'h5F;
parameter FIR6 = 8'h6F;
parameter FIR7 = 8'h7F; 

// Register access 
// type RegsAccessTbl_t is array(0 to 31, 0 to 3) of std_logic_vector(7 downto 0);
localparam [7:0] RA_TBL[0:31][0:3] = '{
'{V0VOLR, V1PITCHL, V1ADSR1, 8'h7E},
'{8'h7E,  V1PITCHH, V1ADSR2, 8'h7E},
'{V0OUTX, V1VOLL,   V3SRCN,  8'h7E},
'{V1VOLR, V2PITCHL, V2ADSR1, 8'h7E},
'{V0ENVX, V2PITCHH, V2ADSR2, 8'h7E},	// 4
'{V1OUTX, V2VOLL,   V4SRCN,  8'h7E},
'{V2VOLR, V3PITCHL, V3ADSR1, 8'h7E},
'{V1ENVX, V3PITCHH, V3ADSR2, 8'h7E},
'{V2OUTX, V3VOLL,   V5SRCN,  8'h7E},	// 8
'{V3VOLR, V4PITCHL, V4ADSR1, 8'h7E},
'{V2ENVX, V4PITCHH, V4ADSR2, 8'h7E},
'{V3OUTX, V4VOLL,   V6SRCN,  8'h7E},
'{V4VOLR, V5PITCHL, V5ADSR1, 8'h7E},	// 12
'{V3ENVX, V5PITCHH, V5ADSR2, 8'h7E},
'{V4OUTX, V5VOLL,   V7SRCN,  8'h7E},
'{V5VOLR, V6PITCHL, V6ADSR1, 8'h7E},
'{V4ENVX, V6PITCHH, V6ADSR2, 8'h7E},// 16
'{V5OUTX, V6VOLL,   V0SRCN,  8'h7E},
'{V6VOLR, V7PITCHL, V7ADSR1, 8'h7E},
'{V5ENVX, V7PITCHH, V7ADSR2, 8'h7E},
'{V6OUTX, V7VOLL,   V1SRCN,  8'h7E},// 20
'{V7VOLR, V0PITCHL, V0ADSR1, 8'h7E},
'{V6ENVX, V0PITCHH, FIR0, 	 8'h7E},
'{V7OUTX, FIR1,     FIR2,    8'h7E},
'{FIR3,   FIR4,     FIR5,    8'h7E},// 24
'{V7ENVX, FIR6,     FIR7,    8'h7E},
'{MVOLL,  EVOLL, 	 EFB,     8'h7E},
'{MVOLR,  EVOLR, 	 PMON,    8'h7E},
'{NON,    EON,      DIR,     8'h7E},// 28
'{EDL,    ESA,      KON,     8'h7E},
'{KOFF,   FLG,      V0ADSR2, 8'h7E},
'{8'h7E,  V0VOLL,   V2SRCN,  8'h7E}
};

// VoiceStep_t
parameter [5:0] VS_IDLE = 0, VS_VOLL = 1, VS_VOLR = 2, VS_PITCHL = 3,
                VS_PITCHH = 4, VS_ADSR1 = 5, VS_ADSR2 = 6, VS_SRCN = 7,
                VS_ENVX = 8, VS_OUTX = 9, VS_FIR0 = 10, VS_FIR1 = 11,
                VS_FIR2 = 12, VS_FIR3 = 13, VS_FIR4 = 14, VS_FIR5 = 15,
                VS_FIR6 = 16, VS_FIR7 = 17, VS_MVOLL = 18, VS_MVOLR = 19,
                VS_EVOLL = 20, VS_EVOLR = 21, VS_EFB = 22, VS_PMON = 23,
                VS_NON = 24, VS_EON = 25, VS_DIR = 26, VS_EDL = 27,
                VS_ESA = 28, VS_KON = 29, VS_KOFF = 30, VS_FLG = 31,
                VS_ECHO = 32;
typedef struct packed {
    logic [5:0] S;      // Step: see above
    logic [2:0] V;      // Voice: 0 - 7
} VoiceStep_r;

// type VoiceStepTbl_t is array{0 to 31, 0 to 3) of VoiceStep_r;
localparam VoiceStep_r VS_TBL[0:31][0:3] = '{
'{{VS_VOLR,3'd0},  {VS_PITCHL,3'd1}, {VS_ADSR1,3'd1}, {VS_IDLE,3'd0}},
'{{VS_IDLE,3'd0},  {VS_PITCHH,3'd1}, {VS_ADSR2,3'd1}, {VS_IDLE,3'd0}},
'{{VS_OUTX,3'd0},  {VS_VOLL,3'd1},   {VS_SRCN,3'd3},  {VS_IDLE,3'd0}},
'{{VS_VOLR,3'd1},  {VS_PITCHL,3'd2}, {VS_ADSR1,3'd2}, {VS_IDLE,3'd0}},
'{{VS_ENVX,3'd0},  {VS_PITCHH,3'd2}, {VS_ADSR2,3'd2}, {VS_IDLE,3'd0}}, // 4
'{{VS_OUTX,3'd1},  {VS_VOLL,3'd2},   {VS_SRCN,3'd4},  {VS_IDLE,3'd0}},
'{{VS_VOLR,3'd2},  {VS_PITCHL,3'd3}, {VS_ADSR1,3'd3}, {VS_IDLE,3'd0}},
'{{VS_ENVX,3'd1},  {VS_PITCHH,3'd3}, {VS_ADSR2,3'd3}, {VS_IDLE,3'd0}},
'{{VS_OUTX,3'd2},  {VS_VOLL,3'd3},   {VS_SRCN,3'd5},  {VS_IDLE,3'd0}}, // 8
'{{VS_VOLR,3'd3},  {VS_PITCHL,3'd4}, {VS_ADSR1,3'd4}, {VS_IDLE,3'd0}},
'{{VS_ENVX,3'd2},  {VS_PITCHH,3'd4}, {VS_ADSR2,3'd4}, {VS_IDLE,3'd0}},
'{{VS_OUTX,3'd3},  {VS_VOLL,3'd4},   {VS_SRCN,3'd6},  {VS_IDLE,3'd0}},
'{{VS_VOLR,3'd4},  {VS_PITCHL,3'd5}, {VS_ADSR1,3'd5}, {VS_IDLE,3'd0}}, // 12
'{{VS_ENVX,3'd3},  {VS_PITCHH,3'd5}, {VS_ADSR2,3'd5}, {VS_IDLE,3'd0}},
'{{VS_OUTX,3'd4},  {VS_VOLL,3'd5},   {VS_SRCN,3'd7},  {VS_IDLE,3'd0}},
'{{VS_VOLR,3'd5},  {VS_PITCHL,3'd6}, {VS_ADSR1,3'd6}, {VS_IDLE,3'd0}},
'{{VS_ENVX,3'd4},  {VS_PITCHH,3'd6}, {VS_ADSR2,3'd6}, {VS_IDLE,3'd0}},// 16
'{{VS_OUTX,3'd5},  {VS_VOLL,3'd6},   {VS_SRCN,3'd0},  {VS_IDLE,3'd0}},
'{{VS_VOLR,3'd6},  {VS_PITCHL,3'd7}, {VS_ADSR1,3'd7}, {VS_IDLE,3'd0}},
'{{VS_ENVX,3'd5},  {VS_PITCHH,3'd7}, {VS_ADSR2,3'd7}, {VS_IDLE,3'd0}},
'{{VS_OUTX,3'd6},  {VS_VOLL,3'd7},   {VS_SRCN,3'd1},  {VS_IDLE,3'd0}}, // 20
'{{VS_VOLR,3'd7},  {VS_PITCHL,3'd0}, {VS_ADSR1,3'd0}, {VS_IDLE,3'd0}},
'{{VS_ENVX,3'd6},  {VS_PITCHH,3'd0}, {VS_FIR0,3'd0},  {VS_IDLE,3'd0}},
'{{VS_OUTX,3'd7},  {VS_FIR1,3'd1},   {VS_FIR2,3'd2},  {VS_IDLE,3'd0}},
'{{VS_FIR3,3'd3},  {VS_FIR4,3'd4},   {VS_FIR5,3'd5},  {VS_IDLE,3'd0}}, // 24
'{{VS_ENVX,3'd7},  {VS_FIR6,3'd6},   {VS_FIR7,3'd7},  {VS_IDLE,3'd0}},
'{{VS_MVOLL,3'd0}, {VS_EVOLL,3'd0},  {VS_EFB,3'd0},   {VS_IDLE,3'd0}},
'{{VS_MVOLR,3'd0}, {VS_EVOLR,3'd0},  {VS_PMON,3'd0},  {VS_IDLE,3'd0}},
'{{VS_NON,3'd0},   {VS_EON,3'd0},    {VS_DIR,3'd0},   {VS_IDLE,3'd0}}, // 28
'{{VS_EDL,3'd0},   {VS_ESA,3'd0},    {VS_KON,3'd0},   {VS_IDLE,3'd0}},
'{{VS_KOFF,3'd0},  {VS_FLG,3'd0},    {VS_ADSR2,3'd0}, {VS_IDLE,3'd0}},
'{{VS_ECHO,3'd0},  {VS_VOLL,3'd0},   {VS_SRCN,3'd2},  {VS_IDLE,3'd0}}
};

// RAM Access
parameter [3:0] RS_IDLE = 0, RS_BRRH = 1, RS_BRR1 = 2, RS_BRR2 = 3,
                RS_SRCNL = 4, RS_SRCNH = 5, RS_ECHORDL = 6, RS_ECHORDH = 7,
                RS_ECHOWRL = 8, RS_ECHOWRH = 9, RS_SMP = 10;
// type RamStepTbl_t is array(0 to 31, 0 to 3) of RamStep_t;
localparam [3:0] RS_TBL[0:31][0:3] = '{
'{RS_SRCNL,    RS_SRCNH,    RS_IDLE,  RS_SMP},
'{RS_BRR1,     RS_BRRH,     RS_IDLE,  RS_SMP},
'{RS_BRR2,     RS_IDLE,     RS_IDLE,  RS_SMP},
'{RS_SRCNL,    RS_SRCNH,    RS_IDLE,  RS_SMP},
'{RS_BRR1,     RS_BRRH,     RS_IDLE,  RS_SMP},
'{RS_BRR2,     RS_IDLE,     RS_IDLE,  RS_SMP},
'{RS_SRCNL,    RS_SRCNH,    RS_IDLE,  RS_SMP},
'{RS_BRR1,     RS_BRRH,     RS_IDLE,  RS_SMP},
'{RS_BRR2,     RS_IDLE,     RS_IDLE,  RS_SMP},
'{RS_SRCNL,    RS_SRCNH,    RS_IDLE,  RS_SMP},
'{RS_BRR1,     RS_BRRH,     RS_IDLE,  RS_SMP},
'{RS_BRR2,     RS_IDLE,     RS_IDLE,  RS_SMP},
'{RS_SRCNL,    RS_SRCNH,    RS_IDLE,  RS_SMP},
'{RS_BRR1,     RS_BRRH,     RS_IDLE,  RS_SMP},
'{RS_BRR2,     RS_IDLE,     RS_IDLE,  RS_SMP},
'{RS_SRCNL,    RS_SRCNH,    RS_IDLE,  RS_SMP},
'{RS_BRR1,     RS_BRRH,     RS_IDLE,  RS_SMP},  // 16
'{RS_BRR2,     RS_IDLE,     RS_IDLE,  RS_SMP},
'{RS_SRCNL,    RS_SRCNH,    RS_IDLE,  RS_SMP},
'{RS_BRR1,     RS_BRRH,     RS_IDLE,  RS_SMP},
'{RS_BRR2,     RS_IDLE,     RS_IDLE,  RS_SMP},  // 20
'{RS_SRCNL,    RS_SRCNH,    RS_IDLE,  RS_SMP},
'{RS_ECHORDL,  RS_ECHORDH,  RS_IDLE,  RS_SMP},
'{RS_ECHORDL,  RS_ECHORDH,  RS_IDLE,  RS_SMP},
'{RS_IDLE,     RS_IDLE,     RS_IDLE,  RS_SMP},  // 24
'{RS_BRR1,     RS_BRRH,     RS_IDLE,  RS_SMP},
'{RS_IDLE,     RS_IDLE,     RS_IDLE,  RS_SMP},
'{RS_IDLE,     RS_IDLE,     RS_IDLE,  RS_SMP},
'{RS_IDLE,     RS_IDLE,     RS_IDLE,  RS_SMP},  // 28
'{RS_ECHOWRL,  RS_ECHOWRH,  RS_IDLE,  RS_SMP},
'{RS_ECHOWRL,  RS_ECHOWRH,  RS_IDLE,  RS_SMP},
'{RS_BRR2,     RS_IDLE,     RS_IDLE,  RS_SMP}
};

// type BrrVoiceTbl_t is array(0 to 31) of integer range 0 to 7;
localparam [2:0] BRR_VOICE_TBL[0:31] = '{
3'd1, 3'd1, 3'd1, 3'd2, 3'd2, 3'd2, 3'd3, 3'd3, 
3'd3, 3'd4, 3'd4, 3'd4, 3'd5, 3'd5, 3'd5, 3'd6, 
3'd6, 3'd6, 3'd7, 3'd7, 3'd7, 3'd0, 3'd0, 3'd0, 
3'd0, 3'd0, 3'd0, 3'd0, 3'd0, 3'd0, 3'd0, 3'd0
};

// BRR Decode
parameter [2:0] BDS_IDLE = 0, BDS_SMPL0 = 1, BDS_SMPL1 = 2, 
                BDS_SMPL2 = 3, BDS_SMPL3 = 4;
typedef struct packed {
    logic [2:0] S;      // BDS_IDLE ...
    logic [2:0] V;      // 0 - 7
} BRRDecodeStep_r;

// type BRRDecodeStepTbl_t is array(0 to 31, 0 to 3) of BRRDecodeStep_r;
localparam BRRDecodeStep_r BDS_TBL [0:31][0:3] = '{
'{{BDS_SMPL2,3'd0}, {BDS_SMPL3,3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_SMPL0,3'd1}, {BDS_SMPL1,3'd1}},
'{{BDS_SMPL2,3'd1}, {BDS_SMPL3,3'd1}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},  // 4
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_SMPL0,3'd2}, {BDS_SMPL1,3'd2}},
'{{BDS_SMPL2,3'd2}, {BDS_SMPL3,3'd2}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_SMPL0,3'd3}, {BDS_SMPL1,3'd3}},  // 8
'{{BDS_SMPL2,3'd3}, {BDS_SMPL3,3'd3}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_SMPL0,3'd4}, {BDS_SMPL1,3'd4}},
'{{BDS_SMPL2,3'd4}, {BDS_SMPL3,3'd4}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},  // 12
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_SMPL0,3'd5}, {BDS_SMPL1,3'd5}},
'{{BDS_SMPL2,3'd5}, {BDS_SMPL3,3'd5}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},  // 16
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_SMPL0,3'd6}, {BDS_SMPL1,3'd6}},
'{{BDS_SMPL2,3'd6}, {BDS_SMPL3,3'd6}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_SMPL0,3'd7}, {BDS_SMPL1,3'd7}},  // 20
'{{BDS_SMPL2,3'd7}, {BDS_SMPL3,3'd7}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},  // 24
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},  // 28
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}},
'{{BDS_IDLE, 3'd0}, {BDS_IDLE, 3'd0}, {BDS_SMPL0,3'd0}, {BDS_SMPL1,3'd0}}
};

// RAM Access
parameter [1:0]  IS_IDLE = 0, IS_ENV = 1, IS_ENV2 = 2;
typedef struct packed {
    logic [1:0] S;      // IS_IDLE ...
    logic [2:0] V;      // 0 - 7
} IntStep_r;

// type IntStepTbl_t is array(0 to 31, 0 to 3) of IntStep_r;
localparam IntStep_r IS_TBL[0:31][0:3] = '{
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd1},    {IS_ENV,  3'd1},    {IS_ENV2, 3'd1}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd2},    {IS_ENV,  3'd2},    {IS_ENV2, 3'd2}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd3},    {IS_ENV,  3'd3},    {IS_ENV2, 3'd3}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd4},    {IS_ENV,  3'd4},    {IS_ENV2, 3'd4}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd5},    {IS_ENV,  3'd5},    {IS_ENV2, 3'd5}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd6},    {IS_ENV,  3'd6},    {IS_ENV2, 3'd6}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd7},    {IS_ENV,  3'd7},    {IS_ENV2, 3'd7}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_ENV,  3'd0},    {IS_ENV2, 3'd0}},
'{{IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0},    {IS_IDLE, 3'd0}}
};

parameter [2:0]
    GS_IDLE = 0,
    GS_WAIT = 1,
    GS_BRR0 = 2,
    GS_BRR1 = 3,
    GS_BRR2 = 4,
    GS_BRR3 = 5;

parameter [1:0]
    BD_IDLE = 0,
    BD_WAIT = 1,
    BD_P0 = 2,
    BD_P1 = 3;

// Envelope Modes
parameter [1:0]
    EM_RELEASE = 0,
    EM_ATTACK = 1,
    EM_DECAY = 2,
    EM_SUSTAIN = 3;

// type GaussTbl_t is array(0 to 511) of signed(11 downto 0);
// Gaussian coefficients supplied externally; no upstream silicon table embedded.

// clamp a 17-bit signed integer to 16-bit signed (max 0x7fff and min 0x8000)
function logic signed [15:0] CLAMP16(logic signed [16:0] a);
    return a[16:15] == 2'b01 ? 16'h7fff :
           a[16:15] == 2'b10 ? 16'h8000 :
           16'(a);
endfunction
