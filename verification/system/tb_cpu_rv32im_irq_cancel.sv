`timescale 1ns/1ps
module tb_cpu_rv32im_irq_cancel;
    reg clk=0, rst=1, ext_irq=0;
    always #5 clk=~clk;
    wire iv, ir, irsp, dv, dr, dw, drsp;
    wire [31:0] ia, da, dwd, drd;
    wire [3:0] dstrb;
    reg ivld=0; reg [31:0] idata=32'h13; reg dvld=0;
    wire tv, trdwe, ttrap; wire [63:0] torder;
    wire [31:0] tpc, tinstr, trddata, tcause; wire [4:0] trd;
    function automatic [31:0] rom(input [31:0] a);
      case(a)
        32'h00:rom=32'h04000093; // addi x1,x0,64
        32'h04:rom=32'h30509073; // csrw mtvec,x1
        32'h08:rom=32'h00001137; // lui x2,1 -> 0x1000
        32'h0c:rom=32'h80010113; // addi x2,x2,-2048 -> MEIE bit 11
        32'h10:rom=32'h30411073; // csrw mie,x2 (MEIE)
        32'h14:rom=32'h30045073; // csrrsi x0,mstatus,8
        32'h18:rom=32'hff900193; // addi x3,x0,-7
        32'h1c:rom=32'h00300213; // addi x4,x0,3
        32'h20:rom=32'h0241c2b3; // div x5,x3,x4
        32'h24:rom=32'h00502023; // sw x5,0(x0)
        32'h28:rom=32'h00100313; // completion marker
        32'h2c:rom=32'h0000006f;
        32'h40:rom=32'h30200073; // mret; retries older XM PC
        default:rom=32'h00000013;
      endcase
    endfunction
    assign ir=1'b1; assign dr=1'b1; assign drd=32'b0;
    always @(posedge clk) begin
      if(rst) begin ivld<=0; idata<=32'h13; dvld<=0; end
      else begin
        ivld<=iv;
        if(iv) idata<=rom(ia);
        dvld<=dv;
      end
    end
    integer starts=0, cancels=0, divretires=0, traps=0, stores=0, retires=0;
    reg done=0, irq_sent=0;
    always @(posedge clk) if(!rst) begin
      if(dut.mdu_start) starts<=starts+1;
      if(dut.mdu_cancel) cancels<=cancels+1;
      if(dv && dw) stores<=stores+1;
      if(dut.mdu_active_q && !irq_sent) begin ext_irq<=1; irq_sent<=1; end
      if(dut.trap_commit) ext_irq<=0;
    end else begin ext_irq<=0; irq_sent<=0; end
    always @(negedge clk) if(!rst && tv && !done) begin
      retires=retires+1;
      if(ttrap) begin
        traps=traps+1;
        if(tcause!==32'h8000000b) $fatal(1,"wrong irq cause %h",tcause);
      end
      if(tpc==32'h20 && !ttrap) divretires=divretires+1;
      if(tpc==32'h28 && trdwe && trd==6) begin
        if(trddata!==1 || starts!=2 || cancels!=1 || traps!=1 || divretires!=1 || stores!=1)
          $fatal(1,"retry failure starts=%0d cancels=%0d traps=%0d div_ret=%0d stores=%0d",starts,cancels,traps,divretires,stores);
        done=1;
        $display("PASS tb_cpu_rv32im_irq_cancel starts=%0d cancels=%0d traps=%0d div_ret=%0d stores=%0d retired=%0d",starts,cancels,traps,divretires,stores,retires);
      end
    end
    cpu_core_stage1 #(.BTB_ENABLE(1'b0),.M_MODE(2)) dut(
      .clk(clk),.rst(rst),.i_req_valid(iv),.i_req_ready(ir),.i_req_addr(ia),
      .i_rsp_valid(ivld),.i_rsp_ready(irsp),.i_rsp_data(idata),.i_rsp_error(1'b0),
      .d_req_valid(dv),.d_req_ready(dr),.d_req_addr(da),.d_req_write(dw),
      .d_req_wdata(dwd),.d_req_wstrb(dstrb),.d_rsp_valid(dvld),.d_rsp_ready(drsp),
      .d_rsp_rdata(drd),.d_rsp_error(1'b0),.timer_irq_i(1'b0),.ext_irq_i(ext_irq),
      .trace_valid(tv),.trace_order(torder),.trace_pc(tpc),.trace_instr(tinstr),
      .trace_rd(trd),.trace_rd_data(trddata),.trace_rd_we(trdwe),.trace_trap(ttrap),.trace_cause(tcause));
    initial begin
      repeat(5) @(posedge clk); rst=0;
      repeat(2000) begin @(negedge clk); if(done) begin $display("ALL TESTS PASSED"); $finish; end end
      $fatal(1,"timeout starts=%0d cancels=%0d traps=%0d divret=%0d",starts,cancels,traps,divretires);
    end
endmodule
