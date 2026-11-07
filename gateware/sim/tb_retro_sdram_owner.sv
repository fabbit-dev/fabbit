`timescale 1ns/1ps
module tb_retro_sdram_owner;
  logic clk=0,rst=1,safe=1;
  // Product management domain, not the old unit fixture's 100 MHz clock.
  always #9.312 clk=~clk;
  logic nes_clock=0,md_clock=0,snes_clock=0;
  int nes_phase_ps=0,md_phase_ps=2011,snes_phase_ps=2037;
  initial begin
    if ($value$plusargs("nes_phase_ps=%d",nes_phase_ps)) begin end
    repeat (nes_phase_ps) #1ps;
    forever #7.778 nes_clock=~nes_clock;
  end
  initial begin
    if ($value$plusargs("md_phase_ps=%d",md_phase_ps)) begin end
    repeat (md_phase_ps) #1ps;
    forever #9.312 md_clock=~md_clock;
  end
  initial begin
    if ($value$plusargs("snes_phase_ps=%d",snes_phase_ps)) begin end
    repeat (snes_phase_ps) #1ps;
    forever #5.820 snes_clock=~snes_clock;
  end
  logic [1:0] requested=0;
  wire [1:0] owner;
  wire busy,memory_clock;
  logic [10:0] a [3]='{11'h123,11'h234,11'h345};
  logic [1:0] ba [3]='{2'd0,2'd1,2'd2};
  logic [2:0] command [3]='{3'b100,3'b101,3'b011};
  logic [31:0] data [3]='{32'h12345678,32'h23456789,32'h3456789a};
  wire [2:0] drive=3'b111;
  wire [10:0] sd_a;
  wire [1:0] sd_ba;
  wire sd_ras_n,sd_cas_n,sd_we_n,dq_oe;
  wire [31:0] dq_out;
  retro_sdram_owner dut (.*);
  realtime last_edge=0,last_rise=0,max_rise_gap=0,min_pulse=1us;
  int directed_count=0,reset_count=0;
  bit [5:0] reset_states=0;
  always @(memory_clock) begin
    if (last_edge!=0) begin
      assert ($realtime-last_edge>=2.5ns)
        else $fatal(1,"short SDRAM clock pulse %0.3fns",($realtime-last_edge)/1ns);
      if ($realtime-last_edge<min_pulse) min_pulse=$realtime-last_edge;
    end
    last_edge=$realtime;
  end
  always @(posedge memory_clock) begin
    if (last_rise!=0) begin
      assert ($realtime-last_rise<1000ns) else $fatal(1,"rising tCCmax");
      if ($realtime-last_rise>max_rise_gap) max_rise_gap=$realtime-last_rise;
    end
    last_rise=$realtime;
  end
  // Independent management-clock watchdog catches a permanently stopped output,
  // including during reset. This test assumes all clock sources remain live.
  always @(negedge clk) begin
    if (last_rise!=0)
      assert ($realtime-last_rise<1000ns) else $fatal(1,"SDRAM clock stopped");
    if (rst || safe || busy || owner==0) begin
      assert ({sd_ras_n,sd_cas_n,sd_we_n}==3'b111 && !dq_oe &&
              sd_a==0 && sd_ba==0 && dq_out==0)
        else $fatal(1,"owner transition did not blank command/DQ");
    end else begin
      assert (sd_a==a[owner-1] && sd_ba==ba[owner-1] &&
              {sd_ras_n,sd_cas_n,sd_we_n}==command[owner-1] &&
              dq_oe && dq_out==data[owner-1])
        else $fatal(1,"owner payload mismatch");
    end
  end
  // Structural protocol assertions: no overlap; first command pair is frozen
  // for an entire final-mux transaction, not merely its OFF or ON state.
  logic [1:0] frozen_first=2'b01;
  bit final_inflight=0;
  always @(negedge clk) begin
    assert (!(dut.select_line[0] && dut.select_line[1]) &&
            !(dut.select_line[2] && dut.select_line[3])) else $fatal(1,"S overlap");
    if (dut.state==dut.WaitOff && dut.off_index[1] && !final_inflight) begin
      frozen_first=dut.select_command[1:0];final_inflight=1;
    end
    if (final_inflight) begin
      assert (dut.select_command[1:0]==frozen_first) else $fatal(1,"group retargeted");
      if (dut.state==dut.Plan) final_inflight=0;
    end
  end
  // Local outputs may move ONLY on their own rising edge. Also verify each
  // level ACK waits eight complete source periods following its S transition.
  for (genvar i=0;i<4;i++) begin : g_check_select
    realtime local_rise=0,change_time=0;
    int periods=0;
    always @(posedge dut.source_clock[i]) begin
      local_rise=$realtime;periods++;
    end
    always @(dut.select_line[i]) if ($time>0) begin
      assert (local_rise==$realtime) else $fatal(1,"nonlocal S transition %0d",i);
      change_time=$realtime;periods=0;
    end
    always @(dut.g_select[i].acknowledged) if ($time>0) begin
      assert (periods>=8 && $realtime>change_time)
        else $fatal(1,"early local ACK %0d periods=%0d",i,periods);
    end
  end
  task automatic wait_owner(input logic [1:0] target_owner);
    realtime rise_at,expected_period;
    wait (!busy && owner==target_owner);
    @(negedge clk);
    assert ((target_owner==3 ||
             dut.select_line[1:0]==(target_owner==2 ? 2'b10 : 2'b01)) &&
            dut.select_line[3:2]==(target_owner==3 ? 2'b10 : 2'b01))
      else $fatal(1,"committed wrong physical clock");
    expected_period=target_owner==3 ? 11.640ns : target_owner==2 ? 18.624ns : 15.556ns;
    @(posedge memory_clock);rise_at=$realtime;
    repeat (4) begin
      @(posedge memory_clock);
      assert ($realtime-rise_at>=expected_period-1ps &&
              $realtime-rise_at<=expected_period+1ps) else $fatal(1,"wrong source period");
      rise_at=$realtime;
    end
  endtask
  task automatic select_owner(input logic [1:0] target_owner);
    @(negedge clk);safe=1;requested=target_owner;
    wait_owner(target_owner);
    safe=0;
    repeat (12) @(negedge clk);
  endtask
  task automatic reset_at(input logic [2:0] reset_state,input bit final_level);
    select_owner(2);
    @(negedge clk);safe=1;requested=final_level ? 2'd3 : 2'd1;
    wait (dut.state==reset_state &&
          ((reset_state!=dut.WaitOff && reset_state!=dut.WaitOn) ||
           dut.off_index[1]==final_level));
    #1ns;rst=1;safe=0;requested=0;
    #1ns;
    assert (busy && !dq_oe && {sd_ras_n,sd_cas_n,sd_we_n}==3'b111)
      else $fatal(1,"reset did not promptly blank");
    reset_states[reset_state]=1;reset_count++;
    repeat (3) @(negedge clk);
    rst=0;
    wait_owner(0);
    assert (owner==0) else $fatal(1,"stale ACK after reset");
  endtask
  initial begin
    repeat (5) @(negedge clk);rst=0;
    wait_owner(0);
    // Every directed change, including idle owner zero, plus same-owner requests.
    for (int source=0;source<4;source++) begin
      for (int target_owner=0;target_owner<4;target_owner++) begin
        select_owner(2'(source));select_owner(2'(target_owner));directed_count++;
      end
    end
    // Unsafe requests cannot start a handover.
    select_owner(1);
    @(negedge clk);requested=2;
    repeat (40) @(negedge clk);
    assert (owner==1 && dut.state==dut.Idle && dut.select_command==4'b0101)
      else $fatal(1,"unsafe request started handover");
    // Latch target 2, then retarget to 3 and remove safe while switching.
    safe=1;
    wait (dut.state==dut.WaitOff);
    @(negedge clk);requested=3;safe=0;
    wait (dut.state==dut.Commit);
    repeat (40) @(negedge clk);
    assert (owner==1 && dut.target==2 && busy && dut.select_line==4'b0110)
      else $fatal(1,"unsafe retarget tore transaction");
    safe=1;
    wait (owner==2);
    assert (busy) else $fatal(1,"queued request escaped busy");
    wait_owner(3);safe=0;
    repeat (12) @(negedge clk);
    // All six manager states; OFF and ON are reset at both mux levels.
    select_owner(2);
    #1ns;rst=1;requested=0;
    reset_states[dut.Idle]=1;reset_count++;
    repeat (3) @(negedge clk);rst=0;wait_owner(0);
    reset_at(dut.Plan,0);
    reset_at(dut.WaitOff,0);reset_at(dut.WaitOn,0);
    reset_at(dut.WaitOff,1);reset_at(dut.WaitOn,1);
    reset_at(dut.Commit,0);reset_at(dut.Settle,0);
    assert (&reset_states && directed_count==16 && reset_count==8)
      else $fatal(1,"coverage incomplete states=%b",reset_states);
    select_owner(3);select_owner(0);
    // Nominal 447 ns budget, stricter than the required 1000 ns contract.
    assert (max_rise_gap<=447ns) else $fatal(1,"nominal handover budget exceeded");
    $display("ok owner directed=%0d resets=%0d states=%b phases_ps=%0d/%0d/%0d",
             directed_count,reset_count,reset_states,nes_phase_ps,md_phase_ps,snes_phase_ps);
    $display("ok max_rise_gap_ns=%0.3f min_pulse_ns=%0.3f",
             max_rise_gap/1ns,min_pulse/1ns);
    $finish;
  end
  initial begin #1ms;$fatal(1,"timeout state=%0d owner=%0d",dut.state,owner);end
endmodule
