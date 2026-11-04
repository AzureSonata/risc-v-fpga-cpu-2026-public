`timescale 1ns/1ps

module tb_cpu_core_stage1;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    wire i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg i_rsp_valid = 1'b0;
    reg [31:0] i_rsp_data = 32'h00000013;
    wire d_req_valid, d_req_ready, d_req_write, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0] d_req_wstrb;
    reg d_rsp_valid = 1'b0;
    reg [31:0] d_rsp_rdata_q = 0;
    wire trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;
    wire [4:0] trace_rd;

    function automatic [31:0] rom(input [31:0] addr);
        case (addr)
            32'h00: rom = 32'h00100093; // addi x1,x0,1
            32'h04: rom = 32'h00108463; // beq x1,x1,+8
            32'h08: rom = 32'h06300113; // wrong path: addi x2,x0,99
            32'h0c: rom = 32'h00002203; // lw x4,0(x0)
            32'h10: rom = 32'h00108463; // beq x1,x1,+8 while a younger instruction is queued
            32'h14: rom = 32'h06300113; // wrong path: addi x2,x0,99
            32'h18: rom = 32'h00108113; // addi x2,x1,1
            32'h1c: rom = 32'h002081b3; // add x3,x1,x2
            32'h20: rom = 32'h00120293; // addi x5,x4,1
            32'h24: rom = 32'h00502223; // sw x5,4(x0)
            32'h28: rom = 32'h00402303; // lw x6,4(x0)
            32'h2c: rom = 32'h00130393; // addi x7,x6,1 (load-use)
            32'h30: rom = 32'h06300013; // addi x0,x0,99
            default: rom = 32'h00000013;
        endcase
    endfunction

    assign i_req_ready = (i_req_addr <= 32'h30);
    always @(posedge clk) begin
        if (rst) begin
            i_rsp_valid <= 1'b0;
            i_rsp_data <= 32'h00000013;
        end else begin
            i_rsp_valid <= 1'b0;
            if (i_req_valid && i_req_ready) begin
                i_rsp_valid <= 1'b1;
                i_rsp_data <= rom(i_req_addr);
            end
        end
    end

    reg [31:0] dmem [0:3];
    reg pending_rsp = 1'b0;
    reg [2:0] rsp_delay = 0;
    reg [31:0] pending_addr = 0, pending_wdata = 0;
    reg [3:0] pending_wstrb = 0;
    reg pending_write = 0;
    integer accepted_requests = 0;
    integer completed_responses = 0;
    integer first_req_wait = 0;
    reg saw_req_backpressure = 1'b0;
    reg req_hold_active = 1'b0;
    reg saw_load_use = 1'b0;
    reg saw_rsp_wait = 1'b0;
    reg accepted_d_context_valid = 1'b0;
    reg [31:0] accepted_d_pc = 0, accepted_d_instr = 0, accepted_d_alu = 0, accepted_d_store_data = 0;
    reg [4:0] accepted_d_rd = 0;
    reg accepted_d_mem_read = 0, accepted_d_mem_write = 0, accepted_d_reg_write = 0;
    integer accepted_then_hold_cycles = 0;
    reg [31:0] held_addr = 0, held_wdata = 0;
    reg held_write = 0;
    reg [3:0] held_wstrb = 0;
    assign d_req_ready = !pending_rsp && (accepted_requests != 0 || first_req_wait >= 3);
    assign d_rsp_rdata = d_rsp_rdata_q;

    always @(posedge clk) begin
        if (rst) begin
            dmem[0] <= 32'd7;
            dmem[1] <= 32'd0;
            pending_rsp <= 1'b0;
            d_rsp_valid <= 1'b0;
            rsp_delay <= 0;
            accepted_requests <= 0;
            completed_responses <= 0;
            first_req_wait <= 0;
            saw_req_backpressure <= 1'b0;
            req_hold_active <= 1'b0;
            saw_load_use <= 1'b0;
            saw_rsp_wait <= 1'b0;
            accepted_d_context_valid <= 1'b0;
            accepted_then_hold_cycles <= 0;
            held_addr <= 0;
            held_wdata <= 0;
            held_write <= 0;
            held_wstrb <= 0;
        end else begin
            if (dut.load_use_stall)
                saw_load_use <= 1'b1;
            if (pending_rsp && !d_rsp_valid) begin
                saw_rsp_wait <= 1'b1;
                if (!dut.backend_hold)
                    $fatal(1, "pipeline was not held while waiting for D response");
                if (d_req_valid)
                    $fatal(1, "accepted D request was replayed before its response");
                if (accepted_d_context_valid &&
                    (dut.xm_pc !== accepted_d_pc || dut.xm_instr !== accepted_d_instr ||
                     dut.xm_alu !== accepted_d_alu || dut.xm_store_data !== accepted_d_store_data ||
                     dut.xm_rd !== accepted_d_rd || dut.xm_mem_read !== accepted_d_mem_read ||
                     dut.xm_mem_write !== accepted_d_mem_write || dut.xm_reg_write !== accepted_d_reg_write))
                    $fatal(1, "accepted D transaction context changed while backend held: pc=%h/%h instr=%h/%h", dut.xm_pc, accepted_d_pc, dut.xm_instr, accepted_d_instr);
                accepted_then_hold_cycles <= accepted_then_hold_cycles + 1;
            end
            if (d_req_valid && accepted_requests == 0 && first_req_wait < 3)
                first_req_wait <= first_req_wait + 1;
            if (d_req_valid && !d_req_ready && !saw_req_backpressure) begin
                saw_req_backpressure <= 1'b1;
            end
            if (d_req_valid && !d_req_ready && !req_hold_active) begin
                req_hold_active <= 1'b1;
                held_addr <= d_req_addr;
                held_wdata <= d_req_wdata;
                held_write <= d_req_write;
                held_wstrb <= d_req_wstrb;
            end
            if (req_hold_active && !d_req_ready &&
                (d_req_addr !== held_addr || d_req_wdata !== held_wdata ||
                 d_req_write !== held_write || d_req_wstrb !== held_wstrb))
                $fatal(1, "D request payload changed under backpressure: addr=%h/%h data=%h/%h write=%b/%b strb=%h/%h", d_req_addr, held_addr, d_req_wdata, held_wdata, d_req_write, held_write, d_req_wstrb, held_wstrb);
            if (d_req_valid && d_req_ready)
                req_hold_active <= 1'b0;
            if (d_req_valid && d_req_ready) begin
                if (accepted_requests == 0 && first_req_wait < 3)
                    $fatal(1, "first D request was not held for three cycles");
                accepted_d_context_valid <= 1'b1;
                accepted_d_pc <= dut.xm_pc;
                accepted_d_instr <= dut.xm_instr;
                accepted_d_alu <= dut.xm_alu;
                accepted_d_store_data <= dut.xm_store_data;
                accepted_d_rd <= dut.xm_rd;
                accepted_d_mem_read <= dut.xm_mem_read;
                accepted_d_mem_write <= dut.xm_mem_write;
                accepted_d_reg_write <= dut.xm_reg_write;
                accepted_requests <= accepted_requests + 1;
                pending_rsp <= 1'b1;
                rsp_delay <= 3;
                pending_addr <= d_req_addr;
                pending_write <= d_req_write;
                pending_wdata <= d_req_wdata;
                pending_wstrb <= d_req_wstrb;
            end
            if (pending_rsp && rsp_delay != 0)
                rsp_delay <= rsp_delay - 1'b1;
            if (pending_rsp && rsp_delay == 0 && !d_rsp_valid) begin
                d_rsp_valid <= 1'b1;
                d_rsp_rdata_q <= dmem[pending_addr[3:2]];
            end
            if (d_rsp_valid && d_rsp_ready) begin
                if (pending_write) begin
                    if (pending_wstrb[0]) dmem[pending_addr[3:2]][7:0] <= pending_wdata[7:0];
                    if (pending_wstrb[1]) dmem[pending_addr[3:2]][15:8] <= pending_wdata[15:8];
                    if (pending_wstrb[2]) dmem[pending_addr[3:2]][23:16] <= pending_wdata[23:16];
                    if (pending_wstrb[3]) dmem[pending_addr[3:2]][31:24] <= pending_wdata[31:24];
                end
                d_rsp_valid <= 1'b0;
                pending_rsp <= 1'b0;
                completed_responses <= completed_responses + 1;
            end
        end
    end

    cpu_core_stage1 dut (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(1'b0), .d_req_valid(d_req_valid),
        .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_rdata),
        .d_rsp_error(1'b0), .trace_valid(trace_valid), .trace_order(trace_order),
        .trace_pc(trace_pc), .trace_instr(trace_instr), .trace_rd(trace_rd),
        .trace_rd_data(trace_rd_data), .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        .timer_irq_i(1'b0), .ext_irq_i(1'b0)   // 批 (c)：基线行为测试不涉及中断
    );

    integer seen = 0;
    always @(negedge clk) begin
        if (!rst && trace_valid) begin
            case (seen)
                0: if (trace_pc !== 32'h00 || trace_rd !== 1 || trace_rd_data !== 1 || !trace_rd_we) $fatal(1, "retire 0 mismatch");
                1: if (trace_pc !== 32'h04 || trace_rd_we) $fatal(1, "branch retire mismatch");
                2: if (trace_pc !== 32'h0c || trace_rd !== 4 || trace_rd_data !== 7 || !trace_rd_we) $fatal(1, "delayed load retire mismatch");
                3: if (trace_pc !== 32'h10 || trace_rd_we) $fatal(1, "branch-after-load retire mismatch");
                4: if (trace_pc !== 32'h18 || trace_rd !== 2 || trace_rd_data !== 2 || !trace_rd_we) $fatal(1, "branch target retire mismatch");
                5: if (trace_pc !== 32'h1c || trace_rd !== 3 || trace_rd_data !== 3 || !trace_rd_we) $fatal(1, "retire 5 mismatch");
                6: if (trace_pc !== 32'h20 || trace_rd !== 5 || trace_rd_data !== 8 || !trace_rd_we) $fatal(1, "load-use retire mismatch");
                7: if (trace_pc !== 32'h24 || trace_rd_we) $fatal(1, "store retire mismatch");
                8: if (trace_pc !== 32'h28 || trace_rd !== 6 || trace_rd_data !== 8 || !trace_rd_we) $fatal(1, "load-after-store mismatch");
                9: if (trace_pc !== 32'h2c || trace_rd !== 7 || trace_rd_data !== 9 || !trace_rd_we) $fatal(1, "second load-use mismatch");
                10: if (trace_pc !== 32'h30 || trace_rd !== 0 || trace_rd_we) $fatal(1, "x0 retire mismatch");
                default: $fatal(1, "unexpected retirement pc=%h", trace_pc);
            endcase
            if (trace_order !== seen) $fatal(1, "trace order mismatch");
            $display("RETIRE %0d pc=%08h rd=x%0d data=%08h we=%b", trace_order, trace_pc, trace_rd, trace_rd_data, trace_rd_we);
            seen = seen + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        repeat (300) @(posedge clk);
        if (seen != 11) $fatal(1, "expected 11 retire events, got %0d", seen);
        if (accepted_requests != 3 || completed_responses != 3)
            $fatal(1, "D requests/responses mismatch accepted=%0d completed=%0d", accepted_requests, completed_responses);
        if (!saw_req_backpressure) $fatal(1, "test did not exercise D request backpressure");
        if (!saw_load_use) $fatal(1, "test did not exercise load-use interlock");
        if (!saw_rsp_wait) $fatal(1, "test did not exercise D response wait");
        if (accepted_then_hold_cycles < 3)
            $fatal(1, "accepted D request was not followed by a multi-cycle backend hold (cycles=%0d)", accepted_then_hold_cycles);
        if (dmem[1] !== 32'd8) $fatal(1, "store result mismatch: %h", dmem[1]);
        if (dut.u_regfile.regs[0] !== 32'd0 || dut.u_regfile.regs[1] !== 1 ||
            dut.u_regfile.regs[2] !== 2 || dut.u_regfile.regs[3] !== 3 ||
            dut.u_regfile.regs[4] !== 7 || dut.u_regfile.regs[5] !== 8 ||
            dut.u_regfile.regs[6] !== 8 || dut.u_regfile.regs[7] !== 9)
            $fatal(1, "register file mismatch");
        $display("PASS tb_cpu_core_stage1: 11 retirements; accepted D context held for %0d response-wait cycles; no D request replay; branch flush; load-use; delayed D ready/response; store once; x0=0", accepted_then_hold_cycles);
        $finish;
    end
endmodule
