`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_full_load_alu;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    wire i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg i_rsp_valid_q = 1'b0;
    reg [63:0] i_rsp_data_q = 64'h0;
    wire d_req_valid, d_req_ready, d_req_write, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0] d_req_wstrb;
    reg d_rsp_valid_q = 1'b0;
    reg [31:0] d_rsp_rdata_q = 32'h0;
    reg d_rsp_error_q = 1'b0;
    wire d_rsp_error;
    reg fault_sram = 1'b0;
    wire issue0, issue1, retire0_valid, retire1_valid;
    wire trace0_valid, trace1_valid, trace0_trap;
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] trace0_pc, trace1_pc, trace0_cause;
    wire [31:0] trace0_instr, trace1_instr, trace0_rd_data, trace1_rd_data;
    wire [4:0] trace0_rd, trace1_rd;
    wire trace0_rd_we, trace1_rd_we;

    reg [31:0] prog [0:63];
    reg [63:0] imem [0:63];
    reg [31:0] dmem [0:1023];
    reg d_pending = 1'b0;
    integer d_wait = 0;
    integer d_wait_config = 5;
    integer i;
    integer pair_load_seen = 0;
    integer bad_load_use_pair = 0;
    integer bad_mmio_pair = 0;
    integer bad_store_pair = 0;
    integer cacheable_store_pair_seen = 0;
    integer cacheable_store_pair_retired = 0;
    integer mmio_store_pair_seen = 0;
    integer load_pair_retired = 0;
    integer load_fault_trap_seen = 0;
    integer load_fault_bypass_seen = 0;
    integer young_load_pair_retired = 0;
    integer store_count = 0;
    integer mmio_store_count = 0;
    integer success_ok = 0;
    integer boundary_byte_pair = 0;
    integer boundary_half_pair = 0;
    integer boundary_word_pair = 0;
    integer boundary_outside_pair = 0;
    integer boundary_ok = 0;
    integer cross_enter_low_pair = 0;
    integer cross_enter_high_pair = 0;
    integer cross_exit_high_pair = 0;
    integer cross_exit_low_pair = 0;
    integer cross_carry_pair = 0;
    integer cross_window_ok = 0;
    integer fault_ok = 0;
    integer young_queue_issue0_count = 0, young_queue_issue1_count = 0;
    integer young_queue_retire0_count = 0, young_queue_retire1_count = 0;
    integer young_queue_dep_issue0_count = 0, young_queue_dep_issue1_count = 0;
    integer completion_replace_issue0_count = 0, completion_replace_issue1_count = 0;
    integer completion_replace_pc10_count = 0;
    integer young_queue_check = 0, young_queue_fail = 0, young_queue_expected_pc = 0;
    integer young_queue_ok = 0, young_queue_fast_ok = 0;
    integer stack_pair_check = 0, stack_pair_seen = 0, stack_pair_retired = 0;
    integer stack_pair_bad = 0, stack_pair_ok = 0;

    assign i_req_ready = 1'b1;
    assign d_req_ready = !d_pending && !d_rsp_valid_q;
    assign d_rsp_rdata = d_rsp_rdata_q;
    assign d_rsp_error = d_rsp_error_q;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            i_rsp_valid_q <= 1'b0;
            i_rsp_data_q <= 64'h0;
        end else begin
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid_q <= 1'b1;
                i_rsp_data_q <= imem[i_req_addr[31:3]];
            end else if (i_rsp_valid_q && i_rsp_ready) begin
                i_rsp_valid_q <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst == `RstDisable && dut.trap_redirect && dut.r0_mem_pending_q &&
            dut.lsu_fault_valid && dut.r0_pc_q == 32'h0000_0008) begin
            if (dut.w0_bypass_we !== 1'b1 || dut.cw0_we !== 1'b0 ||
                dut.issue0 !== 1'b0 || dut.issue1 !== 1'b0 ||
                dut.u_rf.regs[3] !== 32'd0) begin
                $display("FAIL: load-fault trap leaked bypass into state bypass=%b write=%b issue=%b%b x3=%08x",
                         dut.w0_bypass_we, dut.cw0_we, dut.issue0, dut.issue1,
                         dut.u_rf.regs[3]);
                fault_ok = -1;
            end else begin
                load_fault_bypass_seen = load_fault_bypass_seen + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            d_pending <= 1'b0;
            d_wait <= 0;
            d_rsp_valid_q <= 1'b0;
            d_rsp_rdata_q <= 32'h0;
            d_rsp_error_q <= 1'b0;
            store_count <= 0;
            mmio_store_count <= 0;
        end else begin
            if (d_rsp_valid_q && d_rsp_ready)
                d_rsp_valid_q <= 1'b0;
            if (d_req_valid && d_req_ready) begin
                d_pending <= (d_wait_config >= 0);
                d_wait <= d_wait_config;
                d_rsp_valid_q <= (d_wait_config < 0);
                d_rsp_error_q <= fault_sram && (d_req_addr[31:16] == 16'h8000);
                if (d_req_write) begin
                    store_count <= store_count + 1;
                    if (d_req_addr[31:16] == 16'h8000) begin
                        if (d_req_wstrb[0]) dmem[d_req_addr[11:2]][7:0] <= d_req_wdata[7:0];
                        if (d_req_wstrb[1]) dmem[d_req_addr[11:2]][15:8] <= d_req_wdata[15:8];
                        if (d_req_wstrb[2]) dmem[d_req_addr[11:2]][23:16] <= d_req_wdata[23:16];
                        if (d_req_wstrb[3]) dmem[d_req_addr[11:2]][31:24] <= d_req_wdata[31:24];
                    end else begin
                        mmio_store_count <= mmio_store_count + 1;
                    end
                    d_rsp_rdata_q <= 32'h0;
                end else if (d_req_addr[31:16] == 16'h8000) begin
                    d_rsp_rdata_q <= dmem[d_req_addr[11:2]];
                end else begin
                    d_rsp_rdata_q <= 32'h89ab_cdef;
                end
            end else if (d_pending && d_wait > 0) begin
                d_wait <= d_wait - 1;
            end else if (d_pending) begin
                d_pending <= 1'b0;
                d_rsp_valid_q <= 1'b1;
            end
        end
    end

    dual_issue_full_core dut (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid_q),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data_q), .i_rsp_error(2'b00),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid_q), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0),
        .issue0(issue0), .issue1(issue1),
        .retire0_valid(retire0_valid), .retire1_valid(retire1_valid),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(trace0_instr), .trace0_rd(trace0_rd),
        .trace0_rd_data(trace0_rd_data), .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr), .trace1_rd(trace1_rd),
        .trace1_rd_data(trace1_rd_data), .trace1_rd_we(trace1_rd_we), .trace1_trap(), .trace1_cause(),
        .pc_debug()
    );

    always @(posedge clk) begin
        if (rst == `RstDisable) begin
            if (issue0 && issue1) begin
                if (stack_pair_check && dut.fq_out0_pc == 32'h0000_000c &&
                    dut.fq_out1_pc == 32'h0000_0010)
                    stack_pair_seen <= stack_pair_seen + 1;
                if (dut.fq_out0_pc == 32'h0000_0008 && dut.fq_out1_pc == 32'h0000_000c)
                    pair_load_seen <= pair_load_seen + 1;
                if (dut.fq_out0_pc == 32'h0000_0010 && dut.fq_out1_pc == 32'h0000_0014)
                    bad_load_use_pair <= bad_load_use_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_001c && dut.fq_out1_pc == 32'h0000_0020)
                    bad_mmio_pair <= bad_mmio_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0024 && dut.fq_out1_pc == 32'h0000_0028)
                    cacheable_store_pair_seen <= cacheable_store_pair_seen + 1;
                if (dut.fq_out0_pc == 32'h0000_0030 && dut.fq_out1_pc == 32'h0000_0034)
                    mmio_store_pair_seen <= mmio_store_pair_seen + 1;
                if (dut.fq_out0_pc == 32'h0000_0008 && dut.fq_out1_pc == 32'h0000_000c)
                    boundary_byte_pair <= boundary_byte_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0018 && dut.fq_out1_pc == 32'h0000_001c)
                    boundary_half_pair <= boundary_half_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0028 && dut.fq_out1_pc == 32'h0000_002c)
                    boundary_word_pair <= boundary_word_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0034 && dut.fq_out1_pc == 32'h0000_0038)
                    boundary_outside_pair <= boundary_outside_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0008 && dut.fq_out1_pc == 32'h0000_000c)
                    cross_enter_low_pair <= cross_enter_low_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0014 && dut.fq_out1_pc == 32'h0000_0018)
                    cross_enter_high_pair <= cross_enter_high_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0024 && dut.fq_out1_pc == 32'h0000_0028)
                    cross_exit_high_pair <= cross_exit_high_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0030 && dut.fq_out1_pc == 32'h0000_0034)
                    cross_exit_low_pair <= cross_exit_low_pair + 1;
                if (dut.fq_out0_pc == 32'h0000_0040 && dut.fq_out1_pc == 32'h0000_0044)
                    cross_carry_pair <= cross_carry_pair + 1;
            end
            if (trace0_valid && trace1_valid && trace0_pc == 32'h8 && trace1_pc == 32'hc) begin
                if (trace1_order != trace0_order + 64'd1)
                    load_pair_retired <= -1;
                else
                    load_pair_retired <= load_pair_retired + 1;
            end
            if (trace0_valid && trace1_valid && trace0_pc == 32'h24 && trace1_pc == 32'h28) begin
                if (trace1_order != trace0_order + 64'd1)
                    cacheable_store_pair_retired <= -1;
                else
                    cacheable_store_pair_retired <= cacheable_store_pair_retired + 1;
            end
            if (stack_pair_check && trace1_valid && trace1_pc == 32'h0000_0010) begin
                stack_pair_retired <= stack_pair_retired + 1;
                if (!trace0_valid || trace0_pc != 32'h0000_000c ||
                    trace1_order != trace0_order + 64'd1 ||
                    trace1_rd_we !== 1'b1 || trace1_rd !== 5'd2 ||
                    trace1_rd_data !== 32'h8000_ff70)
                    stack_pair_bad <= stack_pair_bad + 1;
            end
            if (trace0_valid && trace0_trap && trace0_pc == 32'h8) begin
                load_fault_trap_seen <= load_fault_trap_seen + 1;
                if (trace1_valid)
                    young_load_pair_retired <= young_load_pair_retired + 1;
            end
            if (trace1_valid && trace1_pc == 32'hc)
                young_load_pair_retired <= young_load_pair_retired + 1;
        end
    end

    always @(posedge clk) begin
        if (rst == `RstDisable) begin
            if (young_queue_check) begin
                if (trace0_valid) begin
                    if (trace0_pc !== young_queue_expected_pc)
                        young_queue_fail = 1;
                    if (trace0_instr !== prog[trace0_pc[7:2]])
                        young_queue_fail = 1;
                    if (trace0_pc == 32'h0000_0010 &&
                        (trace0_rd_we !== 1'b1 || trace0_rd !== 5'd5 ||
                         trace0_rd_data !== 32'd1))
                        young_queue_fail = 1;
                    if (trace0_pc == 32'h0000_0014 &&
                        (trace0_rd_we !== 1'b1 || trace0_rd !== 5'd6 ||
                         trace0_rd_data !== 32'd2))
                        young_queue_fail = 1;
                    if (trace0_pc == 32'h0000_0018 &&
                        (trace0_rd_we !== 1'b1 || trace0_rd !== 5'd7 ||
                         trace0_rd_data !== 32'd4))
                        young_queue_fail = 1;
                    if (trace0_pc == 32'h0000_001c &&
                        (trace0_rd_we !== 1'b1 || trace0_rd !== 5'd8 ||
                         trace0_rd_data !== 32'd6))
                        young_queue_fail = 1;
                    if (trace0_pc == 32'h0000_0020)
                        young_queue_check = 0;
                    else
                        young_queue_expected_pc = young_queue_expected_pc + 4;
                end
                if (young_queue_check && trace1_valid) begin
                    if (trace1_pc !== young_queue_expected_pc)
                        young_queue_fail = 1;
                    if (trace1_instr !== prog[trace1_pc[7:2]])
                        young_queue_fail = 1;
                    if (trace1_order != trace0_order + 64'd1)
                        young_queue_fail = 1;
                    if (trace1_pc == 32'h0000_0010 &&
                        (trace1_rd_we !== 1'b1 || trace1_rd !== 5'd5 ||
                         trace1_rd_data !== 32'd1))
                        young_queue_fail = 1;
                    if (trace1_pc == 32'h0000_0014 &&
                        (trace1_rd_we !== 1'b1 || trace1_rd !== 5'd6 ||
                         trace1_rd_data !== 32'd2))
                        young_queue_fail = 1;
                    if (trace1_pc == 32'h0000_0018 &&
                        (trace1_rd_we !== 1'b1 || trace1_rd !== 5'd7 ||
                         trace1_rd_data !== 32'd4))
                        young_queue_fail = 1;
                    if (trace1_pc == 32'h0000_001c &&
                        (trace1_rd_we !== 1'b1 || trace1_rd !== 5'd8 ||
                         trace1_rd_data !== 32'd6))
                        young_queue_fail = 1;
                    if (trace1_pc == 32'h0000_0020)
                        young_queue_check = 0;
                    else
                        young_queue_expected_pc = young_queue_expected_pc + 4;
                end
                if (dut.young_long_pending && issue0 && !dut.young_completion_replace)
                    young_queue_issue0_count = young_queue_issue0_count + 1;
                if (dut.young_long_pending && issue1 && !dut.young_completion_replace)
                    young_queue_issue1_count = young_queue_issue1_count + 1;
                if (dut.young_completion_replace && issue0) begin
                    completion_replace_issue0_count = completion_replace_issue0_count + 1;
                    if (dut.fq_out0_pc == 32'h0000_0010)
                        completion_replace_pc10_count = completion_replace_pc10_count + 1;
                end
                if (dut.young_completion_replace && issue1)
                    completion_replace_issue1_count = completion_replace_issue1_count + 1;
                if (dut.young_long_pending && issue0 && dut.fq_out0_pc == 32'h0000_0018)
                    young_queue_dep_issue0_count = young_queue_dep_issue0_count + 1;
                if (dut.young_long_pending && issue1 && dut.fq_out1_pc == 32'h0000_001c)
                    young_queue_dep_issue1_count = young_queue_dep_issue1_count + 1;
                if (dut.young_queue_drain && dut.commit0_fire)
                    young_queue_retire0_count = young_queue_retire0_count + 1;
                if (dut.young_queue_drain && dut.commit1_fire)
                    young_queue_retire1_count = young_queue_retire1_count + 1;
            end
        end
    end

    task reset_run;
        input fault_mode;
        begin
            @(negedge clk); rst = `RstEnable; fault_sram = fault_mode;
            d_pending = 1'b0; d_rsp_valid_q = 1'b0; i_rsp_valid_q = 1'b0;
            repeat (3) @(posedge clk);
            #1 rst = `RstDisable;
        end
    endtask

    initial begin
        for (i = 0; i < 64; i = i + 1) prog[i] = 32'h0000_0013;
        for (i = 0; i < 1024; i = i + 1) dmem[i] = 32'h0;
        // LUI x1,0x80000; ADDI x2,x0,0; LW x3,0(x1); ADDI x4,x0,5
        // LW x11,0(x1); ADDI x12,x11,1 (dependent load-use pair must serialize)
        // LUI x7,0x10000; LW x8,0(x7); ADDI x9,x0,9 (MMIO pair must serialize)
        // SW x4,4(x1); ADDI x10,x0,10 pair in order; then MMIO SW must serialize.
        prog[0]  = 32'h8000_00b7;
        prog[1]  = 32'h0000_0113;
        prog[2]  = 32'h0000_a183;
        prog[3]  = 32'h0050_0213;
        prog[4]  = 32'h0000_a583;             // LW x11,0(x1)
        prog[5]  = 32'h0015_8613;             // ADDI x12,x11,1
        prog[6]  = 32'h1000_03b7;
        prog[7]  = 32'h0003_a403;             // LW x8,0(x7)
        prog[8]  = 32'h0090_0493;
        prog[9]  = 32'h0040_a223;             // SW x4,4(x1)
        prog[10] = 32'h00a0_0513;
        prog[11] = 32'h1000_06b7;             // LUI x13,0x10000 (MMIO)
        prog[12] = 32'h0046_a023;             // SW x4,0(x13), must not pair
        prog[13] = 32'h00e0_0713;             // ADDI x14,x0,14
        prog[14] = 32'h0000_006f;
        for (i = 0; i < 32; i = i + 1)
            imem[i] = {prog[2*i+1], prog[2*i]};
        dmem[0] = 32'h0000_1234;

        reset_run(1'b0);
        repeat (350) @(posedge clk);
        #1;
        if (pair_load_seen != 1) $display("FAIL: independent cacheable load+ALU issue count=%0d", pair_load_seen);
        if (load_pair_retired != 1) $display("FAIL: load+ALU did not retire together in order count=%0d", load_pair_retired);
        if (bad_load_use_pair != 0) $display("FAIL: load-use pair issued %0d times", bad_load_use_pair);
        if (bad_mmio_pair != 0) $display("FAIL: MMIO load pair issued %0d times", bad_mmio_pair);
        if (cacheable_store_pair_seen != 1)
            $display("FAIL: independent cacheable store+ALU pair count=%0d", cacheable_store_pair_seen);
        if (cacheable_store_pair_retired != 1)
            $display("FAIL: cacheable store+ALU did not retire together in order count=%0d",
                     cacheable_store_pair_retired);
        if (mmio_store_pair_seen != 0)
            $display("FAIL: MMIO store pair issued %0d times", mmio_store_pair_seen);
        if (dut.u_rf.regs[3] !== 32'h0000_1234 || dut.u_rf.regs[4] !== 32'd5)
            $display("FAIL: independent load+ALU results x3=%08x x4=%08x", dut.u_rf.regs[3], dut.u_rf.regs[4]);
        if (dut.u_rf.regs[12] !== 32'h0000_1235)
            $display("FAIL: serialized load-use result x12=%08x", dut.u_rf.regs[12]);
        if (dut.u_rf.regs[8] !== 32'h89ab_cdef || dut.u_rf.regs[9] !== 32'd9)
            $display("FAIL: serialized MMIO sequence x8=%08x x9=%08x", dut.u_rf.regs[8], dut.u_rf.regs[9]);
        if (dmem[1] !== 32'd5 || dmem[0] !== 32'h0000_1234 || store_count != 2 ||
            mmio_store_count != 1 || dut.u_rf.regs[14] !== 32'd14)
            $display("FAIL: store effects dmem1=%08x dmem0=%08x requests=%0d mmio=%0d x14=%0d",
                     dmem[1], dmem[0], store_count, mmio_store_count, dut.u_rf.regs[14]);
        if (pair_load_seen == 1 && load_pair_retired == 1 && bad_load_use_pair == 0 &&
            bad_mmio_pair == 0 && mmio_store_pair_seen == 0 &&
            cacheable_store_pair_seen == 1 && cacheable_store_pair_retired == 1 &&
            dut.u_rf.regs[3] === 32'h0000_1234 && dut.u_rf.regs[4] === 32'd5 &&
            dut.u_rf.regs[12] === 32'h0000_1235 &&
            dut.u_rf.regs[8] === 32'h89ab_cdef && dut.u_rf.regs[9] === 32'd9 &&
            dmem[1] === 32'd5 && dmem[0] === 32'h0000_1234 &&
            store_count == 2 && mmio_store_count == 1 && dut.u_rf.regs[14] === 32'd14) begin
            $display("PASS: cacheable load/store+independent ALU; dependent, MMIO, and non-cacheable operations serialize");
            success_ok = 1;
        end

        pair_load_seen = 0; bad_load_use_pair = 0; bad_mmio_pair = 0; bad_store_pair = 0;
        load_pair_retired = 0; load_fault_trap_seen = 0; young_load_pair_retired = 0;
        reset_run(1'b1);
        repeat (160) @(posedge clk);
        #1;
        if (load_fault_trap_seen == 0) $display("FAIL: injected SRAM load fault did not trap");
        if (young_load_pair_retired != 0) $display("FAIL: younger ALU retired across load fault count=%0d", young_load_pair_retired);
        if (load_fault_bypass_seen == 0) $display("FAIL: load-fault trap bypass contract was not observed");
        if (load_fault_trap_seen > 0 && young_load_pair_retired == 0 && load_fault_bypass_seen > 0 && fault_ok != -1) begin
            $display("PASS: load fault traps, suppresses array write, and cancels younger paired ALU");
            fault_ok = 1;
        end

        // Hold an older cacheable load while independent ALUs and then their
        // dependent consumers enter the young-result queue through forwarding.
        for (i = 0; i < 64; i = i + 1) prog[i] = 32'h0000_0013;
        prog[0] = 32'h8000_00b7; // LUI x1,0x80000
        prog[1] = 32'h0000_0113; // ADDI x2,x0,0
        prog[2] = 32'h0000_a183; // LW x3,0(x1), delayed older operation
        prog[3] = 32'h0050_0213; // ADDI x4,x0,5, paired with the load
        prog[4] = 32'h0010_0293; // ADDI x5,x0,1
        prog[5] = 32'h0020_0313; // ADDI x6,x0,2
        prog[6] = 32'h0032_8393; // ADDI x7,x5,3, RAW on queued x5
        prog[7] = 32'h0043_0413; // ADDI x8,x6,4, RAW on queued x6
        prog[8] = 32'h0000_006f; // JAL x0,0
        for (i = 0; i < 32; i = i + 1)
            imem[i] = {prog[2*i+1], prog[2*i]};
        dmem[0] = 32'h0000_1234;
        d_wait_config = 20;
        young_queue_issue0_count = 0;
        young_queue_issue1_count = 0;
        young_queue_retire0_count = 0;
        young_queue_retire1_count = 0;
        young_queue_dep_issue0_count = 0;
        young_queue_dep_issue1_count = 0;
        completion_replace_issue0_count = 0;
        completion_replace_issue1_count = 0;
        completion_replace_pc10_count = 0;
        young_queue_fail = 0;
        young_queue_expected_pc = 0;
        young_queue_check = 1;
        reset_run(1'b0);
        repeat (500) @(posedge clk);
        #1;
        young_queue_ok = 1;
        if (young_queue_check != 0 || young_queue_fail != 0) begin
            $display("FAIL: young-result retirement trace order/completion check=%0d fail=%0d expected_pc=%08x",
                     young_queue_check, young_queue_fail, young_queue_expected_pc);
            young_queue_ok = 0;
        end
        if (young_queue_issue0_count < 1 || young_queue_issue1_count < 1) begin
            $display("FAIL: no sustained dual ALU issue behind long operation issue0=%0d issue1=%0d",
                     young_queue_issue0_count, young_queue_issue1_count);
            young_queue_ok = 0;
        end
        if (young_queue_dep_issue0_count != 1 || young_queue_dep_issue1_count != 1) begin
            $display("FAIL: queued RAW consumers did not issue behind load lane0=%0d lane1=%0d",
                     young_queue_dep_issue0_count, young_queue_dep_issue1_count);
            young_queue_ok = 0;
        end
        if (young_queue_issue0_count + young_queue_issue1_count !=
            young_queue_retire0_count + young_queue_retire1_count) begin
            $display("FAIL: young-result queue lost/duplicated entries issued=%0d retired=%0d",
                     young_queue_issue0_count + young_queue_issue1_count,
                     young_queue_retire0_count + young_queue_retire1_count);
            young_queue_ok = 0;
        end
        if (dut.u_rf.regs[3] !== 32'h0000_1234 || dut.u_rf.regs[4] !== 32'd5 ||
            dut.u_rf.regs[5] !== 32'd1 || dut.u_rf.regs[6] !== 32'd2 ||
            dut.u_rf.regs[7] !== 32'd4 || dut.u_rf.regs[8] !== 32'd6) begin
            $display("FAIL: young-result queue register results x3=%08x x4=%08x x5=%08x x6=%08x x7=%08x x8=%08x",
                     dut.u_rf.regs[3], dut.u_rf.regs[4], dut.u_rf.regs[5],
                     dut.u_rf.regs[6], dut.u_rf.regs[7], dut.u_rf.regs[8]);
            young_queue_ok = 0;
        end
        if (young_queue_ok)
            $display("PASS: queued RAW forwarding sustains dependent ALUs behind delayed load and retires in order");

        // Repeat with an immediate response so a background lane1 result can
        // coincide with the older load's commit. It must not replace the
        // original load-paired ALU's saved result or leak through stale r1.
        // Match the D-cache hit timing: response becomes valid immediately
        // after the same edge that accepts the request.
        d_wait_config = -1;
        young_queue_issue0_count = 0;
        young_queue_issue1_count = 0;
        young_queue_retire0_count = 0;
        young_queue_retire1_count = 0;
        completion_replace_issue0_count = 0;
        completion_replace_issue1_count = 0;
        completion_replace_pc10_count = 0;
        young_queue_fail = 0;
        young_queue_expected_pc = 0;
        young_queue_check = 1;
        load_pair_retired = 0;
        reset_run(1'b0);
        repeat (350) @(posedge clk);
        #1;
        young_queue_fast_ok = 1;
        if (young_queue_check != 0 || young_queue_fail != 0 || load_pair_retired != 1) begin
            $display("FAIL: short-response trace/order or load-pair completion check=%0d fail=%0d pair=%0d",
                     young_queue_check, young_queue_fail, load_pair_retired);
            young_queue_fast_ok = 0;
        end
        if (young_queue_issue0_count + young_queue_issue1_count !=
            young_queue_retire0_count + young_queue_retire1_count) begin
            $display("FAIL: short-response queue lost/duplicated entries issued=%0d retired=%0d",
                     young_queue_issue0_count + young_queue_issue1_count,
                     young_queue_retire0_count + young_queue_retire1_count);
            young_queue_fast_ok = 0;
        end
        if (completion_replace_issue0_count != 1 ||
            completion_replace_issue1_count != 1 || completion_replace_pc10_count != 1) begin
            $display("FAIL: load completion did not replace the retiring pair issue0=%0d issue1=%0d pc10=%0d",
                     completion_replace_issue0_count, completion_replace_issue1_count,
                     completion_replace_pc10_count);
            young_queue_fast_ok = 0;
        end
        if (dut.u_rf.regs[3] !== 32'h0000_1234 || dut.u_rf.regs[4] !== 32'd5 ||
            dut.u_rf.regs[5] !== 32'd1 || dut.u_rf.regs[6] !== 32'd2 ||
            dut.u_rf.regs[7] !== 32'd4 || dut.u_rf.regs[8] !== 32'd6) begin
            $display("FAIL: short-response load/queue data x3=%08x x4=%08x x5=%08x x6=%08x x7=%08x x8=%08x",
                     dut.u_rf.regs[3], dut.u_rf.regs[4], dut.u_rf.regs[5],
                     dut.u_rf.regs[6], dut.u_rf.regs[7], dut.u_rf.regs[8]);
            young_queue_fast_ok = 0;
        end
        if (young_queue_fast_ok)
            $display("PASS: immediate load response preserves the older paired ALU and suppresses stale background lane1 writeback");

        // Reproduce the CoreMark failure shape: an SRAM load paired with
        // ADDI sp,sp,48, with the response arriving alongside the ALU result.
        for (i = 0; i < 64; i = i + 1) prog[i] = 32'h0000_0013;
        prog[0] = 32'h8000_00b7; // LUI x1,0x80000
        prog[1] = 32'h8001_0137; // LUI x2,0x80010
        prog[2] = 32'hf401_0113; // ADDI x2,x2,-192 -> 0x8000ff40
        prog[3] = 32'h0000_a183; // LW x3,0(x1)
        prog[4] = 32'h0301_0113; // ADDI x2,x2,48, paired with LW
        prog[5] = 32'h0010_0293; // Independent ALUs may queue behind the load
        prog[6] = 32'h0020_0313;
        prog[7] = 32'h0000_006f;
        for (i = 0; i < 32; i = i + 1)
            imem[i] = {prog[2*i+1], prog[2*i]};
        dmem[0] = 32'h0000_1234;
        d_wait_config = -1;
        stack_pair_check = 1;
        stack_pair_seen = 0;
        stack_pair_retired = 0;
        stack_pair_bad = 0;
        reset_run(1'b0);
        repeat (120) @(posedge clk);
        #1;
        stack_pair_ok = (stack_pair_seen == 1 && stack_pair_retired == 1 &&
                         stack_pair_bad == 0 && dut.u_rf.regs[2] === 32'h8000_ff70 &&
                         dut.u_rf.regs[3] === 32'h0000_1234);
        if (stack_pair_ok)
            $display("PASS: same-edge load response and paired stack ALU retire the current result");
        else
            $display("FAIL: same-edge load+stack-ALU pair issue=%0d retire=%0d bad=%0d x2=%08x x3=%08x",
                     stack_pair_seen, stack_pair_retired, stack_pair_bad,
                     dut.u_rf.regs[2], dut.u_rf.regs[3]);
        stack_pair_check = 0;
        d_wait_config = 5;
        young_queue_check = 0;

        // Exercise the last legal byte/halfword/word in the SRAM window, then
        // prove that the first word outside the window still serializes.
        boundary_byte_pair = 0; boundary_half_pair = 0;
        boundary_word_pair = 0; boundary_outside_pair = 0;
        for (i = 0; i < 64; i = i + 1) prog[i] = 32'h0000_0013;
        prog[0]  = 32'h8001_00b7; // LUI x1,0x80010
        prog[1]  = 32'hfff0_8093; // ADDI x1,x1,-1 => 0x8000ffff
        prog[2]  = 32'h0000_8183; // LB x3,0(x1), final byte
        prog[3]  = 32'h0050_0213; // independent ALU
        prog[4]  = 32'h8001_02b7; // LUI x5,0x80010
        prog[5]  = 32'hffe2_8293; // ADDI x5,x5,-2 => 0x8000fffe
        prog[6]  = 32'h0002_9303; // LH x6,0(x5), final aligned halfword
        prog[7]  = 32'h0070_0393; // independent ALU
        prog[8]  = 32'h8001_0437; // LUI x8,0x80010
        prog[9]  = 32'hffc4_0413; // ADDI x8,x8,-4 => 0x8000fffc
        prog[10] = 32'h0004_2483; // LW x9,0(x8), final aligned word
        prog[11] = 32'h00a0_0513; // independent ALU
        prog[12] = 32'h8001_05b7; // LUI x11,0x80010
        prog[13] = 32'h0005_a603; // LW x12,0(x11), first word outside
        prog[14] = 32'h00d0_0693; // independent ALU, must not pair
        prog[15] = 32'h0000_006f; // JAL x0,0
        for (i = 0; i < 32; i = i + 1)
            imem[i] = {prog[2*i+1], prog[2*i]};
        dmem[1023] = 32'h80ff_7f01;
        reset_run(1'b0);
        repeat (350) @(posedge clk);
        #1;
        if (boundary_byte_pair != 1)
            $display("FAIL: final SRAM byte load+ALU pair count=%0d", boundary_byte_pair);
        if (boundary_half_pair != 1)
            $display("FAIL: final SRAM halfword load+ALU pair count=%0d", boundary_half_pair);
        if (boundary_word_pair != 1)
            $display("FAIL: final SRAM word load+ALU pair count=%0d", boundary_word_pair);
        if (boundary_outside_pair != 0)
            $display("FAIL: out-of-window load paired %0d times", boundary_outside_pair);
        if (dut.u_rf.regs[3] !== 32'hffff_ff80 || dut.u_rf.regs[6] !== 32'hffff_80ff ||
            dut.u_rf.regs[9] !== 32'h80ff_7f01 || dut.u_rf.regs[12] !== 32'h89ab_cdef)
            $display("FAIL: boundary load values LB=%08x LH=%08x LW=%08x outside=%08x",
                     dut.u_rf.regs[3], dut.u_rf.regs[6], dut.u_rf.regs[9], dut.u_rf.regs[12]);
        if (boundary_byte_pair == 1 && boundary_half_pair == 1 && boundary_word_pair == 1 &&
            boundary_outside_pair == 0 && dut.u_rf.regs[3] === 32'hffff_ff80 &&
            dut.u_rf.regs[6] === 32'hffff_80ff && dut.u_rf.regs[9] === 32'h80ff_7f01 &&
            dut.u_rf.regs[12] === 32'h89ab_cdef) begin
            $display("PASS: aligned byte/halfword/word pair at SRAM upper edge; out-of-window load serialized");
            boundary_ok = 1;
        end

        // Check both sides of the SRAM window with signed address offsets:
        // 0x7fffffff + 1 and 0x80010000 - 1 enter SRAM and may pair; the
        // inverse crossings leave SRAM and must serialize.
        for (i = 0; i < 64; i = i + 1) prog[i] = 32'h0000_0013;
        prog[0]  = 32'h8000_00b7; // LUI x1,0x80000
        prog[1]  = 32'hfff0_8693; // ADDI x13,x1,-1 => 0x7fffffff
        prog[2]  = 32'h0016_8703; // LB x14,1(x13) => 0x80000000, pair
        prog[3]  = 32'h0070_0793; // independent ALU
        prog[4]  = 32'h8001_0137; // LUI x2,0x80010
        prog[5]  = 32'hfff1_0803; // LB x16,-1(x2) => 0x8000ffff, pair
        prog[6]  = 32'h0090_0893; // independent ALU
        prog[7]  = 32'h8001_01b7; // LUI x3,0x80010
        prog[8]  = 32'hfff1_8193; // ADDI x3,x3,-1 => 0x8000ffff
        prog[9]  = 32'h0011_8903; // LB x18,1(x3) => 0x80010000, no pair
        prog[10] = 32'h00b0_0993; // independent ALU
        prog[11] = 32'h8000_0237; // LUI x4,0x80000
        prog[12] = 32'hfff2_0a03; // LB x20,-1(x4) => 0x7fffffff, no pair
        prog[13] = 32'h00d0_0a93; // independent ALU
        prog[14] = 32'h8000_12b7; // LUI x5,0x80001 => 0x80001000
        prog[15] = 32'h0000_0013; // NOP: preserve base 0x80001000
        prog[16] = 32'hfff2_8303; // LB x6,-1(x5) => 0x80000fff; high-nibble carry, pair
        prog[17] = 32'h0070_0393; // independent ADDI x7,x0,7
        prog[18] = 32'h0000_006f; // JAL x0,0
        for (i = 0; i < 32; i = i + 1)
            imem[i] = {prog[2*i+1], prog[2*i]};
        dmem[0] = 32'h0000_1234;
        dmem[1023] = 32'h80ff_7f01;
        cross_enter_low_pair = 0;
        cross_enter_high_pair = 0;
        cross_exit_high_pair = 0;
        cross_exit_low_pair = 0;
        cross_carry_pair = 0;
        reset_run(1'b0);
        repeat (350) @(posedge clk);
        #1;
        if (cross_enter_low_pair != 1 || cross_enter_high_pair != 1 ||
            cross_exit_high_pair != 0 || cross_exit_low_pair != 0 || cross_carry_pair != 1)
            $display("FAIL: signed SRAM-window crossing pair counts in-low=%0d in-high=%0d out-high=%0d out-low=%0d carry-edge=%0d",
                     cross_enter_low_pair, cross_enter_high_pair,
                     cross_exit_high_pair, cross_exit_low_pair, cross_carry_pair);
        if (dut.u_rf.regs[14] !== 32'h0000_0034 || dut.u_rf.regs[16] !== 32'hffff_ff80 ||
            dut.u_rf.regs[18] !== 32'hffff_ffef || dut.u_rf.regs[20] !== 32'hffff_ff89 ||
            dut.u_rf.regs[6] !== 32'hffff_ff80 || dut.u_rf.regs[7] !== 32'd7)
            $display("FAIL: signed SRAM-window crossing load results x14=%08x x16=%08x x18=%08x x20=%08x x6=%08x x7=%08x",
                     dut.u_rf.regs[14], dut.u_rf.regs[16], dut.u_rf.regs[18], dut.u_rf.regs[20],
                     dut.u_rf.regs[6], dut.u_rf.regs[7]);
        if (cross_enter_low_pair == 1 && cross_enter_high_pair == 1 &&
            cross_exit_high_pair == 0 && cross_exit_low_pair == 0 && cross_carry_pair == 1 &&
            dut.u_rf.regs[14] === 32'h0000_0034 && dut.u_rf.regs[16] === 32'hffff_ff80 &&
            dut.u_rf.regs[18] === 32'hffff_ffef && dut.u_rf.regs[20] === 32'hffff_ff89 &&
            dut.u_rf.regs[6] === 32'hffff_ff80 && dut.u_rf.regs[7] === 32'd7) begin
            $display("PASS: signed offsets and 12-to-16-bit carry preserve load-pair eligibility");
            cross_window_ok = 1;
        end
        if (success_ok == 1 && fault_ok == 1 && young_queue_ok == 1 && young_queue_fast_ok == 1 &&
            stack_pair_ok == 1 &&
            boundary_ok == 1 && cross_window_ok == 1)
            $display("ALL TESTS PASSED (dual_full_load_alu)");
        else
            $display("DUAL_FULL_LOAD_ALU_RESULT: FAIL");
        $finish;
    end

    initial begin
        #200000;
        $display("DUAL_FULL_LOAD_ALU_RESULT: TIMEOUT");
        $finish;
    end
endmodule
