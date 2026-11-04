`timescale 1ns/1ps
`include "defines.sv"

module tb_wide_fetch_predict;
    reg clk=0,rst=`RstEnable;
    always #5 clk=~clk;
    reg redirect_valid=0;
    reg [31:0] redirect_target=0;
    reg req_ready=0,rsp_valid=0;
    reg [63:0] rsp_data=0;
    reg [1:0] rsp_error=0;
    reg [1:0] push_ready=2;
    reg update_valid=0,update_taken=0,update_pred_taken=0,update_exception=0;
    reg update_is_call=0,update_is_ret=0;
    reg [31:0] update_pc=0,update_target=0,update_pred_target=0;
    wire req_valid,rsp_ready,q0_valid,q1_valid,q0_fault,q1_fault;
    wire [31:0] req_addr,q0_pc,q1_pc,q0_inst,q1_inst,pc_debug;
    wire q0_pred_valid,q0_pred_taken,q1_pred_valid,q1_pred_taken;
    wire [31:0] q0_pred_target,q1_pred_target;
    integer checks=0;

    wide_fetch #(.PREDICT_ENABLE(1'b1)) dut (
        .clk(clk),.rst(rst),.redirect_valid(redirect_valid),.redirect_target(redirect_target),
        .i_req_valid(req_valid),.i_req_ready(req_ready),.i_req_addr(req_addr),
        .i_rsp_valid(rsp_valid),.i_rsp_ready(rsp_ready),.i_rsp_data(rsp_data),.i_rsp_error(rsp_error),
        .push_ready(push_ready),
        .q0_valid(q0_valid),.q0_pc(q0_pc),.q0_inst(q0_inst),.q0_fault(q0_fault),
        .q1_valid(q1_valid),.q1_pc(q1_pc),.q1_inst(q1_inst),.q1_fault(q1_fault),
        .q0_pred_valid(q0_pred_valid),.q0_pred_taken(q0_pred_taken),.q0_pred_target(q0_pred_target),
        .q1_pred_valid(q1_pred_valid),.q1_pred_taken(q1_pred_taken),.q1_pred_target(q1_pred_target),
        .update_valid(update_valid),.update_pc(update_pc),.update_taken(update_taken),
        .update_target(update_target),.update_pred_taken(update_pred_taken),
        .update_pred_target(update_pred_target),.update_exception(update_exception),
        .update_is_call(update_is_call),.update_is_ret(update_is_ret),.pc_debug(pc_debug)
    );

    task check(input condition,input [8*88-1:0] label);
      begin
        checks=checks+1;
        if(condition!==1'b1) $fatal(1,"FAIL: %0s",label);
      end
    endtask

    task train(input [31:0] pc,input [31:0] target);
      begin
        @(negedge clk);
        update_valid=1;update_pc=pc;update_taken=1;update_target=target;
        update_pred_taken=0;update_pred_target=0;update_exception=0;
        update_is_call=0;update_is_ret=0;
        @(posedge clk);#1;
        @(negedge clk);update_valid=0;
      end
    endtask

    task accept_request(input [31:0] expected_addr);
      begin
        req_ready=1;#1;
        check(req_valid&&(req_addr==expected_addr),"request address matches predicted path");
        @(posedge clk);#1;
        req_ready=0;
        @(negedge clk);
      end
    endtask

    task respond(input [63:0] data);
      begin
        rsp_data=data;rsp_valid=1;#1;
        check(rsp_ready,"response accepted or drained");
        @(posedge clk);#1;
        rsp_valid=0;
        @(negedge clk);
      end
    endtask

    initial begin
      repeat(3) @(posedge clk);
      @(negedge clk);rst=`RstDisable;

      // Hold the request before handshake so the predictor can be trained.
      train(32'h00000000,32'h00000020);
      accept_request(32'h00000000);
      respond(64'h0070031306300293);
      #1;
      check(q0_valid&&q0_pc==32'h0&&q0_pred_valid&&q0_pred_taken&&
            q0_pred_target==32'h20,"slot 0 prediction metadata follows the returned block");
      check(!q1_valid&&!q1_pred_valid,"slot 0 taken prediction drops the same-block high word");
      check(req_valid&&req_addr==32'h20,"slot 0 taken prediction redirects the next request");
      accept_request(32'h20);

      // Redirect while the predicted target request is outstanding. Its old
      // response must be drained stale before the new 0x40 fetch can issue.
      @(negedge clk);req_ready=0;redirect_target=32'h40;redirect_valid=1;
      @(posedge clk);#1;
      @(negedge clk);redirect_valid=0;
      respond(64'h1111111122222222);
      check(req_valid&&req_addr==32'h40,"stale response drain leaves redirected request ready");

      // Train the high instruction of the next aligned block while request is
      // held. Both instructions must be delivered; only the following request
      // should use the slot-1 branch target.
      train(32'h00000044,32'h00000080);
      accept_request(32'h40);
      respond(64'h0070031306300293);
      #1;
      check(q0_valid&&q0_pc==32'h40,"slot 0 of the next aligned block is preserved");
      check(q1_valid&&q1_pc==32'h44&&q1_pred_valid&&q1_pred_taken&&
            q1_pred_target==32'h80,"slot 1 prediction metadata follows its instruction");
      check(req_valid&&req_addr==32'h80,"slot 1 taken prediction selects the following fetch address");

      $display("PASS: wide fetch dual predictions preserve block and PC[2] ordering (%0d checks)",checks);
      $display("ALL TESTS PASSED (wide_fetch_predict)");
      $finish;
    end
    initial begin #20000;$fatal(1,"TIMEOUT");end
endmodule
