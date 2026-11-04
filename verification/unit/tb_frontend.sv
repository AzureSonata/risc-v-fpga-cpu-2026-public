// ============================================================================
//        前端联合测试 — pc_reg + if_stage + if_id + id_stage
//        验证完整 IF→ID 流水线通路（不依赖精确 PC 序列）
// ============================================================================

`timescale 1ns / 1ps

`include "defines.sv"

module tb_frontend;

    reg         clk;
    reg         rst;

    reg         redirect_valid;
    reg [31:0]  redirect_target;
    reg         hold_pc;
    reg         hold_if;
    reg         hold_if_id;
    reg         exc_flush;

    reg         i_req_ready;
    reg         i_rsp_valid;
    reg  [31:0] i_rsp_data;
    reg         i_rsp_error;

    wire [31:0] pc;
    wire        i_req_valid;
    wire [31:0] i_req_addr;
    wire        i_rsp_ready;
    wire        advance_valid;

    wire        if_out_valid;
    reg         if_out_ready;
    wire        if_out_fault;
    wire [31:0] if_out_pc;
    wire [31:0] if_out_inst;

    wire        id_valid;
    wire [31:0] id_pc;
    wire [31:0] id_inst;

    wire [6:0]  opcode;
    wire [4:0]  rd;
    wire [31:0] imm;
    wire        reg_we, branch, jal, jalr, lui, auipc;

    wire flush_if_id = exc_flush;
    wire flush_if    = exc_flush;

    // ==================================================================
    // 模块例化
    // ==================================================================
    pc_reg u_pc_reg (
        .clk             (clk), .rst (rst),
        .redirect_valid  (redirect_valid), .redirect_target (redirect_target),
        .advance_valid   (advance_valid),
        .pred_valid(1'b0), .pred_target(32'b0),
        .hold_pc         (hold_pc), .pc (pc)
    );

        if_stage u_if_stage (
            .pred_hit_i(1'b0), .pred_taken_i(1'b0), .pred_target_i(32'b0),
        .clk (clk), .rst (rst),
        .pc (pc), .redirect_valid (redirect_valid),
        .hold_if (hold_if), .flush_if (flush_if),
        .i_req_valid (i_req_valid), .i_req_ready (i_req_ready),
        .i_req_addr (i_req_addr),
        .advance_valid (advance_valid),
        .i_rsp_valid (i_rsp_valid), .i_rsp_ready (i_rsp_ready),
        .i_rsp_data (i_rsp_data), .i_rsp_error (i_rsp_error),
        .if_out_valid (if_out_valid), .if_out_ready (if_out_ready),
        .if_out_pc (if_out_pc), .if_out_inst (if_out_inst),
        .if_out_fault (if_out_fault)
    );

            if_id u_if_id (
        .clk (clk), .rst (rst),
        .if_valid_i (if_out_valid), .if_pc_i (if_out_pc),
        .if_inst_i (if_out_inst), .if_fault_i (if_out_fault),
        .if_pred_valid_i (1'b0), .if_pred_taken_i (1'b0),
        .if_pred_target_i (32'h0),
        .hold_if_id (hold_if_id), .flush_if_id (flush_if_id),
        .id_valid_o (id_valid), .id_pc_o (id_pc),
        .id_inst_o (id_inst), .id_fault_o ()
    );

        id_stage u_id_stage (
        .rst (rst), .inst_i (id_inst), .pc_i (id_pc),
        .inst_valid_i (id_valid),
        .fault_i (1'b0),
        .pred_valid_i (1'b0), .pred_taken_i (1'b0),
        .pred_target_i (32'h0),
        .ex_jump_flag_i (1'b0),
        .rs1_addr_o (), .rs2_addr_o (), .imm_o (imm),
        .reg_we_o (reg_we), .rd_addr_o (rd), .mem_req_o (),
        .mem_we_o (), .mem_wstrb_o (), .branch_o (branch),
        .jal_o (jal), .jalr_o (jalr), .lui_o (lui),
        .auipc_o (auipc), .uses_rs1_o (), .uses_rs2_o (),
        .opcode_o (opcode), .funct3_o (), .funct7_o (),
        .rd_o (rd), .pred_valid_o (), .pred_taken_o (),
        .pred_target_o (), .illegal_instr_o ()
    );

    always #5 clk = ~clk;

    integer cycle;
    always @(posedge clk) cycle <= cycle + 1;

    integer errors;

    task check;
        input [8*32:0] label;
        input condition;
        begin
            if (!condition) begin $display("FAIL [%0d] %s", cycle, label); errors=errors+1; end
            else $display("PASS [%0d] %s", cycle, label);
        end
    endtask

    task tic;
        begin @(posedge clk); #1; end
    endtask

    // 完成一笔取指：调用时 if_stage 须在 REQ 态
    task fetch_rsp;
        input [31:0] data;
        begin
            i_req_ready = 1'b1;
            tic();                  // REQ→WAIT_RSP
            i_req_ready = 1'b0;
            tic();                  // wait
            i_rsp_valid = 1'b1;
            i_rsp_data  = data;
             i_rsp_error = 1'b0;
            tic();                  // rsp received
            i_rsp_valid = 1'b0;
        end
    endtask

    initial begin
        $display("==============================================");
        $display("  Frontend Integration Test");
        $display("==============================================");
        errors = 0; cycle = 0; clk = 0;
        rst = `RstEnable;
        redirect_valid = 0; redirect_target = 0;
        hold_pc = 0; hold_if = 0; hold_if_id = 0; exc_flush = 0;
        i_req_ready = 0; i_rsp_valid = 0; i_rsp_data = 0; i_rsp_error = 0;

        repeat (3) @(posedge clk);
        @(negedge clk); rst = `RstDisable;

        // ============================================================
        // Test 1: 基本流水线 — PC=0 取指 → IF/ID → 译码
        // ============================================================
        $display("\n=== Test 1: Basic pipeline ===");
        tic();                      // IDLE→REQ for PC=0
        fetch_rsp(32'h00001000);    // complete fetch
        tic();                      // IF/ID captures

        check("id_valid=1", id_valid===1'b1);
        check("id_inst valid", id_inst===32'h00001000);
        $display("Test 1: OK (id_inst=%08h)", id_inst);

        // ============================================================
        // Test 2: Hold 冻结流水线
        // ============================================================
        $display("\n=== Test 2: Hold ===");
        hold_pc = 1; hold_if = 1; hold_if_id = 1;
        repeat (3) tic();
        check("id_valid held", id_valid===1'b1);
        check("id_inst held", id_inst===32'h00001000);
        // release
        hold_pc = 0; hold_if = 0; hold_if_id = 0;
        $display("Test 2: OK");

        // ============================================================
        // Test 3: Flush 冲刷 IF/ID
        // ============================================================
        $display("\n=== Test 3: Flush ===");
        exc_flush = 1;
        tic();
        exc_flush = 0;
        check("id_valid=0 after flush", id_valid===1'b0);
        $display("Test 3: OK");

        // ============================================================
        // Test 4: 重定向 redirect
        // ============================================================
        $display("\n=== Test 4: Redirect ===");
        // After flush, if_stage may have stale pending req
        // Use redirect to restart IF from known PC
        redirect_target = 32'h00004000;
        redirect_valid  = 1;
        exc_flush       = 1;       // also flush
        tic();                      // redirect epoch++, FLUSH, state→IDLE
        redirect_valid = 0;
        exc_flush = 0;
        check("PC=0x4000", pc===32'h00004000);
        check("id_valid=0", id_valid===1'b0);

        // IDLE will send new request on next posedge
        tic();                      // IDLE→REQ for PC=0x4000

        fetch_rsp(32'h00005000);
        tic();                      // IF/ID captures

        check("decoded valid", id_valid===1'b1);
        check("decoded inst=0x5000", id_inst===32'h00005000);
        $display("Test 4: OK");

        // ============================================================
        // Test 5: 陈旧 epoch 丢弃
        // ============================================================
        $display("\n=== Test 5: Stale epoch discard ===");
        // Send a new request but delay response
        // Meanwhile redirect → epoch++ → old rsp discarded
        i_req_ready = 1;
        tic();                      // REQ→WAIT_RSP
        i_req_ready = 0;
        tic();                      // wait

        // Redirect while request pending
        redirect_target = 32'h0000A000;
        redirect_valid  = 1;
        exc_flush       = 1;
        tic();                      // epoch++
        redirect_valid = 0;
        exc_flush = 0;
        check("PC=0xA000", pc===32'h0000A000);

        // Return old response (epoch-1)
        i_rsp_valid = 1;
        i_rsp_data  = 32'hDEADBEEF;
        i_rsp_error = 0;
        tic();
        i_rsp_valid = 0;

        check("stale rsp discarded", if_out_valid===1'b0);

        // Now fetch from 0xA000
        tic();                      // IDLE→REQ for PC=0xA000

        fetch_rsp(32'h0000B000);
        tic();
        check("decoded inst=0xB000", id_inst===32'h0000B000);
        $display("Test 5: OK");

        // ============================================================
        $display("\n==============================================");
        if (errors==0) $display("  🎉 ALL INTEGRATION TESTS PASSED");
        else           $display("  ⚠️  %0d FAILURES", errors);
        $display("==============================================");
        $finish;
    end

    initial begin #3000; $display("TIMEOUT"); $finish; end
    initial begin $dumpfile("build/tb_frontend.vcd"); $dumpvars(0, tb_frontend); end
endmodule