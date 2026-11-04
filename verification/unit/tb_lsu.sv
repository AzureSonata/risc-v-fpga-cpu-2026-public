//-----------------------------------------------------------------
// B1: LSU Unit Testbench - Flat inline structure
//-----------------------------------------------------------------

`timescale 1ns/1ns

module tb_lsu;

logic        clk, rst;
logic        valid_i;
logic [31:0] opcode_i, pc_i, ra_operand_i, rb_operand_i;
logic        hold_i;
logic        req_valid_o, req_ready_i;
logic [31:0] req_addr_o;
logic        req_write_o;
logic [31:0] req_wdata_o;
logic [3:0]  req_wstrb_o;
logic        rsp_valid_i, rsp_ready_o;
logic [31:0] rsp_rdata_i;
logic        rsp_error_i;
logic        valid_o;
logic [31:0] result_o;
logic        fault_valid_o, fault_ready_i;
logic        stall_o;
logic        mem_advanceable_o;
logic        fault_o;
logic [31:0] fault_pc_o;
logic [4:0]  fault_rd_o;
// 批 (b)：故障归因（集成端据此分 cause 4/6 与 5/7、并填 mtval）
logic        fault_misaligned_o;
logic [31:0] fault_addr_o;

riscv_lsu #(.WB_ON_RESPONSE(1'b1)) u_lsu (
    .clk_i(clk), .rst_i(rst), .valid_i(valid_i),
    .opcode_i(opcode_i), .pc_i(pc_i),
    .ra_operand_i(ra_operand_i), .rb_operand_i(rb_operand_i),
    .hold_i(hold_i),
    .req_valid_o(req_valid_o), .req_ready_i(req_ready_i),
    .req_addr_o(req_addr_o), .req_write_o(req_write_o),
    .req_wdata_o(req_wdata_o), .req_wstrb_o(req_wstrb_o),
    .rsp_valid_i(rsp_valid_i), .rsp_ready_o(rsp_ready_o),
    .rsp_rdata_i(rsp_rdata_i), .rsp_error_i(rsp_error_i),
    .fault_valid_o(fault_valid_o), .fault_ready_i(fault_ready_i),
    .valid_o(valid_o), .result_o(result_o), .stall_o(stall_o),
    .mem_advanceable_o(mem_advanceable_o), .fault_o(fault_o),
    .fault_pc_o(fault_pc_o), .fault_rd_o(fault_rd_o),
    .fault_misaligned_o(fault_misaligned_o), .fault_addr_o(fault_addr_o)
);

always #5 clk = ~clk;

integer pass_cnt, fail_cnt;
logic [31:0] bp_addr;      // 背压用例：从 DUT 首次呈现时采样完整请求载荷
logic        bp_write;
logic [31:0] bp_wdata;
logic [3:0]  bp_wstrb;
logic        bp_monitor;
integer      bp_accept_count;

task automatic check_success_wb(input [31:0] expected_result, input check_result);
    begin
        #1;
        if (valid_o === 1'b1 && (!check_result || result_o === expected_result)) begin
            $display("  PASS: combinational LSU writeback valid=%b result=%08x", valid_o, result_o);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: combinational LSU writeback valid=%b result=%08x expected=%08x",
                     valid_o, result_o, expected_result);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

// Count only actual DUT req_valid && req_ready handshakes in the dedicated
// backpressure scenario, including the cycle ready is released.
always @(posedge clk) begin
    if (bp_monitor && req_valid_o && req_ready_i)
        bp_accept_count <= bp_accept_count + 1;
end

task automatic check_load_first_cycle_backpressure;
    input [31:0] instruction;
    input [31:0] base_addr;
    input [31:0] expected_byte_addr;
    input [31:0] response_word;
    input [31:0] expected_result;
    begin
        @(negedge clk);
        valid_i = 1'b1;
        opcode_i = instruction;
        ra_operand_i = base_addr;
        rb_operand_i = 32'h1234_5678;
        pc_i = 32'h0000_4000;
        hold_i = 1'b0;
        req_ready_i = 1'b0;
        rsp_valid_i = 1'b0;
        rsp_error_i = 1'b0;
        #2;
        bp_addr = {expected_byte_addr[31:2], 2'b00};
        if (req_valid_o === 1'b1 && req_ready_i === 1'b0) begin
            $display("  PASS: IDLE request is presented and held under backpressure (%08x)", instruction);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: request not presented for IDLE backpressure (%08x)", instruction);
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk); #1;
        if (req_valid_o === 1'b1 && req_write_o === 1'b0 &&
            req_addr_o === bp_addr && req_wdata_o === 32'b0 && req_wstrb_o === 4'b0) begin
            $display("  PASS: captured load presented from REQ_WAIT (%08x)", instruction);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: captured load (%08x): v=%b a=%08x w=%b", instruction,
                     req_valid_o, req_addr_o, req_write_o);
            fail_cnt = fail_cnt + 1;
        end

        // Simulate the producer advancing after the first presented cycle.
        // The LSU must retain request payload and load-format context itself.
        @(negedge clk);
        valid_i = 1'b0;
        opcode_i = 32'h0020_A023; // unrelated SW with a different base and data
        ra_operand_i = 32'h9000_0100;
        rb_operand_i = 32'hDEAD_BEEF;
        #2;
        if (req_valid_o === 1'b1 && req_write_o === 1'b0 &&
            req_addr_o === bp_addr && req_wdata_o === 32'b0 && req_wstrb_o === 4'b0 &&
            fault_addr_o === expected_byte_addr) begin
            $display("  PASS: request/address context held after upstream changes");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: request/context changed: v=%b a=%08x byte_addr=%08x",
                     req_valid_o, req_addr_o, fault_addr_o);
            fail_cnt = fail_cnt + 1;
        end

        req_ready_i = 1'b1;
        #2;
        if (req_valid_o === 1'b1 && req_addr_o === bp_addr && req_write_o === 1'b0) begin
            $display("  PASS: held load request remains valid through ready release");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: held load request lost at ready release");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk); #1;
        req_ready_i = 1'b0;
        // The request has been accepted. Keep the live operands pointed at an
        // unrelated store and prove the outstanding response state still
        // drives the captured load tuple, even though req_valid is now low.
        valid_i = 1'b0;
        opcode_i = 32'h0020_A023;
        ra_operand_i = 32'h9000_0200;
        rb_operand_i = 32'hCAFE_BABE;
        #1;
        if (req_valid_o === 1'b0 && req_addr_o === bp_addr &&
            req_write_o === 1'b0 && req_wdata_o === 32'b0 && req_wstrb_o === 4'b0) begin
            $display("  PASS: WAIT_RSP holds the accepted load tuple while live inputs change");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: WAIT_RSP tuple changed: v=%b a=%08x w=%b d=%08x s=%b",
                     req_valid_o, req_addr_o, req_write_o, req_wdata_o, req_wstrb_o);
            fail_cnt = fail_cnt + 1;
        end
        rsp_rdata_i = response_word;
        rsp_valid_i = 1'b1;
        #1;
        if (rsp_ready_o === 1'b1) begin
            $display("  PASS: accepted load waits for response");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: accepted load did not enter response wait");
            fail_cnt = fail_cnt + 1;
        end
        check_success_wb(expected_result, 1'b1);
        if (req_valid_o === 1'b0 && req_addr_o === bp_addr &&
            req_write_o === 1'b0 && req_wdata_o === 32'b0 && req_wstrb_o === 4'b0) begin
            $display("  PASS: response cycle retains the accepted request tuple");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: response-cycle request tuple changed");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk); #1;
        rsp_valid_i = 1'b0;
        rsp_rdata_i = 32'b0;
        valid_i = 1'b0;
        req_ready_i = 1'b1;
        #5;
    end
endtask

initial begin
    pass_cnt = 0; fail_cnt = 0;
    clk = 0; rst = 1; hold_i = 0;
    valid_i = 0; opcode_i = 0; pc_i = 0;
    ra_operand_i = 0; rb_operand_i = 0;
    req_ready_i = 1; rsp_valid_i = 0;
    rsp_rdata_i = 0; rsp_error_i = 0; fault_ready_i = 0;
    bp_monitor = 0; bp_accept_count = 0;

    $display("========================================\n  LSU Unit Testbench - Stage1 B1\n========================================\n");

    #8 rst = 0;
    #12; // Past reset

    //=============================================================
    // Helper macro: issue a request at negedge, check at #2
    //=============================================================
    // 1. SW @ 0x80000000
    $display("--- SW ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0020A023; ra_operand_i=32'h80000000; rb_operand_i=32'hA5A5A5A5; #2;
    #1;
    if (req_valid_o && req_write_o && req_wstrb_o===4'hF && req_wdata_o===32'hA5A5A5A5) begin
        $display("  PASS: SW request"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: SW request"); end
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0; valid_i=0;
    #5;

    // 2. SH @4 (low halfword, addr[1]=0)
    $display("--- SH @4 (low half) ---");
    @(negedge clk); valid_i=1; opcode_i=32'h00201223; ra_operand_i=32'd0; rb_operand_i=32'hAABBCCDD; #2;
    #1;
    if (req_valid_o && req_write_o && req_wstrb_o===4'b0011 && req_wdata_o[15:0]===16'hCCDD) begin
        $display("  PASS: SH @4 low half (strb=%b)", req_wstrb_o); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: SH @4 (strb=%b, data=0x%h)", req_wstrb_o, req_wdata_o); end
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0; valid_i=0;
    #5;

    // 3. SH @6 (high halfword, addr[1]=1)
    $display("--- SH @6 (high half) ---");
    @(negedge clk); valid_i=1; opcode_i=32'h00201323; ra_operand_i=32'd0; rb_operand_i=32'hAABBCCDD; #2;
    #1;
    if (req_valid_o && req_write_o && req_wstrb_o===4'b1100 && req_wdata_o[31:16]===16'hCCDD) begin
        $display("  PASS: SH @6 high half (strb=%b)", req_wstrb_o); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: SH @6 (strb=%b, data=0x%h)", req_wstrb_o, req_wdata_o); end
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0; valid_i=0;
    #5;

    // 4. SB @3 (byte lane 3)
    $display("--- SB @3 ---");
    @(negedge clk); valid_i=1; opcode_i=32'h002001A3; ra_operand_i=32'd0; rb_operand_i=32'h42; #2;
    #1;
    if (req_valid_o && req_write_o && req_wstrb_o===4'b1000 && req_wdata_o[31:24]===8'h42) begin
        $display("  PASS: SB @3 (strb=%b)", req_wstrb_o); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: SB @3 (strb=%b)", req_wstrb_o); end
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0; valid_i=0;
    #5;

    // 5. SB @0 (byte lane 0)
    $display("--- SB @0 ---");
    @(negedge clk); valid_i=1; opcode_i=32'h00200023; ra_operand_i=32'd0; rb_operand_i=32'h42; #2;
    #1;
    if (req_valid_o && req_write_o && req_wstrb_o===4'b0001 && req_wdata_o[7:0]===8'h42) begin
        $display("  PASS: SB @0 (strb=%b)", req_wstrb_o); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: SB @0 (strb=%b)", req_wstrb_o); end
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0; valid_i=0;
    #5;

    // 6. SB @1 (byte lane 1)
    $display("--- SB @1 ---");
    @(negedge clk); valid_i=1; opcode_i=32'h002000A3; ra_operand_i=32'd0; rb_operand_i=32'h42; #2;
    #1;
    if (req_valid_o && req_write_o && req_addr_o===32'd0 &&
        req_wstrb_o===4'b0010 && req_wdata_o===32'h0000_4200) begin
        $display("  PASS: SB @1 (addr=%08h data=%08h strb=%b)", req_addr_o, req_wdata_o, req_wstrb_o); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: SB @1 (addr=%08h data=%08h strb=%b)", req_addr_o, req_wdata_o, req_wstrb_o); end
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0; valid_i=0;
    #5;

    // 7. SB @2 (byte lane 2)
    $display("--- SB @2 ---");
    @(negedge clk); valid_i=1; opcode_i=32'h00200123; ra_operand_i=32'd0; rb_operand_i=32'h42; #2;
    #1;
    if (req_valid_o && req_write_o && req_addr_o===32'd0 &&
        req_wstrb_o===4'b0100 && req_wdata_o===32'h0042_0000) begin
        $display("  PASS: SB @2 (addr=%08h data=%08h strb=%b)", req_addr_o, req_wdata_o, req_wstrb_o); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: SB @2 (addr=%08h data=%08h strb=%b)", req_addr_o, req_wdata_o, req_wstrb_o); end
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0; valid_i=0;
    #5;

    // 8. LW @0x80000000
    $display("--- LW ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0000A083; ra_operand_i=32'h80000000; #2;
    #1;
    if (req_valid_o && ~req_write_o) begin pass_cnt=pass_cnt+1; end // request sent
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: LW request not fired"); end
    @(posedge clk); #1; rsp_rdata_i=32'h12345678; rsp_valid_i=1;
    check_success_wb(32'h12345678, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0; rsp_rdata_i=0; valid_i=0;
    #5;

    // 7. LB @0 (byte0=0x01, signed → 0x01)
    $display("--- LB @0 ---");
    @(negedge clk); valid_i=1; opcode_i=32'h00008083; ra_operand_i=32'h80000000; #2; #1; if (req_valid_o && ~req_write_o) pass_cnt=pass_cnt+1; else begin fail_cnt=fail_cnt+1; $display("  FAIL: LB request not fired"); end
    @(posedge clk); #1; rsp_rdata_i=32'hABCDEF01; rsp_valid_i=1;
    check_success_wb(32'h00000001, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0; rsp_rdata_i=0; valid_i=0;
    #5;

    // 8. LB @0 negative (byte0=0x80, signed → 0xFFFFFF80)
    $display("--- LB @0 neg ---");
    @(negedge clk); valid_i=1; opcode_i=32'h00008083; ra_operand_i=32'h80000000; #2; #1; if (req_valid_o && ~req_write_o) pass_cnt=pass_cnt+1; else begin fail_cnt=fail_cnt+1; $display("  FAIL: LB request not fired"); end
    @(posedge clk); #1; rsp_rdata_i=32'hFFFFEF80; rsp_valid_i=1;
    check_success_wb(32'hFFFFFF80, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0; rsp_rdata_i=0; valid_i=0;
    #5;

    // 9. LB @3 (byte3=0xAB, signed → 0xFFFFFFAB)
    $display("--- LB @3 ---");
    @(negedge clk); valid_i=1; opcode_i=32'h00308083; ra_operand_i=32'h80000000; #2; #1; if (req_valid_o && ~req_write_o) pass_cnt=pass_cnt+1; else begin fail_cnt=fail_cnt+1; $display("  FAIL: LB @3 request not fired"); end
    @(posedge clk); #1; rsp_rdata_i=32'hABCDEF01; rsp_valid_i=1;
    check_success_wb(32'hFFFFFFAB, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0; rsp_rdata_i=0; valid_i=0;
    #5;

    // 10. LBU @3 (byte3=0xAB, unsigned → 0x000000AB)
    $display("--- LBU @3 ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0030C083; ra_operand_i=32'h80000000; #2; #1; if (req_valid_o && ~req_write_o) pass_cnt=pass_cnt+1; else begin fail_cnt=fail_cnt+1; $display("  FAIL: LBU @3 request not fired"); end
    @(posedge clk); #1; rsp_rdata_i=32'hABCDEF01; rsp_valid_i=1;
    check_success_wb(32'h000000AB, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0; rsp_rdata_i=0; valid_i=0;
    #5;

    // 11. Misaligned LW @0x80000007 (different from the preceding LBU address)
    $display("--- Misaligned LW ---");
    // Registered valid_o: completes at 2nd posedge after input
    @(negedge clk); valid_i=1; opcode_i=32'h0000A083; ra_operand_i=32'h80000007; #2;
    // Should see NO memory request (misaligned)
    if (~req_valid_o) begin $display("  PASS: Misaligned LW, no mem req"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: Misaligned LW sent req"); end
    // 2 posedges for MISALIGNED_ST→IDLE + wb_valid
    @(posedge clk); @(posedge clk); #1;
    // PR #20 review #3 + Task 5：非对齐同样不得产生"成功写回"，改为拉高 fault_o。
    // 预期变更理由：原断言 valid_o && result_o===addr 依赖"用地址充当故障标记"的旧语义，
    // 而该语义正是 review 指出的缺陷（集成端无法区分访问错误与正常数据）。
    if (fault_o===1'b1 && valid_o===1'b0) begin
        $display("  PASS: Misaligned LW raises fault, no writeback"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: Misaligned LW (fault=%b, valid=%b)", fault_o, valid_o); end
    // 批 (b) 新增：故障类别与出错地址必须可归因（→ cause 4 与 mtval）
    if (fault_misaligned_o===1'b1) begin $display("  PASS: misaligned fault flagged (cause 4/6 path)"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: fault_misaligned_o=%b (want 1)", fault_misaligned_o); end
    if (fault_addr_o===32'h80000007) begin $display("  PASS: fault_addr_o=%0h", fault_addr_o); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: fault_addr_o=0x%h (want 0x80000007)", fault_addr_o); end
    valid_i=0;
    #5;

    // 12. Backpressure: request presented while req_ready_i=0 must be held,
    //     upstream stalled, and MEM must not advance (PR #20 review #2).
    $display("--- Backpressure (req_ready_i=0) ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0020A023; ra_operand_i=32'h80000010; rb_operand_i=32'hDEADBEEF;
    req_ready_i=0; hold_i=0; bp_monitor=1; bp_accept_count=0; #2;
    if (req_valid_o===1'b1 && req_ready_i===1'b0) begin $display("  PASS: IDLE request presented under backpressure"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: IDLE request not presented under backpressure"); end
    @(posedge clk); #1;
    // Capture the public DUT request interface at first presentation; all
    // later stability checks compare against this sampled transaction.
    bp_addr = req_addr_o;
    bp_write = req_write_o;
    bp_wdata = req_wdata_o;
    bp_wstrb = req_wstrb_o;
    if (req_valid_o===1'b1 && bp_addr===32'h80000010 && bp_write===1'b1 &&
        bp_wdata===32'hDEADBEEF && bp_wstrb===4'hF &&
        req_write_o===bp_write && req_addr_o===bp_addr && req_wdata_o===bp_wdata && req_wstrb_o===bp_wstrb) begin
        $display("  PASS: BP req presented"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: BP req presented (v=%b w=%b d=0x%h s=%b)", req_valid_o, req_write_o, req_wdata_o, req_wstrb_o); end
    if (stall_o===1'b1) begin $display("  PASS: BP stall_o=1 on fire cycle"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: BP stall_o=%b (want 1)", stall_o); end
    if (mem_advanceable_o===1'b0) begin $display("  PASS: BP mem not advanceable"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: BP mem_advanceable_o=%b (want 0)", mem_advanceable_o); end

    // Hold ready low 2 more cycles: valid and full payload must stay put
    @(negedge clk); #2;
    if (req_valid_o===1'b1 && req_write_o===bp_write && req_addr_o===bp_addr &&
        req_wdata_o===bp_wdata && req_wstrb_o===bp_wstrb) begin
        $display("  PASS: BP held (cycle 2)"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: BP held cycle 2 (v=%b a=0x%h d=0x%h)", req_valid_o, req_addr_o, req_wdata_o); end
    @(negedge clk); #2;
    if (req_valid_o===1'b1 && req_write_o===bp_write && req_addr_o===bp_addr &&
        req_wdata_o===bp_wdata && req_wstrb_o===bp_wstrb) begin
        $display("  PASS: BP held (cycle 3)"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: BP held cycle 3 (v=%b a=0x%h)", req_valid_o, req_addr_o); end

    // Upstream walks away while the request is still unaccepted: the request and
    // its full payload must survive (proves the payload is latched, not combinational).
    @(negedge clk); valid_i=0; #2;
    if (req_valid_o===1'b1 && req_write_o===bp_write && req_addr_o===bp_addr &&
        req_wdata_o===bp_wdata && req_wstrb_o===bp_wstrb) begin
        $display("  PASS: BP survives upstream drop (latched)"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: BP lost on upstream drop (v=%b a=0x%h d=0x%h)", req_valid_o, req_addr_o, req_wdata_o); end

    // Release: accept the held request, then drain the response
    req_ready_i=1; #2;
    if (req_valid_o===1'b1 && req_write_o===bp_write && req_addr_o===bp_addr &&
        req_wdata_o===bp_wdata && req_wstrb_o===bp_wstrb) begin
        $display("  PASS: BP valid present at release"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: BP valid lost at release (v=%b a=0x%h)", req_valid_o, req_addr_o); end
    @(posedge clk); #1; valid_i=0;
    if (bp_accept_count===1) begin
        $display("  PASS: exactly one DUT request handshake after ready release"); pass_cnt=pass_cnt+1;
    end else begin
        fail_cnt=fail_cnt+1;
        $display("  FAIL: request handshake count=%0d (want 1)", bp_accept_count);
    end
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0;
    if (bp_accept_count===1) begin
        $display("  PASS: no duplicate DUT request handshake through response"); pass_cnt=pass_cnt+1;
    end else begin
        fail_cnt=fail_cnt+1;
        $display("  FAIL: duplicate request handshake count=%0d", bp_accept_count);
    end
    bp_monitor=0;
    req_ready_i=1; hold_i=0; #5;

    // 13. hold_i raised while request presented but not yet accepted:
    //     an already-presented valid must NOT be retracted (PR #20 review #2).
    $display("--- Hold during backpressure ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0020A023; ra_operand_i=32'h80000020; rb_operand_i=32'h12345678;
    req_ready_i=0; hold_i=0; #2;
    if (req_valid_o===1'b1 && req_write_o===1'b1 && req_addr_o===32'h80000020) begin
        $display("  PASS: direct IDLE request presented before capture edge"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: direct IDLE request missing"); end
    @(posedge clk); #1;
    if (req_valid_o===1'b1) begin $display("  PASS: hold-case req presented"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: hold-case req not presented"); end
    @(negedge clk); hold_i=1; #2;
    if (req_valid_o===1'b1) begin $display("  PASS: valid held under hold_i"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: valid retracted by hold_i (v=%b)", req_valid_o); end
    // Cleanup: release hold, accept, drain
    @(negedge clk); hold_i=0; req_ready_i=1; #2;
    @(posedge clk); #1;
    @(posedge clk); #1; valid_i=0;
    @(posedge clk); #1; rsp_valid_i=1;
    check_success_wb(32'b0, 1'b0);
    @(posedge clk); #1; rsp_valid_i=0;
    #5;

    // 14. Error response must raise fault and must NOT produce a successful
    //     writeback (PR #20 review #3).
    $display("--- Error response (rsp_error_i=1) ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0000A083; ra_operand_i=32'h80000030; #2;   // LW
    #1;
    if (req_valid_o===1'b1 && req_write_o===1'b0) begin $display("  PASS: err-case req fired"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: err-case req fired (v=%b w=%b)", req_valid_o, req_write_o); end
    @(posedge clk); #1; rsp_rdata_i=32'hBAADF00D; rsp_error_i=1; rsp_valid_i=1;
    #1;
    if (valid_o===1'b0) begin $display("  PASS: error response has no successful writeback"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: error response asserted successful writeback"); end
    @(posedge clk); #1; rsp_valid_i=0; rsp_error_i=0; rsp_rdata_i=0; valid_i=0;
    if (fault_o===1'b1) begin $display("  PASS: error raises fault_o"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: error did not raise fault_o"); end
    if (valid_o===1'b0) begin $display("  PASS: error produces no successful writeback"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: error produced successful writeback (valid=%b result=0x%h)", valid_o, result_o); end
    if (fault_valid_o===1'b1) begin $display("  PASS: fault event is valid"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: missing fault_valid_o event"); end
    @(negedge clk); #1;
    if (fault_valid_o!==1'b1) begin fail_cnt=fail_cnt+1; $display("  FAIL: unconsumed fault event was not held"); end
    else begin $display("  PASS: unconsumed fault event held"); pass_cnt=pass_cnt+1; end
    if (stall_o===1'b1 && mem_advanceable_o===1'b0) begin
        $display("  PASS: unconsumed fault backpressures upstream"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: unconsumed fault did not backpressure (stall=%b advanceable=%b)",
                 stall_o, mem_advanceable_o); end
    fault_ready_i=1'b1;
    @(posedge clk); #1; fault_ready_i=1'b0;
    if (fault_valid_o===1'b0) begin $display("  PASS: fault event clears on ready/valid handshake"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: fault event did not clear after handshake"); end
    if (stall_o===1'b0 && mem_advanceable_o===1'b1) begin
        $display("  PASS: acknowledgement releases backpressure"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: acknowledgement did not release backpressure"); end
    #5;

    // 15. Normal response reverse control: no fault, real data written back
    $display("--- Normal response (rsp_error_i=0) ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0000A083; ra_operand_i=32'h80000034; #2;   // LW
    #1;
    if (req_valid_o===1'b1 && req_write_o===1'b0) begin $display("  PASS: ok-case req fired"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: ok-case req fired"); end
    @(posedge clk); #1; rsp_rdata_i=32'h600DCAFE; rsp_valid_i=1;
    check_success_wb(32'h600DCAFE, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0; rsp_rdata_i=0; valid_i=0;
    if (fault_o===1'b0) begin $display("  PASS: normal response raises no fault"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: normal response raised fault_o"); end
    #5;

    // 16. hold_i=1 while req_ready_i=1 (the normal case: the D-port adapter holds
    //     ready high whenever it is idle). req_valid_o is gated by ~hold_i, so the
    //     request is NOT presented — the LSU must therefore NOT consume the handshake
    //     and advance to WAIT_RSP, or it waits forever for a response that can never
    //     arrive (deadlock, no self-recovery when hold is released).
    $display("--- hold_i with D-port ready ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0000A083; ra_operand_i=32'h80000038;
    hold_i=1; req_ready_i=1; #2;
    if (req_valid_o===1'b0) begin $display("  PASS: hold gates req_valid_o"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: req_valid_o not gated by hold"); end
    @(posedge clk); #1; @(posedge clk); #1; @(posedge clk); #1;
    if (stall_o===1'b0) begin $display("  PASS: not stuck while hold asserted"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: stuck (stall_o=1) though the request was never presented"); end
    @(negedge clk); hold_i=0; #2;
    #1;
    if (req_valid_o===1'b1 && req_ready_i===1'b1) begin $display("  PASS: request presents after hold released"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: request not presented after hold released"); end
    @(posedge clk); #1; valid_i=0;
    @(posedge clk); #1; rsp_rdata_i=32'hFEEDBEEF; rsp_valid_i=1;
    check_success_wb(32'hFEEDBEEF, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0; rsp_rdata_i=0;
    hold_i=0; req_ready_i=1; #5;

    // 17. An aligned IDLE request is presented immediately and accepted on the
    //     first edge when ready is high; later response handling stays registered.
    $display("--- immediate request/handshake timing ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0000A083; ra_operand_i=32'h8000003C;
    hold_i=0; req_ready_i=1; #2;
    if (stall_o===1'b0 && mem_advanceable_o===1'b1) begin
        $display("  PASS: IDLE can accept the memory instruction"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: acceptance control (stall=%b advanceable=%b)", stall_o, mem_advanceable_o); end
    if (req_valid_o===1'b1 && req_ready_i===1'b1 && req_addr_o===32'h8000003C) begin
        $display("  PASS: request valid with correct payload in IDLE"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: IDLE request missing/incorrect"); end
    @(posedge clk); #1;
    if (req_valid_o===1'b0 && rsp_ready_o===1'b1) begin
        $display("  PASS: accepted request enters response wait without duplicate"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: response wait state missing/duplicate request"); end
    @(posedge clk); #1; valid_i=0;
    @(posedge clk); #1; rsp_rdata_i=32'h0000BEEF; rsp_valid_i=1;
    check_success_wb(32'h0000BEEF, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0; rsp_rdata_i=0;
    #5;

    // 18. fault must carry the faulting instruction's PC and rd context so the
    //     integrator can attribute it (A's review #3 asks for PC/instruction/rd).
    //     0x00002283 = LW x5, 0(x0)  → rd field [11:7] = 5
    $display("--- fault context (pc/rd) ---");
    @(negedge clk); valid_i=1; opcode_i=32'h00002283; pc_i=32'h00003000; ra_operand_i=32'h80000200; req_ready_i=1; #2;
    @(posedge clk); #1;
    @(posedge clk); #1; rsp_error_i=1; rsp_valid_i=1;
    @(posedge clk); #1; rsp_valid_i=0; rsp_error_i=0; valid_i=0;
    if (fault_pc_o===32'h00003000) begin $display("  PASS: fault_pc_o=%0h", fault_pc_o); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: fault_pc_o=0x%h (want 0x3000)", fault_pc_o); end
    if (fault_rd_o===5'd5) begin $display("  PASS: fault_rd_o=x%0d", fault_rd_o); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: fault_rd_o=x%0d (want x5)", fault_rd_o); end
    // 批 (b) 新增：访问错误（非非对齐）必须报 fault_misaligned_o=0，且带上出错字节地址
    if (fault_misaligned_o===1'b0) begin $display("  PASS: access fault is not flagged as misaligned"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: fault_misaligned_o=%b (want 0)", fault_misaligned_o); end
    if (fault_addr_o===32'h80000200) begin $display("  PASS: fault_addr_o=%0h", fault_addr_o); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: fault_addr_o=0x%h (want 0x80000200)", fault_addr_o); end
    fault_ready_i=1'b1; @(posedge clk); #1; fault_ready_i=1'b0;
    #5;

    // 19. Cross-case: the D request is accepted first, then upstream hold rises
    //     while the response is pending. Do not reissue the request; complete once.
    $display("--- Accepted request then hold ---");
    @(negedge clk); valid_i=1; opcode_i=32'h0000A083; ra_operand_i=32'h80000040;
    hold_i=0; req_ready_i=1; rsp_valid_i=0; #2;
    if (req_valid_o===1'b1 && req_addr_o===32'h80000040 && req_write_o===1'b0) begin
        $display("  PASS: IDLE presents the request for immediate handshake"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1; $display("  FAIL: IDLE request missing/incorrect"); end
    @(posedge clk); #1;
    valid_i=0; hold_i=1;
    if (req_valid_o===1'b0 && rsp_ready_o===1'b1 && stall_o===1'b1) begin
        $display("  PASS: accepted request waits for response under hold"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: post-accept state (v=%b ready=%b stall=%b)", req_valid_o, rsp_ready_o, stall_o); end
    repeat (2) begin
        @(negedge clk); #1;
        if (req_valid_o===1'b0 && rsp_ready_o===1'b1 && valid_o===1'b0) begin
            $display("  PASS: no duplicate request while response delayed"); pass_cnt=pass_cnt+1;
        end else begin fail_cnt=fail_cnt+1;
            $display("  FAIL: duplicate/early completion (v=%b ready=%b wb=%b)", req_valid_o, rsp_ready_o, valid_o); end
    end
    @(negedge clk); rsp_rdata_i=32'hC001D00D; rsp_valid_i=1; #1;
    if (rsp_ready_o===1'b1) begin $display("  PASS: response accepted under hold"); pass_cnt=pass_cnt+1; end
    else begin fail_cnt=fail_cnt+1; $display("  FAIL: response not ready under hold"); end
    check_success_wb(32'hC001D00D, 1'b1);
    @(posedge clk); #1; rsp_valid_i=0;
    @(posedge clk); #1;
    if (valid_o===1'b0 && req_valid_o===1'b0) begin
        $display("  PASS: no duplicate writeback or request"); pass_cnt=pass_cnt+1;
    end else begin fail_cnt=fail_cnt+1;
        $display("  FAIL: duplicate writeback/request (wb=%b req=%b)", valid_o, req_valid_o); end
    hold_i=0; #5;

    // 20. Load format/address context must be captured on the first presented
    // cycle even when ready is low. Existing tests above retain ready-high
    // first-cycle coverage; these cases change upstream payload before accept.
    $display("--- Load metadata capture under first-cycle backpressure ---");
    check_load_first_cycle_backpressure(32'h0020_8283, 32'h8000_0000,
                                        32'h8000_0002, 32'h80FF_7F01,
                                        32'hFFFF_FFFF); // LB +2
    check_load_first_cycle_backpressure(32'h0020_C283, 32'h8000_0000,
                                        32'h8000_0002, 32'h80FF_7F01,
                                        32'h0000_00FF); // LBU +2
    check_load_first_cycle_backpressure(32'h0020_9283, 32'h8000_0000,
                                        32'h8000_0002, 32'h80FF_7F01,
                                        32'hFFFF_80FF); // LH +2
    check_load_first_cycle_backpressure(32'h0020_D283, 32'h8000_0000,
                                        32'h8000_0002, 32'h80FF_7F01,
                                        32'h0000_80FF); // LHU +2
    check_load_first_cycle_backpressure(32'h0000_A283, 32'h8000_0000,
                                        32'h8000_0000, 32'h80FF_7F01,
                                        32'h80FF_7F01); // LW

    // Summary
    $display("\n========================================");
    if (fail_cnt==0) $display("  ALL TESTS PASS (%0d passed)", pass_cnt);
    else $display("  FAILED: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $display("========================================");
    if (fail_cnt==0) $finish;
    else $fatal(1,"TESTBENCH FAILED");
end

endmodule
