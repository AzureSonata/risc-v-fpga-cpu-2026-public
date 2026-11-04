// ============================================================================
//        IF 阶段 — 单元测试（简化版，直接驱动端口）
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_if_stage;

    reg         clk;
    reg         rst;
    reg  [31:0] pc;
    reg         redirect_valid;
    reg         hold_if;
    reg         flush_if;

    // IF 请求（DUT 输出 → 我们监控）
    wire        i_req_valid;
    reg         i_req_ready;
    wire [31:0] i_req_addr;

    // IF 响应（我们驱动 → DUT 输入）
    reg         i_rsp_valid;
    wire        i_rsp_ready;    // DUT 输出，always-ready
    reg  [31:0] i_rsp_data;
    reg         i_rsp_error;
    reg  [1:0]  i_rsp_epoch;

    // DUT 输出到 IF/ID
    wire        if_out_valid;
    reg         if_out_ready;
    wire [31:0] if_out_pc;
    wire [31:0] if_out_inst;
    wire        if_out_fault;

    if_stage u_if_stage (
        .pred_hit_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'b0),
        .clk            (clk),
        .rst            (rst),
        .pc             (pc),
        .redirect_valid (redirect_valid),
        .hold_if        (hold_if),
        .flush_if       (flush_if),
        .i_req_valid    (i_req_valid),
        .i_req_ready    (i_req_ready),
        .i_req_addr     (i_req_addr),

        .i_rsp_valid    (i_rsp_valid),
        .i_rsp_ready    (i_rsp_ready),
        .i_rsp_data     (i_rsp_data),
        .i_rsp_error    (i_rsp_error),

        .if_out_valid   (if_out_valid),
        .if_out_ready  (if_out_ready),
        .if_out_pc      (if_out_pc),
        .if_out_inst    (if_out_inst),
        .if_out_fault   (if_out_fault)
    );

    always #5 clk = ~clk;

    integer errors;
    integer cycle_cnt;

    // 同步驱动：在 posedge 之后设置响应
    task drive_rsp;
        input [31:0] data;
        input [1:0] epoch;
        begin
            i_rsp_valid <= 1;
            i_rsp_data <= data;
            i_rsp_epoch <= epoch;
            i_rsp_error <= 0;
        end
    endtask

    task clear_rsp;
        begin
            i_rsp_valid <= 0;
        end
    endtask

    initial begin
        $display("==========================================");
        $display("  IF Stage Unit Test (Direct Drive)");
        $display("==========================================");
        errors = 0;
        cycle_cnt = 0;
        clk = 0;
        rst = `RstEnable;
        pc = 32'h0;
        redirect_valid = `False;
        hold_if = `False;
        flush_if = `False;
        i_req_ready = 1'b0;
        i_rsp_valid = 1'b0;
        i_rsp_data = 32'h0;
        i_rsp_error = 1'b0;
        i_rsp_epoch = 2'b0;

        // ==========================================================
        // Test 1: Reset — IF stage should start requesting immediately
        // ==========================================================
        @(negedge clk);
        rst = `RstDisable;
        if_out_ready = `True;
        @(posedge clk); #1;
        // IF stage exits reset and sends first request for PC=0
        if (i_req_valid !== 1'b1) begin
            $display("FAIL Test 1: no request after reset");
            errors = errors + 1;
        end else $display("PASS Test 1: requesting PC=0 after reset");

        // ==========================================================
        // Test 2: Verify request address and epoch
        // ==========================================================
        @(posedge clk); #1;
        if (i_req_addr !== 32'h00000000)
            begin $display("FAIL Test 2a: addr=%08h", i_req_addr); errors=errors+1; end
        else $display("PASS Test 2: req PC=%08h", i_req_addr);

        // ==========================================================
        // Test 3: Accept request, return response, set up next PC
        // ==========================================================
        // Accept the request
        i_req_ready = 1'b1;
        @(posedge clk); #1;
        i_req_ready = 1'b0;

        // Return response for this request
        // ALSO set pc to 4 BEFORE the posedge where if_stage reads it
        drive_rsp(32'h00001000, u_if_stage.req_epoch);
        pc = 32'h00000004;  // Update pc for next request (read on this posedge)
        @(posedge clk); #1;
        clear_rsp();

        // Check that response was received
        if (if_out_valid !== 1'b1)
            begin $display("FAIL Test 3a: if_out_valid=%b", if_out_valid); errors=errors+1; end
        else if (if_out_pc !== 32'h00000000)
            begin $display("FAIL Test 3b: if_out_pc=%08h", if_out_pc); errors=errors+1; end
        else $display("PASS Test 3: response PC=0 inst=%08h", if_out_inst);

        // ==========================================================
        // Test 4: Sequential request uses updated PC
        // ==========================================================
        // After processing response, if_stage should have sent next req for PC=4
        #1;
        if (i_req_valid !== 1'b1)
            begin $display("FAIL Test 4a: no next req (valid=%b)", i_req_valid); errors=errors+1; end
        else if (i_req_addr !== 32'h00000004)
            begin $display("FAIL Test 4b: next addr=%08h (expected 4)", i_req_addr); errors=errors+1; end
        else $display("PASS Test 4: next req for PC=4");

        // Accept and respond for PC=4
        i_req_ready = 1'b1;
        @(posedge clk); #1;
        i_req_ready = 1'b0;
        drive_rsp(32'h00001004, u_if_stage.req_epoch);
        @(posedge clk); #1;
        clear_rsp();

        if (if_out_valid !== 1'b1 || if_out_pc !== 32'h00000004)
            begin $display("FAIL Test 4c: response if_out_pc=%08h", if_out_pc); errors=errors+1; end
        else $display("PASS Test 4c: seq response PC=4 inst=%08h", if_out_inst);

        // ==========================================================
        // Test 5: Hold
        // ==========================================================
        // Continue sequence: request for PC=8
        pc = 32'h00000008;
        @(posedge clk); #1;
        // Now hold
        hold_if = `True;
        i_req_ready = 1'b1;
        @(posedge clk); #1;
        i_req_ready = 1'b0;
        // Return response, but hold is set → should not send next request
        drive_rsp(32'h00001008, u_if_stage.req_epoch);
        @(posedge clk); #1;
        clear_rsp();

        // Response received, but hold prevents new request
        if (i_req_valid !== 1'b0)
            begin $display("FAIL Test 5a: req during hold"); errors=errors+1; end
        else $display("PASS Test 5: hold suppressed next request");

        // Release hold
        hold_if = `False;
        @(posedge clk); #1;
        if (i_req_valid !== 1'b1)
            begin $display("FAIL Test 5b: no req after hold release"); errors=errors+1; end
        else $display("PASS Test 5b: req after hold release");

        // ==========================================================
        // Test 6: Redirect
        // ==========================================================
        // Accept current request
        i_req_ready = 1'b1;
        @(posedge clk); #1;
        i_req_ready = 1'b0;

        // Return response
        drive_rsp(32'h0000100c, u_if_stage.req_epoch);
        @(posedge clk); #1;
        clear_rsp();

        // Now send redirect while next request is pending
        pc = 32'h00002000;  // redirect target
        @(posedge clk); #1;

        // Let request go out for PC=8
        i_req_ready = 1'b1;
        @(posedge clk); #1;
        i_req_ready = 1'b0;

        // Redirect!
        redirect_valid = `True;
        // Also update pc to redirect target
        @(posedge clk); #1;
        redirect_valid = `False;

        // The epoch should have incremented, so the pending response
        // (from the old PC=8 request) will be stale
        drive_rsp(32'hDEAD, u_if_stage.req_epoch - 2'b1);  // WRONG epoch (stale)
        @(posedge clk); #1;
        clear_rsp();

        // The stale response should be dropped
        if (if_out_valid !== 1'b0)
            begin $display("FAIL Test 6a: accepted stale response"); errors=errors+1; end
        else $display("PASS Test 6a: stale response dropped (epoch mismatch)");

        // New request should go out for redirect target
        @(posedge clk); #1;
        if (i_req_valid !== 1'b1)
            begin $display("FAIL Test 6b: no req after redirect"); errors=errors+1; end
        else if (i_req_addr !== 32'h00002000)
            begin $display("FAIL Test 6c: redirect addr=%08h (expected 00002000)", i_req_addr); errors=errors+1; end
        else $display("PASS Test 6b: redirect request for PC=00002000");

        // ==========================================================
        // Summary
        // ==========================================================
        $display("==========================================");
        if (errors == 0) $display("  ALL TESTS PASSED");
        else $display("  %0d TEST(S) FAILED", errors);
        $display("==========================================");
        $finish;
    end

    initial begin
        #1000;
        $display("TIMEOUT");
        $finish;
    end

    initial begin
        $dumpfile("build/tb_if_stage.vcd");
        $dumpvars(0, tb_if_stage);
    end

endmodule