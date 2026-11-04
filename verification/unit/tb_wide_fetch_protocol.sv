`timescale 1ns/1ps
`include "defines.sv"
module tb_wide_fetch_protocol;
reg clk=0,rst=`RstEnable,redirect=0,rsp_valid=0;
always #5 clk=~clk;
reg [31:0] target=0;
reg [63:0] data=0;
reg [1:0] room=2;
reg req_ready=0;
wire req_valid,rsp_ready,q0valid,q1valid;
wire [31:0] req_addr,q0pc,q1pc,q0inst,q1inst;
integer drains=0;
wide_fetch dut(.clk(clk),.rst(rst),.redirect_valid(redirect),.redirect_target(target),
.i_req_valid(req_valid),.i_req_ready(req_ready),.i_req_addr(req_addr),
.i_rsp_valid(rsp_valid),.i_rsp_ready(rsp_ready),.i_rsp_data(data), .i_rsp_error(2'b00),
.push_ready(room),.q0_valid(q0valid),.q0_pc(q0pc),.q0_inst(q0inst),
.q1_valid(q1valid),.q1_pc(q1pc),.q1_inst(q1inst),.pc_debug());
always @(posedge clk) if(!rst && rsp_valid && rsp_ready) drains=drains+1;
initial begin
 repeat(2) @(negedge clk);rst=`RstDisable;req_ready=1;
 @(posedge clk); @(negedge clk);req_ready=0;
 // More than four redirects must not wrap a tag and revive the old response.
 repeat(5) begin redirect=1;target=32'h1c;@(negedge clk);end
 redirect=0;rsp_valid=1;data=64'h1111111122222222;
 if(q0valid) $fatal(1,"FAIL: stale instruction visible");
 @(posedge clk);@(negedge clk);rsp_valid=0;
 if(drains!=1) $fatal(1,"FAIL: stale response did not drain");
 if(!req_valid || req_addr!=32'h18) $fatal(1,"FAIL: redirect request address");
 req_ready=1;@(posedge clk);@(negedge clk);req_ready=0;
 rsp_valid=1;data=64'h0070031306300293;
 @(posedge clk);@(negedge clk);rsp_valid=0;room=0;
 if(!dut.block_valid_q) $fatal(1,"FAIL: target response missing");
 repeat(3) @(negedge clk);
 room=1;#1;
 if(!q0valid || q0pc!=32'h1c || q0inst!=32'h00700313 || q1valid)
  $fatal(1,"FAIL: target PC[2]/high-word selection");
 @(posedge clk);@(negedge clk);
 if(dut.block_valid_q) $fatal(1,"FAIL: high-only block not consumed");
 $display("PASS: sticky stale survives repeated redirects and drains strict slave");
 $display("PASS: high-word redirect and blocked target response preserve payload");
 $display("ALL TESTS PASSED (wide_fetch_protocol)");$finish;
end
initial begin #10000;$fatal(1,"FAIL: timeout");end
endmodule
