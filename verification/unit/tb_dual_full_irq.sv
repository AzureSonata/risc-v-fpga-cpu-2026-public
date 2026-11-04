`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_full_irq;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    wire        i_req_valid, i_req_ready;
    wire [31:0] i_req_addr;
    reg         i_rsp_valid;
    wire        i_rsp_ready;
    reg  [63:0] i_rsp_data;
    wire        d_req_valid, d_req_ready, d_req_write;
    wire [31:0] d_req_addr, d_req_wdata;
    wire [3:0]  d_req_wstrb;
    reg         d_rsp_valid;
    wire        d_rsp_ready;
    reg  [31:0] d_rsp_rdata;
    wire        d_rsp_error = 1'b0;
    reg         timer_irq = 1'b0;

    wire issue0, issue1, retire0_valid, retire1_valid;
    wire trace0_valid, trace1_valid;
    wire trace0_trap, trace1_trap;
    wire [31:0] trace0_cause;
    wire [31:0] trace0_pc, trace1_pc;
    wire [31:0] trace0_instr;
    wire [63:0] trace0_order, trace1_order;

    reg [31:0] prog [0:255];
    reg [63:0] imem [0:255];
    reg [31:0] dmem [0:1023];
    reg        i_rsp_valid_q;
    reg [63:0] i_rsp_data_q;
    reg        d_rsp_valid_q;
    reg [31:0] d_rsp_rdata_q;
    integer i;
    integer fail = 0;
    integer trap_events = 0;
    integer trace_events = 0;
    integer slot0_retire_count = 0;
    integer slot1_retire_count = 0;
    integer mret_retire_count = 0;
    reg [31:0] trap_cause_seen = 32'h0;
    reg [31:0] trap_trace_pc_seen = 32'h0;
    reg [31:0] trap_mepc_seen = 32'h0;
    reg pair_irq_injected = 1'b0;
    reg irq_bypass_contract_seen = 1'b0;

    assign i_req_ready = 1'b1;
    assign i_rsp_valid = i_rsp_valid_q;
    assign i_rsp_data  = i_rsp_data_q;
    assign d_req_ready = 1'b1;
    assign d_rsp_valid = d_rsp_valid_q;
    assign d_rsp_rdata = d_rsp_rdata_q;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            i_rsp_valid_q <= 1'b0;
            i_rsp_data_q  <= 64'h0;
        end else begin
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid_q <= 1'b1;
                i_rsp_data_q  <= imem[i_req_addr[31:3]];
            end else if (i_rsp_valid && i_rsp_ready) begin
                i_rsp_valid_q <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            d_rsp_valid_q <= 1'b0;
            d_rsp_rdata_q <= 32'h0;
        end else begin
            d_rsp_valid_q <= 1'b0;
            if (d_req_valid && d_req_ready) begin
                if (!d_req_write) d_rsp_rdata_q <= dmem[d_req_addr[11:2]];
                d_rsp_valid_q <= 1'b1;
            end
        end
    end

    // Observe registered retirement records away from the active edge so the
    // scoreboard sees the complete payload emitted by dual_retire_trace.
    always @(negedge clk) begin
        if (rst == `RstDisable) begin
            trace_events <= trace_events + trace0_valid + trace1_valid;
            if (trace0_valid && !trace0_trap && trace0_pc == 32'h14)
                slot0_retire_count <= slot0_retire_count + 1;
            if (trace0_valid && !trace0_trap && trace0_pc == 32'h18)
                slot1_retire_count <= slot1_retire_count + 1;
            if (trace1_valid && !trace1_trap && trace1_pc == 32'h18)
                slot1_retire_count <= slot1_retire_count + 1;
            if (trace0_valid && !trace0_trap && trace0_pc == 32'h10c &&
                trace0_instr == 32'h30200073)
                mret_retire_count <= mret_retire_count + 1;
            if (trace0_valid && trace0_trap) begin
                trap_events <= trap_events + 1;
                trap_cause_seen <= trace0_cause;
                trap_trace_pc_seen <= trace0_pc;
                trap_mepc_seen <= dut.u_csr.mepc;
            end
        end
    end

    // Check the combinational trap cycle before the active edge clears the
    // retiring state and fetch queue.
    always @(posedge clk) begin
        if (rst == `RstDisable && dut.trap_redirect && dut.r0_pc_q == 32'h14) begin
            if (dut.w0_bypass_we === 1'b1 && dut.cw0_we === 1'b0 &&
                dut.w1_bypass_we === 1'b1 && dut.cw1_we === 1'b0 &&
                dut.issue0 === 1'b0 && dut.issue1 === 1'b0 &&
                dut.fq_out0_valid === 1'b0 && dut.fq_out1_valid === 1'b0 &&
                dut.d0_ra === 32'd1 && dut.u_rf.regs[11] === 32'd0 &&
                dut.u_rf.regs[12] === 32'd0)
                irq_bypass_contract_seen = 1'b1;
            else begin
                $display("FAIL: IRQ trap bypass/flush contract bypass=%b write=%b issue=%b%b fq=%b%b ra=%08x x11=%08x",
                         dut.w0_bypass_we, dut.cw0_we, dut.issue0, dut.issue1,
                         dut.fq_out0_valid, dut.fq_out1_valid, dut.d0_ra, dut.u_rf.regs[11]);
                fail = fail + 1;
            end
        end
    end

    dual_issue_full_core dut (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data), .i_rsp_error(2'b00),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
        .timer_irq_i(timer_irq), .ext_irq_i(1'b0),
        .issue0(issue0), .issue1(issue1),
        .retire0_valid(retire0_valid), .retire1_valid(retire1_valid),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(trace0_instr), .trace0_rd(), .trace0_rd_data(),
        .trace0_rd_we(), .trace0_trap(trace0_trap), .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(), .trace1_rd(), .trace1_rd_data(),
        .trace1_rd_we(), .trace1_trap(trace1_trap), .trace1_cause(),
        .pc_debug()
    );

    initial begin
        for (i = 0; i < 256; i = i + 1) prog[i] = 32'h00000013;
        for (i = 0; i < 1024; i = i + 1) dmem[i] = 32'h0;
        $readmemh("verification/unit/dual_full_irq.hex", prog);
        // Keep the existing CSR/handler setup, but replace the idle loop with
        // an independent pair. The timer is asserted only when both results
        // are live and ready for same-cycle retirement.
        prog[5] = 32'h00100593; // PC 0x14: addi x11,x0,1 (older slot)
        prog[6] = 32'h00200613; // PC 0x18: addi x12,x0,2 (younger slot)
        prog[7] = 32'h00158693; // PC 0x1c: addi x13,x11,1 observes speculative bypass
        prog[8] = 32'h0000006f; // jal x0,0
        for (i = 0; i < 128; i = i + 1)
            imem[i] = {prog[2*i + 1], prog[2*i]};

        repeat (3) @(posedge clk);
        #1; rst = `RstDisable;

        // Wait for the real full-core execution results, not merely decode or
        // issue, then raise IRQ before their retirement edge.
        begin : inject_irq_at_pair
            integer n;
            n = 0;
            while (!pair_irq_injected && n < 500) begin
                @(negedge clk);
                if (dut.alu_w0_valid && dut.alu_w1_valid &&
                    dut.commit0_fire && dut.commit1_fire &&
                    dut.r0_pc_q == 32'h14 && dut.r1_pc_q == 32'h18) begin
                    timer_irq = 1'b1;
                    pair_irq_injected = 1'b1;
                end
                n = n + 1;
            end
        end
        if (!pair_irq_injected)
            $fatal(1, "FAIL: timer IRQ injection never observed both live retire slots");

        begin : wait_irq_and_mret
            integer n;
            n = 0;
            while (trap_events == 0 && n < 100) begin @(negedge clk); n = n + 1; end
            if (trap_events == 0) $fatal(1, "FAIL: timer IRQ did not produce a trap");
            #1;
            // IRQ is sampled before the pair's retirement edge. The precise
            // boundary is therefore the older slot PC; neither pair member
            // may retire or write architectural state before trap entry.
            if (slot0_retire_count !== 0 || dut.u_rf.regs[11] !== 32'd0)
            begin
                $display("FAIL: older slot retired or wrote before sampled IRQ (count=%0d x11=%08x)",
                         slot0_retire_count, dut.u_rf.regs[11]);
                fail = fail + 1;
            end
            if (slot1_retire_count !== 0 || dut.u_rf.regs[12] !== 32'd0)
            begin
                $display("FAIL: younger slot retired or wrote before sampled IRQ (count=%0d x12=%08x)",
                         slot1_retire_count, dut.u_rf.regs[12]);
                fail = fail + 1;
            end
            if (dut.u_csr.mepc !== 32'h14 || trap_mepc_seen !== 32'h14)
            begin
                $display("FAIL: pair-precommit IRQ mepc must point to older PC 0x14 (csr=%08x trace-snapshot=%08x)",
                         dut.u_csr.mepc, trap_mepc_seen);
                fail = fail + 1;
            end
            if (dut.u_csr.mcause !== 32'h80000007 || trap_cause_seen !== 32'h80000007)
            begin
                $display("FAIL: timer IRQ cause mismatch csr=%08x trace=%08x",
                         dut.u_csr.mcause, trap_cause_seen);
                fail = fail + 1;
            end

            if (!irq_bypass_contract_seen) begin
                $display("FAIL: IRQ trap cycle did not demonstrate read-only bypass with issue/queue flush");
                fail = fail + 1;
            end

            // The handler clears MTIE. Drop the external test stimulus too,
            // then ensure mret resumes at the younger instruction and never
            // replays the already-retired older instruction.
            timer_irq = 1'b0;
            n = 0;
            while (mret_retire_count == 0 && n < 200) begin @(negedge clk); n = n + 1; end
            if (mret_retire_count == 0) $fatal(1, "FAIL: handler did not return through mret");
            n = 0;
            while (slot1_retire_count == 0 && n < 100) begin @(negedge clk); n = n + 1; end
            repeat (20) @(negedge clk);
        end
        #1;

        if (dut.u_rf.regs[10] !== 32'h80000007) begin
            $display("FAIL: x10=0x%08x expected 0x80000007", dut.u_rf.regs[10]); fail=fail+1;
        end
        if (dut.u_rf.regs[1] !== 32'h100) begin
            $display("FAIL: x1=0x%08x expected 0x100", dut.u_rf.regs[1]); fail=fail+1;
        end
        if (dut.u_csr.mie !== 32'h0) begin
            $display("FAIL: mie=0x%08x expected 0 (handler clears MTIE)", dut.u_csr.mie); fail=fail+1;
        end
        if (trap_events !== 1) begin
            $display("FAIL: trap_events=%0d expected 1", trap_events); fail=fail+1;
        end
        if (trap_cause_seen !== 32'h80000007) begin
            $display("FAIL: trap cause seen 0x%08x expected 0x80000007", trap_cause_seen); fail=fail+1;
        end
        if (slot0_retire_count !== 1 || dut.u_rf.regs[11] !== 32'd1) begin
            $display("FAIL: older slot duplicate/missing after mret count=%0d x11=%08x",
                     slot0_retire_count, dut.u_rf.regs[11]); fail=fail+1;
        end
        if (slot1_retire_count !== 1 || dut.u_rf.regs[12] !== 32'd2) begin
            $display("FAIL: younger slot did not resume exactly once count=%0d x12=%08x",
                     slot1_retire_count, dut.u_rf.regs[12]); fail=fail+1;
        end
        if (dut.u_csr.mepc !== 32'h14 || trap_trace_pc_seen !== 32'h14) begin
            $display("FAIL: pair-precommit IRQ boundary PC expected 0x14 csr=%08x trace=%08x",
                     dut.u_csr.mepc, trap_trace_pc_seen); fail=fail+1;
        end

        $display("DUAL_FULL_IRQ: trace_events=%0d trap_events=%0d cause=0x%08x",
                 trace_events, trap_events, trap_cause_seen);
        if (fail == 0) begin
            $display("PASS: timer IRQ sampled before pair retirement preserves older-PC boundary");
            $display("PASS: mret replays both pair members exactly once without duplicate retirement");
            $display("ALL TESTS PASSED (dual_full_irq)");
        end else begin
            $display("DUAL_FULL_IRQ_RESULT: FAIL failures=%0d", fail);
        end
        $finish;
    end

    initial begin
        #300000;
        $display("DUAL_FULL_IRQ_RESULT: TIMEOUT");
        $finish;
    end
endmodule
