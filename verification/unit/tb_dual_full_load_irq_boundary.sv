`timescale 1ns/1ps
`include "defines.sv"

// Pending timer IRQ must be serviced at a bounded retirement boundary while
// independent cacheable loads continuously replace earlier loads.
module tb_dual_full_load_irq_boundary;
    reg clk = 0, rst = `RstEnable, timer_irq = 0;
    always #5 clk = ~clk;
    wire i_req_valid, i_rsp_ready, d_req_valid, d_req_write, d_rsp_ready;
    wire [31:0] i_req_addr, d_req_addr, d_req_wdata;
    wire [3:0] d_req_wstrb;
    wire issue0, issue1, retire0_valid, retire1_valid;
    reg i_rsp_valid = 0, d_rsp_valid = 0;
    reg [63:0] i_rsp_data = 0;
    reg [31:0] d_rsp_data = 0;
    reg [31:0] prog [0:511];
    reg [63:0] imem [0:255];
    reg pending = 0, irq_raised = 0;
    reg short_stream = 0, pair_stream = 0, mret_stream = 0;
    reg irq_seen = 0, mret_seen = 0, saw_young_issue = 0;
    integer resumed_pc20 = 0, resumed_pc24 = 0;
    integer delay_cycles = 0, accepted = 0, committed_loads = 0, replacements = 0;
    integer paired_alu_commits = 0, paired_load_retirements = 0;
    integer i, cycle = 0;
    reg [31:0] last_committed_pc = 32'hfffffffc;
    reg [31:0] expected_irq_pc;

    dual_issue_full_core #(.DUAL_ISSUE_EN(1), .PREDICT_ENABLE(1)) dut (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(1'b1),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(2'b00),
        .d_req_valid(d_req_valid), .d_req_ready(1'b1), .d_req_addr(d_req_addr),
        .d_req_write(d_req_write), .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_data),
        .d_rsp_error(1'b0), .timer_irq_i(timer_irq), .ext_irq_i(1'b0),
        .issue0(issue0), .issue1(issue1), .retire0_valid(retire0_valid),
        .retire1_valid(retire1_valid), .trace0_valid(), .trace0_order(), .trace0_pc(),
        .trace0_instr(), .trace0_rd(), .trace0_rd_data(), .trace0_rd_we(),
        .trace0_trap(), .trace0_cause(), .trace1_valid(), .trace1_order(), .trace1_pc(),
        .trace1_instr(), .trace1_rd(), .trace1_rd_data(), .trace1_rd_we(),
        .trace1_trap(), .trace1_cause(), .pc_debug()
    );

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            i_rsp_valid <= 0; d_rsp_valid <= 0; pending <= 0; delay_cycles <= 0;
        end else begin
            cycle <= cycle + 1;
            if (dut.young_queue_drain && (issue0 || issue1))
                $fatal(1, "issue must stay stopped while the young completion queue drains");
            if (i_req_valid) begin
                i_rsp_valid <= 1;
                i_rsp_data <= imem[i_req_addr[31:3]];
            end else if (i_rsp_valid && i_rsp_ready) i_rsp_valid <= 0;

            if (d_rsp_valid && d_rsp_ready) d_rsp_valid <= 0;
            if (d_req_valid) begin
                if (d_req_write || pending || (d_rsp_valid && !d_rsp_ready))
                    $fatal(1, "unexpected overlapping request or store");
                if (pair_stream && irq_raised && !irq_seen)
                    $fatal(1, "younger request accepted after IRQ before trap: addr=%08x", d_req_addr);
                accepted <= accepted + 1;
                pending <= 1; delay_cycles <= mret_stream ? 6 : 2;
            end else if (pending && delay_cycles != 0) delay_cycles <= delay_cycles - 1;
            else if (pending) begin
                pending <= 0; d_rsp_valid <= 1; d_rsp_data <= 32'h12345678;
            end

            if (dut.commit0_fire && !dut.commit_trap_fire) begin
                last_committed_pc = dut.w0_pc_final;
                if (pair_stream && prog[dut.w0_pc_final[31:2]] == 32'h00138393)
                    paired_alu_commits = paired_alu_commits + 1;
                if (mret_stream && irq_seen) begin
                    if (dut.mret_commit) mret_seen = 1;
                    if (dut.w0_pc_final == 32'h20) resumed_pc20 = resumed_pc20 + 1;
                    if (dut.w0_pc_final == 32'h24) begin
                        if (resumed_pc20 != 1) $fatal(1, "resumed PCs retired out of order");
                        resumed_pc24 = resumed_pc24 + 1;
                    end
                end
                if (dut.commit1_fire) begin
                    last_committed_pc = dut.s1_pc_final;
                    if (pair_stream && prog[dut.s1_pc_final[31:2]] == 32'h00138393)
                        paired_alu_commits = paired_alu_commits + 1;
                    if (dut.r0_mem_pending_q && dut.r1_mem_pair_pending_q)
                        paired_load_retirements = paired_load_retirements + 1;
                    if (mret_stream && irq_seen) begin
                        if (dut.s1_pc_final == 32'h20) resumed_pc20 = resumed_pc20 + 1;
                        if (dut.s1_pc_final == 32'h24) begin
                            if (resumed_pc20 != 1) $fatal(1, "resumed slot1 retired out of order");
                            resumed_pc24 = resumed_pc24 + 1;
                        end
                    end
                end
                if (mret_stream && irq_seen && (resumed_pc20 > 1 || resumed_pc24 > 1))
                    $fatal(1, "young instruction retired twice after mret");
                if (mret_stream && irq_seen && resumed_pc20 == 1 && resumed_pc24 == 1) begin
                    #1;
                    if (!mret_seen || dut.u_rf.regs[8] !== 32'd8 ||
                        dut.u_rf.regs[9] !== 32'd9 || !dut.u_csr.mstatus_mie_q)
                        $fatal(1, "mret recovery wrong mret=%b x8=%08x x9=%08x MIE=%b",
                               mret_seen, dut.u_rf.regs[8], dut.u_rf.regs[9], dut.u_csr.mstatus_mie_q);
                    $display("PASS: mret refetched and retired flushed young PCs 20/24 once in order");
                    $display("ALL TESTS PASSED");
                    $finish;
                end
            end
            if (mret_stream && irq_raised && !irq_seen && dut.young_long_pending &&
                issue0 && !dut.young_completion_replace && dut.fq_out0_pc == 32'h20)
                saw_young_issue = 1;
            if (irq_raised && dut.young_completion_replace && issue0 && dut.d0_is_mem)
                replacements = replacements + 1;
            if (irq_raised && dut.commit0_fire && dut.r0_mem_pending_q &&
                !dut.commit_trap_fire) begin
                committed_loads = committed_loads + 1;
                if (pair_stream && committed_loads == 1 &&
                    (!dut.commit1_fire || dut.s1_pc_final !== 32'h0000001c))
                    $fatal(1, "older paired ALU did not retire with load");
                $display("IRQ_WAIT cycle=%0d load=%0d pc=%08x pending=%b rsp=%b replace=%b issue=%b csr_irq=%b irq_take=%b",
                         cycle, committed_loads, dut.r0_pc_q, dut.r0_mem_pending_q,
                         d_rsp_valid, dut.young_completion_replace, issue0,
                         dut.csr_irq_pending, dut.irq_take);
                if (committed_loads >= 16 && !short_stream)
                    $fatal(1, "IRQ starved through 16 consecutive load retirements; replacements=%0d accepted=%0d last_pc=%08x",
                           replacements, accepted, last_committed_pc);
            end
            if (irq_raised && dut.commit_trap_fire) begin
                expected_irq_pc = last_committed_pc + 4;
                if (dut.commit_trap_cause !== 32'h80000007 ||
                    dut.commit_trap_pc !== expected_irq_pc)
                    $fatal(1, "IRQ cause/precise PC wrong cause=%08x pc=%08x expected=%08x",
                           dut.commit_trap_cause, dut.commit_trap_pc, expected_irq_pc);
                #1;
                if (dut.u_csr.mepc_q !== expected_irq_pc ||
                    dut.u_csr.mcause_q !== 32'h80000007 || dut.u_csr.mstatus_mie_q !== 0)
                    $fatal(1, "IRQ CSR state wrong mepc=%08x mcause=%08x MIE=%b",
                           dut.u_csr.mepc_q, dut.u_csr.mcause_q, dut.u_csr.mstatus_mie_q);
                if (dut.u_rf.regs[11] !== 32'h12345678 ||
                    (pair_stream && (paired_load_retirements == 0 ||
                                     dut.u_rf.regs[7] !== paired_alu_commits ||
                                     paired_alu_commits != 1 || committed_loads != 1 ||
                                     accepted != 1 || expected_irq_pc !== 32'h00000020)))
                    $fatal(1, "IRQ lost older load/paired ALU x11=%08x x7=%08x committed_alu=%0d paired_load=%0d",
                           dut.u_rf.regs[11], dut.u_rf.regs[7], paired_alu_commits, paired_load_retirements);
                if (mret_stream) begin
                    if (!saw_young_issue || dut.u_rf.regs[8] !== 0 || dut.u_rf.regs[9] !== 0)
                        $fatal(1, "young work not issued speculatively or leaked before IRQ");
                    irq_seen = 1; timer_irq = 0;
                    $display("IRQ entered; speculative young ALU not retired; timer IRQ cleared");
                end else begin
                    $display("PASS: IRQ accepted after %0d loads at precise PC %08x", committed_loads, expected_irq_pc);
                    $display("ALL TESTS PASSED");
                    $finish;
                end
            end
        end
    end

    always @(negedge clk) begin
        if (rst == `RstDisable && !irq_raised && dut.r0_mem_pending_q && pending &&
            !d_rsp_valid && dut.u_csr.mstatus_mie_q && dut.u_csr.mie_q[7]) begin
            timer_irq = 1; irq_raised = 1;
            $display("IRQ_ASSERT cycle=%0d pending_pc=%08x outstanding=%b", cycle, dut.r0_pc_q, pending);
        end
    end

    initial begin
        mret_stream = $test$plusargs("mret_stream");
        pair_stream = $test$plusargs("pair_stream") || mret_stream;
        short_stream = $test$plusargs("short_stream") || pair_stream;
        for (i = 0; i < 512; i = i + 1) prog[i] = 32'h00000013;
        prog[0] = 32'h40000093; // addi x1,x0,0x400 (mtvec)
        prog[1] = 32'h30509073; // csrrw x0,mtvec,x1
        prog[2] = 32'h08000113; // addi x2,x0,0x80 (MTIE)
        prog[3] = 32'h30411073; // csrrw x0,mie,x2
        prog[4] = 32'h30045073; // csrrsi x0,mstatus,8 (MIE)
        prog[5] = 32'h80000537; // lui x10,0x80000
        for (i = 6; i < (pair_stream ? 22 : (short_stream ? 14 : 134)); i = i + 1)
            prog[i] = pair_stream ? ((i[0] == 0) ? 32'h00052583 : 32'h00138393) :
                      ((i[0] == 0) ? 32'h00052583 : 32'h00452603); // lw+addi / lw+lw
        if (mret_stream) begin
            prog[8] = 32'h00800413; // addi x8,x0,8: issue speculatively then flush
            prog[9] = 32'h00900493; // addi x9,x0,9: issue speculatively then flush
            prog[256] = 32'h30200073; // mret at mtvec=0x400
        end
        for (i = 0; i < 256; i = i + 1) imem[i] = {prog[2*i+1], prog[2*i]};
        repeat (5) @(negedge clk);
        rst = `RstDisable;
        repeat (3000) @(negedge clk);
        $fatal(1, "timeout irq_raised=%b loads=%0d replacements=%0d", irq_raised, committed_loads, replacements);
    end
endmodule
