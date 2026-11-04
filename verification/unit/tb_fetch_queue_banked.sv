`timescale 1ns/1ps
`include "defines.sv"

module tb_fetch_queue_banked;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg         in0_valid;
    reg  [31:0] in0_pc;
    reg  [31:0] in0_inst;
    reg         in0_fault;
    reg         in0_pred_valid;
    reg         in0_pred_taken;
    reg  [31:0] in0_pred_target;
    reg         in1_valid;
    reg  [31:0] in1_pc;
    reg  [31:0] in1_inst;
    reg         in1_fault;
    reg         in1_pred_valid;
    reg         in1_pred_taken;
    reg  [31:0] in1_pred_target;

    wire [1:0]  in_ready;
    wire        decode0_valid, decode1_valid;
    wire        out0_valid;
    wire [31:0] out0_pc, out0_inst, out0_pred_target;
    wire        out0_fault, out0_pred_valid, out0_pred_taken;
    wire        out1_valid;
    wire [31:0] out1_pc, out1_inst, out1_pred_target;
    wire        out1_fault, out1_pred_valid, out1_pred_taken;
    reg         out0_consume, out1_consume, flush;

    wire [98:0] out0_payload = {out0_pred_target, out0_pred_taken,
                                out0_pred_valid, out0_fault, out0_inst, out0_pc};
    wire [98:0] out1_payload = {out1_pred_target, out1_pred_taken,
                                out1_pred_valid, out1_fault, out1_inst, out1_pc};

    fetch_queue #(.DEPTH(8)) dut (
        .clk(clk), .rst(rst),
        .in0_valid(in0_valid), .in0_pc(in0_pc), .in0_inst(in0_inst),
        .in0_fault(in0_fault), .in0_pred_valid(in0_pred_valid),
        .in0_pred_taken(in0_pred_taken), .in0_pred_target(in0_pred_target),
        .in1_valid(in1_valid), .in1_pc(in1_pc), .in1_inst(in1_inst),
        .in1_fault(in1_fault), .in1_pred_valid(in1_pred_valid),
        .in1_pred_taken(in1_pred_taken), .in1_pred_target(in1_pred_target),
        .in_ready(in_ready),
        .decode0_valid(decode0_valid), .decode1_valid(decode1_valid),
        .out0_valid(out0_valid), .out0_pc(out0_pc), .out0_inst(out0_inst),
        .out0_fault(out0_fault), .out0_pred_valid(out0_pred_valid),
        .out0_pred_taken(out0_pred_taken), .out0_pred_target(out0_pred_target),
        .out1_valid(out1_valid), .out1_pc(out1_pc), .out1_inst(out1_inst),
        .out1_fault(out1_fault), .out1_pred_valid(out1_pred_valid),
        .out1_pred_taken(out1_pred_taken), .out1_pred_target(out1_pred_target),
        .out0_consume(out0_consume), .out1_consume(out1_consume),
        .flush(flush)
    );


    reg [98:0] model[0:7];
    integer count=0, step=0, checks=0, n,j,pops,pushes,ready_expected;
    reg [31:0] lfsr=32'h13579bdf;
    reg [98:0] payload0,payload1;
    reg [8:0] seen_count=0;
    task verify;
      begin
        checks=checks+1;
        if(in_ready !== (flush ? 2'd0 : count>=8 ? 2'd0 : count==7 ? 2'd1 : 2'd2))
          $fatal(1,"FAIL ready step=%0d count=%0d ready=%0d",step,count,in_ready);
        checks=checks+1;
        if(out0_valid !== (!flush && count>0) || decode0_valid !== (count>0))
          $fatal(1,"FAIL valid0 step=%0d count=%0d",step,count);
        checks=checks+1;
        if(out1_valid !== (!flush && count>1) || decode1_valid !== (count>1))
          $fatal(1,"FAIL valid1 step=%0d count=%0d",step,count);
        if(count>0) begin
          checks=checks+1; if(out0_payload!==model[0]) $fatal(1,"FAIL payload0 step=%0d",step);
        end
        if(count>1) begin
          checks=checks+1; if(out1_payload!==model[1]) $fatal(1,"FAIL payload1 step=%0d",step);
        end
      end
    endtask
    initial begin
      in0_valid=0;in1_valid=0;out0_consume=0;out1_consume=0;flush=0;
      in0_pc=0;in0_inst=0;in0_fault=0;in0_pred_valid=0;in0_pred_taken=0;in0_pred_target=0;
      in1_pc=0;in1_inst=0;in1_fault=0;in1_pred_valid=0;in1_pred_taken=0;in1_pred_target=0;
      repeat(3) @(negedge clk);rst=0;
      for(step=0;step<4096;step=step+1) begin
        @(negedge clk);
        lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        in0_valid=(step<6) ? 1'b1 : lfsr[0];
        in1_valid=(step<6) ? 1'b1 : lfsr[1];
        out0_consume=(step<4) ? 1'b0 : lfsr[2];
        out1_consume=lfsr[3];
        flush=(step>8 && lfsr[9:4]==0);
        in0_pred_target=lfsr^32'hdead1234;
        in0_pred_taken=lfsr[6];
        in0_pred_valid=lfsr[7];
        in0_fault=lfsr[8];
        in0_inst=32'h01000000+step;
        in0_pc=32'h00001000+(step*8);
        in1_pred_target=lfsr^32'h1234dead;
        in1_pred_taken=lfsr[9];
        in1_pred_valid=lfsr[10];
        in1_fault=lfsr[11];
        in1_inst=32'h02000000+step;
        in1_pc=32'h00001004+(step*8);
        payload0={in0_pred_target,in0_pred_taken,in0_pred_valid,in0_fault,in0_inst,in0_pc};
        payload1={in1_pred_target,in1_pred_taken,in1_pred_valid,in1_fault,in1_inst,in1_pc};
        #1;verify();seen_count[count]=1;
        ready_expected=flush ? 0 : count>=8 ? 0 : count==7 ? 1 : 2;
        pops=(out0_consume && count>0) ? ((out1_consume && count>1)?2:1):0;
        pushes=(in0_valid && ready_expected>0) ? ((in1_valid && ready_expected>1)?2:1):0;
        @(posedge clk);
        if(flush) count=0;
        else begin
          for(j=0;j<count-pops;j=j+1)model[j]=model[j+pops];
          count=count-pops;
          if(pushes>0)model[count]=payload0;
          if(pushes>1)model[count+1]=payload1;
          count=count+pushes;
        end
        #1;verify();
      end
      if(seen_count!==9'h1ff) $fatal(1,"FAIL occupancy coverage=%h",seen_count);
      $display("PASS: banked queue 4096 randomized cycles %0d payload/credit checks; all 9 occupancies",checks);
      $display("ALL TESTS PASSED (fetch_queue_banked)");$finish;
    end
endmodule
