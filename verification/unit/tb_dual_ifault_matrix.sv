`timescale 1ns/1ps
module dual_ifault_case #(parameter C=0)(output reg done=0);
reg clk=0,rst=1;always #5 clk=~clk;
reg rsp=0;reg [63:0] data=0;reg [1:0] error=0;
wire req,ready,rsp_ready;wire [31:0] addr;
reg [31:0] prog[0:255];integer i,traps=0;
wire tv,tt;
assign ready=!rsp || rsp_ready;
always @(posedge clk) begin
 if(rst) begin rsp<=0;error<=0;end
 else if(req&&ready) begin
  rsp<=1; data<={prog[addr[9:2]+1],prog[addr[9:2]]};
  error <= addr==8 ? ((C==1)?2'b10:(C==2)?2'b11:(C==4)?2'b00:2'b01):0;
 end else if(rsp&&rsp_ready) rsp<=0;
end
always @(posedge clk) if(tv&&tt) traps=traps+1;
dual_issue_full_core dut(.clk(clk),.rst(rst),.i_req_valid(req),.i_req_ready(ready),
.i_req_addr(addr),.i_rsp_valid(rsp),.i_rsp_ready(rsp_ready),.i_rsp_data(data),.i_rsp_error(error),
.d_req_valid(),.d_req_ready(1'b1),.d_req_addr(),.d_req_write(),.d_req_wdata(),.d_req_wstrb(),
.d_rsp_valid(1'b0),.d_rsp_ready(),.d_rsp_rdata(32'b0),.d_rsp_error(1'b0),
.timer_irq_i(1'b0),.ext_irq_i(1'b0),.trace0_valid(tv),.trace0_trap(tt));
initial begin
 for(i=0;i<256;i=i+1)prog[i]=32'h00000013;
 prog[0]=32'h10000613; prog[1]=32'h30561073;
 prog[2]=32'h06300293; prog[3]=32'h00700313;prog[4]=32'h0000006f;
 prog[64]=32'h0000006f;
 if(C==3)prog[0]=32'h00c0006f;
 if(C==4)prog[2]=32'h002002ef;
 repeat(3)@(negedge clk);rst=0;
 repeat(150)@(negedge clk);
 if(C==3)begin
  if(traps!=0 || dut.u_rf.regs[5]!==0 || dut.u_rf.regs[6]!==7)
   $fatal(1,"FAIL: skipped low-word fault leaked");
 end else if(C==4)begin
  if(traps!=1 || dut.u_csr.mcause!==0 || dut.u_csr.mepc!==8 ||
     dut.u_csr.mtval!==10 || dut.u_rf.regs[5]!==0)
   $fatal(1,"FAIL: misaligned JAL precise trap/link suppression");
 end else begin
  if(traps!=1 || dut.u_csr.mcause!==1 ||
     dut.u_csr.mepc!==((C==1)?12:8) || dut.u_csr.mtval!==((C==1)?12:8) ||
     dut.u_rf.regs[5]!==((C==1)?99:0) || dut.u_rf.regs[6]!==0)
   $fatal(1,"FAIL: per-word fetch fault C=%0d mepc=%h",C,dut.u_csr.mepc);
 end
 $display("PASS: fetch/target error C=%0d exact trap and suppressed side effects",C);done=1;
end
endmodule
module tb_dual_ifault_matrix;
wire [4:0] done;
dual_ifault_case #(0) a(done[0]);dual_ifault_case #(1) b(done[1]);
dual_ifault_case #(2) c(done[2]);dual_ifault_case #(3) d(done[3]);dual_ifault_case #(4) e(done[4]);
initial begin wait(&done);$display("ALL TESTS PASSED (dual_ifault_matrix)");$finish;end
initial begin #5000;$fatal(1,"FAIL: timeout");end
endmodule
