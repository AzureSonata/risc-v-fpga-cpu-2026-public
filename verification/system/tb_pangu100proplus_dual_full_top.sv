`timescale 1ns/1ps

module tb_pangu100proplus_dual_full_top;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rstn = 1'b0;

    wire [7:0]  led;
    wire [31:0] gpio_out;
    wire        uart_tx;
    wire        trace0_valid, trace1_valid;
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] trace0_pc, trace0_instr, trace0_rd_data, trace0_cause;
    wire [31:0] trace1_pc, trace1_instr, trace1_rd_data, trace1_cause;
    wire [4:0]  trace0_rd, trace1_rd;
    wire        trace0_rd_we, trace0_trap, trace1_rd_we, trace1_trap;
    wire [31:0] pc_debug;

    integer trap_events = 0;
    integer issue_dual_events = 0;
    integer cold_load_alu_pairs = 0;
    integer warm_load_alu_pairs = 0;
    integer ordinary_alu_pair_issue_cycles = 0;
    integer ordinary_alu_pair_retire_cycles = 0;
    integer ordinary_alu_pair_errors = 0;
    integer bad_pair_order = 0;
    integer dcache_refill_beats = 0;
    integer consecutive_load_retire_count = 0;
    integer lsu_response_turnover_offers = 0;
    integer lsu_response_turnover_accepts = 0;
    integer unaccepted_dcache_requests = 0;
    reg [31:0] trap_cause_seen = 32'h0;

    always @(posedge clk) begin
        if (rstn) begin
            if ((trace0_valid && trace0_pc == 32'h0000_0048 && trace0_instr == 32'h0040_a383) ||
                (trace0_valid && trace0_pc == 32'h0000_004c && trace0_instr == 32'h0080_a403))
                consecutive_load_retire_count <= consecutive_load_retire_count + 1;
            if (trace0_valid) begin
                if (trace0_trap) begin
                    trap_events <= trap_events + 1;
                    trap_cause_seen <= trace0_cause;
                end
                if (trace1_valid) issue_dual_events <= issue_dual_events + 1;
                if (trace1_valid && trace0_pc == 32'h0000_0008 &&
                    trace0_instr == 32'h0000_a203 && trace1_pc == 32'h0000_000c &&
                    trace1_instr == 32'h1000_0593) begin
                    cold_load_alu_pairs <= cold_load_alu_pairs + 1;
                    if (trace1_order != trace0_order + 64'd1)
                        bad_pair_order <= bad_pair_order + 1;
                end
                if (trace1_valid && trace0_pc == 32'h0000_0038 &&
                    trace0_instr == 32'h0000_a283 && trace1_pc == 32'h0000_003c &&
                    trace1_instr == 32'h0070_0313) begin
                    warm_load_alu_pairs <= warm_load_alu_pairs + 1;
                    if (trace1_order != trace0_order + 64'd1)
                        bad_pair_order <= bad_pair_order + 1;
                end
                if (trace1_valid && trace0_pc == 32'h0000_0040 &&
                    trace0_instr == 32'h0000_1a37 && trace1_pc == 32'h0000_0044 &&
                    trace1_instr == 32'h0120_0a93) begin
                    ordinary_alu_pair_retire_cycles <= ordinary_alu_pair_retire_cycles + 1;
                    if (trace1_order != trace0_order + 64'd1 ||
                        trace0_rd != 5'd20 || trace0_rd_we !== 1'b1 ||
                        trace0_rd_data !== 32'h0000_1000 ||
                        trace1_rd != 5'd21 || trace1_rd_we !== 1'b1 ||
                        trace1_rd_data !== 32'h0000_0012) begin
                        ordinary_alu_pair_errors <= ordinary_alu_pair_errors + 1;
                        $display("ORDINARY_ALU_PAIR_TRACE_ERROR: pc=%08x/%08x rd=%0d/%0d data=%08x/%08x order=%0d/%0d",
                                 trace0_pc, trace1_pc, trace0_rd, trace1_rd,
                                 trace0_rd_data, trace1_rd_data, trace0_order, trace1_order);
                    end
                end
            end
            if (dut.u_cpu.issue0 && dut.u_cpu.issue1 &&
                dut.u_cpu.fq_out0_pc == 32'h0000_0040 &&
                dut.u_cpu.fq_out1_pc == 32'h0000_0044)
                ordinary_alu_pair_issue_cycles <= ordinary_alu_pair_issue_cycles + 1;
            if (dut.u_cpu.u_lsu.turnover_request)
                lsu_response_turnover_offers <= lsu_response_turnover_offers + 1;
            if (dut.u_cpu.u_lsu.turnover_request && dut.d_req_valid && dut.d_req_ready)
                lsu_response_turnover_accepts <= lsu_response_turnover_accepts + 1;
            if (dut.u_mem.d_cp_cache_req_valid && dut.u_mem.d_cp_cache_req_ready &&
                !(dut.d_req_valid && dut.d_req_ready))
                unaccepted_dcache_requests <= unaccepted_dcache_requests + 1;
            if (dut.u_mem.d_cp_beat_valid && dut.u_mem.d_cp_beat_ready)
                dcache_refill_beats <= dcache_refill_beats + 1;
        end
    end

    pangu100proplus_dual_full_top #(
        .ROM_INIT_FILE("verification/unit/dual_full_soc.hex"),
        .MEM_DEPTH(256), .MEM_AW(8), .UART_DIV(4),
        .ICACHE_ENABLE(1'b1), .DCACHE_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rstn(rstn),
        .gpio_in(32'h0), .uart_rx(1'b1),
        .led(led), .gpio_out(gpio_out), .uart_tx(uart_tx),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order),
        .trace0_pc(trace0_pc), .trace0_instr(trace0_instr),
        .trace0_rd(trace0_rd), .trace0_rd_data(trace0_rd_data),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap),
        .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order),
        .trace1_pc(trace1_pc), .trace1_instr(trace1_instr),
        .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap),
        .trace1_cause(trace1_cause),
        .pc_debug(pc_debug)
    );

    integer fail = 0;
    initial begin
        repeat (10) @(posedge clk);
        // Place each pair on one 64-bit fetch beat. The LW at PC 0x08 misses
        // into the real D-cache; its independent ADDI at PC 0x0c shares the beat.
        // The following SW hits that line. Seed SRAM as initial data before reset.
        {dut.u_mem.u_sram_d.mem3[0], dut.u_mem.u_sram_d.mem2[0], dut.u_mem.u_sram_d.mem1[0], dut.u_mem.u_sram_d.mem0[0]} = 32'h0000_0123;
        dut.u_mem.u_rom_i.mem[2] = 32'h0000_a203; // PC 0x08: lw   x4,0(x1)
        dut.u_mem.u_rom_i.mem[3] = 32'h1000_0593; // PC 0x0c: addi x11,x0,0x100
        dut.u_mem.u_rom_i.mem[4] = 32'h0030_a223; // PC 0x10: sw   x3,4(x1)

        // After timer setup, prepare the GPIO-input bypass address, run a
        // warm-hit load+ALU pair, then exercise cache→cache→bypass turnover.
        dut.u_mem.u_rom_i.mem[13] = 32'h1000_05b7; // PC 0x34: lui x11,0x10000
        dut.u_mem.u_rom_i.mem[14] = 32'h0000_a283; // PC 0x38: lw   x5,0(x1)
        dut.u_mem.u_rom_i.mem[15] = 32'h0070_0313; // PC 0x3c: addi x6,x0,7
        dut.u_mem.u_rom_i.mem[16] = 32'h0000_1a37; // PC 0x40: lui  x20,0x1
        dut.u_mem.u_rom_i.mem[17] = 32'h0120_0a93; // PC 0x44: addi x21,x0,0x12
        dut.u_mem.u_rom_i.mem[18] = 32'h0040_a383; // PC 0x48: lw   x7,4(x1)
        dut.u_mem.u_rom_i.mem[19] = 32'h0080_a403; // PC 0x4c: lw   x8,8(x1)
        dut.u_mem.u_rom_i.mem[20] = 32'h0145_a483; // PC 0x50: lw   x9,20(x11), bypass GPIO input
        dut.u_mem.u_rom_i.mem[21] = 32'h0000_006f; // PC 0x54: jal  x0,0
        rstn = 1'b1;
        repeat (20000) @(posedge clk);
        #1;

        if (dut.u_cpu.u_rf.regs[4] !== 32'h123) begin
            $display("FAIL: x4=0x%08x expected 0x123", dut.u_cpu.u_rf.regs[4]); fail=fail+1;
        end
        if (dut.u_cpu.u_rf.regs[10] !== 32'h80000007) begin
            $display("FAIL: x10=0x%08x expected 0x80000007", dut.u_cpu.u_rf.regs[10]); fail=fail+1;
        end
        if (dut.u_cpu.u_rf.regs[2] !== 32'h10000000) begin
            $display("FAIL: x2=0x%08x expected 0x10000000", dut.u_cpu.u_rf.regs[2]); fail=fail+1;
        end
        if ({dut.u_mem.u_sram_d.mem3[0], dut.u_mem.u_sram_d.mem2[0], dut.u_mem.u_sram_d.mem1[0], dut.u_mem.u_sram_d.mem0[0]} !== 32'h123) begin
            $display("FAIL: D-SRAM[0]=0x%08x expected 0x123", {dut.u_mem.u_sram_d.mem3[0], dut.u_mem.u_sram_d.mem2[0], dut.u_mem.u_sram_d.mem1[0], dut.u_mem.u_sram_d.mem0[0]}); fail=fail+1;
        end
        if ({dut.u_mem.u_sram_d.mem3[1], dut.u_mem.u_sram_d.mem2[1], dut.u_mem.u_sram_d.mem1[1], dut.u_mem.u_sram_d.mem0[1]} !== 32'h123) begin
            $display("FAIL: D-SRAM[1]=0x%08x expected 0x123 after store hit", {dut.u_mem.u_sram_d.mem3[1], dut.u_mem.u_sram_d.mem2[1], dut.u_mem.u_sram_d.mem1[1], dut.u_mem.u_sram_d.mem0[1]}); fail=fail+1;
        end
        if (dut.u_mem.u_timer.mtimecmp !== 32'hffffffff) begin
            $display("FAIL: mtimecmp=0x%08x expected 0xffffffff", dut.u_mem.u_timer.mtimecmp); fail=fail+1;
        end
        if (cold_load_alu_pairs !== 1) begin
            $display("FAIL: cold load+ALU paired retire count=%0d expected 1", cold_load_alu_pairs); fail=fail+1;
        end
        if (warm_load_alu_pairs !== 1) begin
            $display("FAIL: warm load+ALU paired retire count=%0d expected 1", warm_load_alu_pairs); fail=fail+1;
        end
        if (ordinary_alu_pair_issue_cycles !== 1) begin
            $display("FAIL: ordinary ALU pair issue cycles=%0d expected 1", ordinary_alu_pair_issue_cycles); fail=fail+1;
        end
        if (ordinary_alu_pair_retire_cycles !== 1 || ordinary_alu_pair_errors !== 0) begin
            $display("FAIL: ordinary ALU pair retire cycles/errors=%0d/%0d expected 1/0",
                     ordinary_alu_pair_retire_cycles, ordinary_alu_pair_errors); fail=fail+1;
        end
        if (bad_pair_order !== 0) begin
            $display("FAIL: paired retire order violations=%0d", bad_pair_order); fail=fail+1;
        end
        if (dut.u_mem.u_dcache.stat_miss !== 32'd1 ||
            dut.u_mem.u_dcache.stat_hit !== 32'd4) begin
            $display("FAIL: DCache hit/miss=%0d/%0d expected 4/1",
                     dut.u_mem.u_dcache.stat_hit, dut.u_mem.u_dcache.stat_miss); fail=fail+1;
        end
        if (dcache_refill_beats !== 4) begin
            $display("FAIL: DCache refill beats=%0d expected 4", dcache_refill_beats); fail=fail+1;
        end
        if (dut.u_cpu.u_rf.regs[5] !== 32'h123 || dut.u_cpu.u_rf.regs[6] !== 32'd7) begin
            $display("FAIL: warm pair result x5=0x%08x x6=0x%08x expected 0x123/7",
                     dut.u_cpu.u_rf.regs[5], dut.u_cpu.u_rf.regs[6]); fail=fail+1;
        end
        if (dut.u_cpu.u_rf.regs[7] !== 32'h123 || dut.u_cpu.u_rf.regs[8] !== 32'h0 ||
            dut.u_cpu.u_rf.regs[9] !== 32'h0 || consecutive_load_retire_count !== 2) begin
            $display("FAIL: consecutive loads x7/x8/x9=%08x/%08x/%08x retire_count=%0d",
                     dut.u_cpu.u_rf.regs[7], dut.u_cpu.u_rf.regs[8],
                     dut.u_cpu.u_rf.regs[9], consecutive_load_retire_count); fail=fail+1;
        end
        if (unaccepted_dcache_requests !== 0) begin
            $display("FAIL: D-cache accepted %0d requests without upstream handshake",
                     unaccepted_dcache_requests); fail=fail+1;
        end
        if (lsu_response_turnover_offers == 0 || lsu_response_turnover_accepts == 0) begin
            $display("FAIL: expected response-edge turnover; offers/accepts=%0d/%0d",
                     lsu_response_turnover_offers, lsu_response_turnover_accepts); fail=fail+1;
        end
        if (trap_events == 0) begin
            $display("FAIL: no timer interrupt trap observed"); fail=fail+1;
        end
        if (trap_cause_seen !== 32'h80000007) begin
            $display("FAIL: trap cause seen 0x%08x expected 0x80000007", trap_cause_seen); fail=fail+1;
        end

        $display("PANGU_DUAL_FULL: trap_events=%0d dual_events=%0d cold_pairs=%0d warm_pairs=%0d alu_issue=%0d alu_retire=%0d alu_errors=%0d consecutive_loads=%0d turnover=%0d/%0d dcache_ghosts=%0d DCache hit/miss=%0d/%0d refill_beats=%0d pc=0x%08x led=0x%02x",
                 trap_events, issue_dual_events, cold_load_alu_pairs, warm_load_alu_pairs,
                 ordinary_alu_pair_issue_cycles, ordinary_alu_pair_retire_cycles,
                 ordinary_alu_pair_errors, consecutive_load_retire_count,
                 lsu_response_turnover_offers, lsu_response_turnover_accepts,
                 unaccepted_dcache_requests,
                 dut.u_mem.u_dcache.stat_hit, dut.u_mem.u_dcache.stat_miss,
                 dcache_refill_beats, pc_debug, led);
        if (fail == 0) begin
            $display("PASS: 64-bit dual-issue core fetch through 32-bit adapter + ICache/ROM");
            $display("PASS: D-side store/load through cpu_mem_subsystem DCache + SRAM");
            $display("PASS: real timer MMIO raises machine timer interrupt and mret recovers");
            $display("ALL TESTS PASSED (pangu100proplus_dual_full_top)");
        end else begin
            $display("PANGU_DUAL_FULL_RESULT: FAIL failures=%0d", fail);
        end
        $finish;
    end

    initial begin
        #300000;
        $display("PANGU_DUAL_FULL_RESULT: TIMEOUT pc=0x%08x", pc_debug);
        $finish;
    end
endmodule
