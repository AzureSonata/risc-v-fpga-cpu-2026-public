`timescale 1ns/1ps
`include "defines.sv"

module tb_branch_predictor_dual;
    reg clk=0, rst=`RstEnable;
    always #5 clk=~clk;
    reg q_valid=0, q1_valid=0;
    reg [31:0] q_pc=0, q1_pc=0;
    wire q_hit,q_taken,q1_hit,q1_taken;
    wire [31:0] q_target,q1_target;
    reg u_valid=0, u_taken=0, u_pred_taken=0, u_exception=0;
    reg u_is_call=0, u_is_ret=0;
    reg [31:0] u_pc=0, u_target=0, u_pred_target=0;
    reg stat_clr=0;
    wire [31:0] stat_query,stat_hit,stat_mispredict;
    integer checks=0;

    branch_predictor #(.DUAL_QUERY(1'b1),.RAS_ENABLE(1'b1),.RAS_DEPTH(8)) dut (
        .clk(clk),.rst(rst),
        .q_valid(q_valid),.q_pc(q_pc),.q_hit(q_hit),.q_taken(q_taken),.q_target(q_target),
        .q1_valid(q1_valid),.q1_pc(q1_pc),.q1_hit(q1_hit),.q1_taken(q1_taken),.q1_target(q1_target),
        .u_valid(u_valid),.u_pc(u_pc),.u_taken(u_taken),.u_target(u_target),
        .u_pred_taken(u_pred_taken),.u_pred_target(u_pred_target),.u_exception(u_exception),
        .u_is_call(u_is_call),.u_is_ret(u_is_ret),
        .stat_clr(stat_clr),.stat_query(stat_query),.stat_hit(stat_hit),.stat_mispredict(stat_mispredict)
    );

    task check(input condition,input [8*80-1:0] label);
      begin
        checks=checks+1;
        if(condition!==1'b1) $fatal(1,"FAIL: %0s",label);
      end
    endtask

    task train(input [31:0] pc,input taken,input [31:0] target,input is_call,input is_ret);
      begin
        @(negedge clk);
        u_valid=1;u_pc=pc;u_taken=taken;u_target=target;
        u_is_call=is_call;u_is_ret=is_ret;u_pred_taken=0;u_pred_target=0;u_exception=0;
        @(posedge clk);#1;
        @(negedge clk);u_valid=0;u_is_call=0;u_is_ret=0;
      end
    endtask

    initial begin
      repeat(3) @(posedge clk);
      @(negedge clk);rst=`RstDisable;
      q_pc=32'h00001000;q1_pc=32'h00001004;
      #1;check(!q_hit&&!q1_hit,"both adjacent entries miss after reset");

      train(32'h00001000,1,32'h00002000,0,0);
      train(32'h00001004,1,32'h00003000,0,0);
      q_valid=1;q1_valid=1;#1;
      check(q_hit&&q_taken&&(q_target==32'h00002000),"query port 0 returns first BTB entry");
      check(q1_hit&&q1_taken&&(q1_target==32'h00003000),"query port 1 returns adjacent BTB entry");
      @(posedge clk);#1;
      check(stat_query==2&&stat_hit==2,"dual query statistics count both requests");
      @(negedge clk);q_valid=0;q1_valid=0;

      // Install a return marker with an empty stack, then push a call. The
      // second lookup must select the current RAS top instead of its stale BTB target.
      train(32'h00004000,1,32'h0000dead,0,1);
      train(32'h00005010,1,32'h00006000,1,0);
      q1_pc=32'h00004000;#1;
      check(q1_hit&&q1_taken&&(q1_target==32'h00005014),"RAS depth-8 top overrides a cached return target");

      // A later not-taken update changes only entry 0's direction state.
      train(32'h00001000,0,32'h00002000,0,0);
      q_pc=32'h00001000;q1_pc=32'h00001004;#1;
      check(q_hit&&!q_taken,"port 0 direction trains independently");
      check(q1_hit&&q1_taken,"port 1 entry remains taken");

      $display("PASS: dual-query predictor %0d checks",checks);
      $display("ALL TESTS PASSED (branch_predictor_dual)");
      $finish;
    end
    initial begin #10000;$fatal(1,"TIMEOUT");end
endmodule
