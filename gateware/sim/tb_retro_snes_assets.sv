`default_nettype none
`timescale 1ns / 1ps
module tb_retro_snes_assets;
    logic clk=0;
    always #5ns clk=!clk;
    logic reset=1, run=0, start=0, byte_valid=0, byte_last=0;
    logic [1:0] channel=0;
    logic [10:0] byte_addr=0;
    logic [7:0] byte_data=0;
    wire byte_ready, busy, done;
    wire [2:0] error;
    wire ipl_clear, ipl_we, coeff_clear, coeff_we;
    wire [5:0] ipl_addr;
    wire [7:0] ipl_data;
    wire [8:0] coeff_addr;
    wire [11:0] coeff_data;
    wire ipl_ready, coeff_ready;
    logic suppress_ready=0;
    wire backend_ipl_ready=ipl_ready && !suppress_ready;
    wire backend_coeff_ready=coeff_ready && !suppress_ready;
    snes_asset_loader dut (.*);
    logic [5:0] ipl_read_addr=0;
    wire [7:0] ipl_read_data;
    logic [8:0] coeff_read_addr=0;
    wire signed [11:0] coeff_read_data;
    snes_assets backend (.*);
    int ipl_writes=0, coeff_writes=0, completions=0;
    always @(posedge clk) begin
        if (ipl_we) ipl_writes++;
        if (coeff_we) coeff_writes++;
        if (done) completions++;
    end
    task automatic tick;
        @(posedge clk); #1ns;
    endtask
    task automatic begin_asset(input logic [1:0] ch);
        channel=ch; start=1; tick(); start=0; tick();
    endtask
    task automatic send(input int addr,input byte value,input bit last_byte);
        while (!byte_ready) tick();
        byte_addr=11'(addr); byte_data=value; byte_last=last_byte; byte_valid=1;
        tick(); byte_valid=0;
    endtask
    task automatic wait_done;
        assert (!done) else $fatal(1,"done before backend final write");
        do tick(); while (busy);
        assert (done && error==0) else $fatal(1,"completion/backend guard");
        tick();
    endtask
    initial begin
        repeat (3) tick(); reset=0; tick();
        assert (!ipl_ready && !coeff_ready) else $fatal(1,"default assets present");
        begin_asset(0);
        for (int i=0;i<64;i++) begin
            if ((i%7)==0) repeat (3) tick();
            send(i,8'(i^8'ha5),i==63);
        end
        wait_done();
        assert (ipl_ready && ipl_writes==64 && completions==1)
            else $fatal(1,"IPL exact coverage/count");
        for (int i=0;i<64;i++) begin
            ipl_read_addr=6'(i); #1ns;
            assert (ipl_read_data==8'(i^8'ha5)) else $fatal(1,"IPL ordering");
        end
        begin_asset(1);
        for (int i=0;i<512;i++) begin
            send(i*2,8'(i),0);
            send(i*2+1,8'((i>>8)|4'ha),i==511);
        end
        wait_done();
        assert (coeff_ready && coeff_writes==512 && completions==2)
            else $fatal(1,"Gaussian exact coverage/count");
        for (int i=0;i<512;i++) begin
            coeff_read_addr=9'(i); #1ns;
            assert (coeff_read_data==12'(12'ha00|i)) else $fatal(1,"12-bit LE coefficient");
        end
        // ABORT at the outer ROM session does not clear a completed coefficient
        // image. A fresh stopped START must replace an unfinished IPL upload.
        begin_asset(0);
        for (int i=0;i<11;i++) send(i,8'(i),0);
        assert (busy && !ipl_ready && coeff_ready) else $fatal(1,"partial IPL state");
        begin_asset(0);
        for (int i=0;i<64;i++) send(i,8'(i^8'h3c),i==63);
        wait_done();
        assert (ipl_ready && coeff_ready) else $fatal(1,"restart destroyed other asset");
        // Duplicate address, early last, missing last, invalid high nibble.
        begin_asset(0); send(0,1,0); send(0,2,0); tick();
        assert (error==3 && !ipl_ready && !busy) else $fatal(1,"duplicate address");
        begin_asset(0); send(0,1,1); tick();
        assert (error==4 && !ipl_ready && !busy) else $fatal(1,"short IPL");
        begin_asset(0);
        for (int i=0;i<64;i++) send(i,8'(i),0);
        tick();
        assert (error==4 && !ipl_ready) else $fatal(1,"missing last");
        begin_asset(1); send(0,8'h34,0); send(1,8'hf2,0); tick();
        assert (error==5 && !coeff_ready) else $fatal(1,"coefficient truncation accepted");
        suppress_ready=1; begin_asset(0);
        for (int i=0;i<64;i++) send(i,8'(i),i==63);
        repeat (6) tick();
        assert (error==6 && !done && !ipl_ready) else $fatal(1,"backend ready ignored");
        suppress_ready=0; run=1; begin_asset(0);
        assert (error==1 && busy && !byte_ready) else $fatal(1,"run programming guard");
        run=0; tick(); reset=1; tick(); reset=0; tick();
        assert (!ipl_ready && !coeff_ready) else $fatal(1,"reset retained valid assets");
        begin_asset(0); send(0,8'h56,0); run=1; tick();
        assert (error==2 && busy && !byte_ready) else $fatal(1,"midstream run not aborted");
        run=0; repeat (3) tick();
        assert (!ipl_ready && !coeff_ready && !busy && !byte_ready)
            else $fatal(1,"deferred invalidation/reception guard");
        $display("PASS SNES assets: lengths/LE12/order/last/coverage/backend/run guards");
        $finish;
    end
    initial begin #100us; $fatal(1,"timeout"); end
endmodule
`default_nettype wire
