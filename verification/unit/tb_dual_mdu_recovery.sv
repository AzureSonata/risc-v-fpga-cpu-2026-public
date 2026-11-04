`timescale 1ns/1ps
module dual_mdu_recovery_case #(parameter RESET_CASE=0)(output reg done=0);
reg clk=0,rst=1,irq=0;always #5 clk=~clk;
reg rsp=0;reg [63:0] data=0;wire req,ready,rsp_ready;wire [31:0]addr;
reg [31:0]prog[0:255];integer i,trap_count=0,mret=0;
wire tv,tt;wire [31:0] ins;
assign ready=!rsp || rsp_ready;
always @(posedge clk) begin
 if(rst)rsp<=0;
 else if(req&&ready)begin rsp<=1;data<={prog[addr[9:2]+1],prog[addr[9:2]]};end
 else if(rsp&&rsp_ready)rsp<=0;
end
always @(posedge clk)begin
 if(rst)begin trap_count=0;mret=0;end
 else if(tv)begin
  if(tt)begin trap_count=trap_count+1;irq=0;end
  else if(ins[6:0]==7'h33 && ins[31:25]==1)mret=mret+1;
 end
end
dual_issue_full_core dut(.clk(clk),.rst(rst),.i_req_valid(req),.i_req_ready(ready),.i_req_addr(addr),
.i_rsp_valid(rsp),.i_rsp_ready(rsp_ready),.i_rsp_data(data),.i_rsp_error(2'b00),
.d_req_valid(),.d_req_ready(1'b1),.d_req_addr(),.d_req_write(),.d_req_wdata(),.d_req_wstrb(),
.d_rsp_valid(1'b0),.d_rsp_ready(),.d_rsp_rdata(32'b0),.d_rsp_error(1'b0),
.timer_irq_i(irq),.ext_irq_i(1'b0),.trace0_valid(tv),.trace0_trap(tt),.trace0_instr(ins));
initial begin
 for(i=0;i<256;i=i+1)prog[i]=32'h00000013;
 prog[0]=32'h10000613;prog[1]=32'h30561073;
 prog[2]=32'h08000613;prog[3]=32'h30461073;
 prog[4]=32'h00800613;prog[5]=32'h30061073;
 prog[6]=32'hff900093;prog[7]=32'h00300113;
 prog[8]=32'h0220c1b3;prog[9]=32'h00118213;prog[10]=32'h0000006f;
 prog[64]=32'h30401073;prog[65]=32'h30200073;
 repeat(3)@(negedge clk);rst=0;
 wait(dut.mdu_pending_q);@(negedge clk);
 if(RESET_CASE)begin
  rst=1;prog[6]=32'h00700093;repeat(3)@(negedge clk);rst=0;
 end else irq=1;
 repeat(350)@(negedge clk);
 if(mret!=1 || dut.mdu_pending_q || dut.u_rf.regs[3]!==((RESET_CASE)?2:32'hfffffffe) ||
    dut.u_rf.regs[4]!==((RESET_CASE)?3:32'hffffffff))
  $fatal(1,"FAIL: MDU recovery case=%0d retired=%0d x3=%h x4=%h",RESET_CASE,mret,dut.u_rf.regs[3],dut.u_rf.regs[4]);
 if(!RESET_CASE && (trap_count!=1 || dut.u_csr.mcause!==32'h80000007 || dut.u_csr.mepc!==32'h20))
  $fatal(1,"FAIL: MDU IRQ precise replay");
 $display("PASS: MDU recovery reset=%0d, no ghost write or duplicate retirement",RESET_CASE);done=1;
end
endmodule
module tb_dual_mdu_recovery;
wire a,b;
dual_mdu_recovery_case #(0) c(a);dual_mdu_recovery_case #(1) d(b);
initial begin wait(a&&b);$display("ALL TESTS PASSED (dual_mdu_recovery)");$finish;end
initial begin #10000;$fatal(1,"FAIL: MDU recovery timeout");end
endmodule
