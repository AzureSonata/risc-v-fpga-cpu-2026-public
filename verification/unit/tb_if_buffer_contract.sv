`timescale 1ns/1ps
`include "defines.sv"

module tb_if_buffer_contract;
    reg clk = 0;
    reg rst = 1;
    reg [31:0] pc = 0;
    reg redirect_valid = 0;
    reg hold_if = 0;
    reg flush_if = 0;
    wire i_req_valid;
    reg i_req_ready = 0;
    wire [31:0] i_req_addr;
    wire advance_valid;
    reg i_rsp_valid = 0;
    wire i_rsp_ready;
    reg [31:0] i_rsp_data = 0;
    reg i_rsp_error = 0;
    wire if_out_valid;
    reg if_out_ready = 0;
    wire [31:0] if_out_pc, if_out_inst;
    wire if_out_fault;
    integer errors = 0;
    integer captures = 0;
    reg [31:0] captured_pc [0:2];
    reg [31:0] captured_inst [0:2];

    always #5 clk = ~clk;

    if_stage dut (
        .pred_hit_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'b0),
        .clk(clk), .rst(rst), .pc(pc), .redirect_valid(redirect_valid),
        .hold_if(hold_if), .flush_if(flush_if),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .advance_valid(advance_valid),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .if_out_valid(if_out_valid), .if_out_ready(if_out_ready),
        .if_out_pc(if_out_pc), .if_out_inst(if_out_inst),
        .if_out_fault(if_out_fault)
    );

    // Sample the payload accepted by the consumer before NBA updates.
    always @(posedge clk) begin
        if (!rst && if_out_valid && if_out_ready) begin
            captured_pc[captures] = if_out_pc;
            captured_inst[captures] = if_out_inst;
            captures = captures + 1;
        end
    end

    task check;
        input condition;
        input [8*100-1:0] label;
        begin
            if (!condition) begin
                $display("FAIL: %0s", label);
                errors = errors + 1;
            end else begin
                $display("PASS: %0s", label);
            end
        end
    endtask

    task accept_request;
        input [31:0] expected_addr;
        integer cycles;
        begin
            cycles = 0;
            while ((i_req_valid !== 1'b1 || i_req_addr !== expected_addr) && cycles < 20) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            check(i_req_valid === 1'b1 && i_req_addr === expected_addr,
                  "expected instruction request is presented");
            i_req_ready = 1;
            @(posedge clk); #1;
            @(negedge clk); i_req_ready = 0;
        end
    endtask

    task return_response;
        input [31:0] inst;
        begin
            check(i_rsp_ready === 1'b1, "response receiver is ready");
            i_rsp_valid = 1;
            i_rsp_data = inst;
            i_rsp_error = 0;
            @(posedge clk); #1;
            @(negedge clk); i_rsp_valid = 0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        check(i_req_valid === 1'b0 && if_out_valid === 1'b0,
              "synchronous active-high reset initializes IF outputs");
        rst = 0;

        // Hold P1 at the output, put P2 in the skid buffer, then make P3
        // ready on the same edge that P2 is promoted. P2 must not be lost.
        accept_request(32'h0);
        @(negedge clk); if_out_ready = 0; pc = 32'h4;
        return_response(32'h1111_1111);
        accept_request(32'h4);
        @(negedge clk); pc = 32'h8;
        return_response(32'h2222_2222);
        accept_request(32'h8);

        @(negedge clk);
        i_rsp_valid = 1;
        i_rsp_data = 32'h3333_3333;
        check(i_rsp_ready === 1'b0, "full skid buffer backpressures P3");
        @(posedge clk); #1;
        @(negedge clk);
        if_out_ready = 1;
        #1;
        check(i_rsp_ready === 1'b1, "P3 becomes ready as P1 leaves output");
        @(posedge clk); #1;
        check(if_out_valid === 1'b1 && if_out_pc === 32'h4 &&
              if_out_inst === 32'h2222_2222 && dut.buf_valid === 1'b1 &&
              dut.buf_pc === 32'h8 && dut.buf_inst === 32'h3333_3333,
              "P2 promotion and P3 buffering coexist without overwrite");
        @(negedge clk); i_rsp_valid = 0;
        @(posedge clk); #1;
        check(if_out_valid === 1'b1 && if_out_pc === 32'h8 &&
              if_out_inst === 32'h3333_3333,
              "P3 follows P2 in order");
        @(posedge clk); #1;
        check(captures === 3 && captured_pc[0] === 32'h0 &&
              captured_pc[1] === 32'h4 && captured_pc[2] === 32'h8 &&
              captured_inst[0] === 32'h1111_1111 &&
              captured_inst[1] === 32'h2222_2222 &&
              captured_inst[2] === 32'h3333_3333,
              "three accepted payloads are delivered exactly once in order");

        // Gate #3 boundary: assert downstream hold on the same cycle as the
        // outstanding fetch response. The accepted response must remain held
        // intact at the IF output and must not trigger a subsequent request.
        @(negedge clk);
        rst = 1;
        hold_if = 0;
        if_out_ready = 0;
        i_req_ready = 0;
        i_rsp_valid = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 0;
        pc = 32'h100;
        accept_request(32'h100);

        @(negedge clk);
        hold_if = 1;
        i_rsp_valid = 1;
        i_rsp_data = 32'hA55A_1234;
        i_rsp_error = 0;
        check(i_rsp_ready === 1'b1, "same-cycle hold/response is accepted");
        @(posedge clk); #1;
        check(if_out_valid === 1'b1 && if_out_pc === 32'h100 &&
              if_out_inst === 32'hA55A_1234 && if_out_fault === 1'b0,
              "response payload survives hold asserted on its handshake");
        check(i_req_valid === 1'b0,
              "same-cycle hold prevents issuing the following request");
        @(negedge clk);
        i_rsp_valid = 0;
        repeat (2) @(posedge clk); #1;
        check(if_out_valid === 1'b1 && if_out_pc === 32'h100 &&
              if_out_inst === 32'hA55A_1234,
              "held response remains stable until downstream release");

        if (errors == 0) begin
            $display("ALL IF BUFFER CONTRACT TESTS PASSED");
            $finish;
        end else begin
            $fatal(1, "%0d IF buffer contract test(s) failed", errors);
        end
    end

    initial begin
        #2000;
        $fatal(1, "TIMEOUT");
    end
endmodule
