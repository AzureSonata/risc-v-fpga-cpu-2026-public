`timescale 1ns/1ps
`include "defines.sv"
module dual_mdu_case #(parameter MODE=2, parameter DUAL=1)(output reg done=0);
reg clk=0,rst=1;always #5 clk=~clk;
wire req,ready,rsp_ready;wire [31:0] addr;
reg rsp=0;reg [63:0] data=0;reg [31:0] prog[0:255];
wire tv,trap;wire [31:0] instr;integer i,mret=0;
assign ready=!rsp || rsp_ready;
always @(posedge clk) begin
 if(rst) rsp<=0;
 else if(req&&ready) begin rsp<=1;data<={prog[addr[9:2]+1],prog[addr[9:2]]};end
 else if(rsp&&rsp_ready) rsp<=0;
end
wire [31:0] trace_pc;
dual_issue_full_core #(.M_MODE(MODE),.DUAL_ISSUE_EN(DUAL)) dut(
.clk(clk),.rst(rst),.i_req_valid(req),.i_req_ready(ready),.i_req_addr(addr),
.i_rsp_valid(rsp),.i_rsp_ready(rsp_ready),.i_rsp_data(data), .i_rsp_error(2'b00),
.d_req_valid(),.d_req_ready(1'b1),.d_req_addr(),.d_req_write(),.d_req_wdata(),.d_req_wstrb(),
.d_rsp_valid(1'b0),.d_rsp_ready(),.d_rsp_rdata(32'b0),.d_rsp_error(1'b0),
.timer_irq_i(1'b0),.ext_irq_i(1'b0),.trace0_valid(tv),.trace0_instr(instr),
.trace0_trap(trap),.trace0_pc(trace_pc));
always @(posedge clk) if(tv&&!trap&&instr[6:0]==7'h33&&instr[31:25]==7'h01) mret=mret+1;
initial begin
 for(i=0;i<256;i=i+1)prog[i]=32'h00000013;
 prog[0]=32'h10000613;
 prog[1]=32'h30561073;
 prog[2]=32'hff900093;
 prog[3]=32'h00300113;
 prog[4]=32'h022081b3;
 prog[5]=32'h02209233;
 prog[6]=32'h0220a2b3;
 prog[7]=32'h0220b333;
 prog[8]=32'h0220c3b3;
 prog[9]=32'h0220d433;
 prog[10]=32'h0220e4b3;
 prog[11]=32'h0220f533;
 prog[12]=32'h00118593;
 prog[13]=32'h02208033;
 prog[14]=32'h0000006f;
 prog[64]=32'h0000006f;
 repeat(3)@(negedge clk);rst=0;
 repeat(900)@(negedge clk);
 if(MODE==0) begin
  if(dut.u_csr.mcause!==2 || dut.u_csr.mepc!==32'h10 || mret!=0)
   $fatal(1,"FAIL: RV32I disabled-extension trap mode=%0d",MODE);
 end else begin
  if(dut.u_rf.regs[3]!==32'hffffffeb || dut.u_rf.regs[4]!==32'hffffffff ||
     dut.u_rf.regs[5]!==32'hffffffff || dut.u_rf.regs[6]!==2)
   $fatal(1,"FAIL: MUL family mode=%0d dual=%0d",MODE,DUAL);
  if(MODE==1) begin
   if(dut.u_csr.mcause!==2 || dut.u_csr.mepc!==32'h20 || mret!=4)
    $fatal(1,"FAIL: Zmmul DIV trap mret=%0d mepc=%h",mret,dut.u_csr.mepc);
  end else begin
   if(dut.u_rf.regs[7]!==32'hfffffffe || dut.u_rf.regs[8]!==32'h55555553 ||
      dut.u_rf.regs[9]!==32'hffffffff || dut.u_rf.regs[10]!==0 ||
      dut.u_rf.regs[11]!==32'hffffffec || mret!=9 || dut.u_rf.regs[0]!==0)
    $fatal(1,"FAIL: DIV/REM/dependent consumer/retirement count mret=%0d",mret);
  end
 end
 $display("PASS: M_MODE=%0d dual=%0d arithmetic/dependency/x0/trap and once-only retirement",MODE,DUAL);
 done=1;
end
endmodule
module tb_dual_mdu_matrix;
wire [5:0] done;
dual_mdu_case #(0,0) a(done[0]);dual_mdu_case #(0,1) b(done[1]);
dual_mdu_case #(1,0) c(done[2]);dual_mdu_case #(1,1) d(done[3]);
dual_mdu_case #(2,0) e(done[4]);dual_mdu_case #(2,1) f(done[5]);
initial begin wait(&done);$display("ALL TESTS PASSED (dual_mdu_matrix)");$finish;end
initial begin #20000;$fatal(1,"FAIL: MDU timeout");end
endmodule
