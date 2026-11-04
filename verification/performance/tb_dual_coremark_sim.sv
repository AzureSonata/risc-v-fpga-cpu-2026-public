`timescale 1ns/1ps
// Full SoC measurement harness. All completion paths emit an explicit marker;
// timeout uses $fatal so a partial run cannot become a successful benchmark.
module tb_dual_coremark_sim;
    parameter integer DUAL = 1;
    parameter integer PREDICT_ENABLE = 1;
    parameter integer PRED_MODE = 0;
    parameter integer BTB_ENTRIES = 64;
    parameter integer ICACHE = 1;
    parameter integer DCACHE = 1;
    parameter integer WIDE_ICACHE = 1;
    parameter integer ICACHE_PREFETCH = 0;
    parameter integer UART_DIV = 434;
    reg clk = 0;
    reg rstn = 0;
    always #5 clk = ~clk;
    wire [7:0] led;
    wire [31:0] gpio_out, pc;
    wire uart_tx, t0v, t1v, t0trap, t1trap;
    wire [31:0] t0pc, t0ins, t0rd_data, t1pc, t1ins;
    wire [31:0] t1rd_data;
    wire [4:0] t0rd, t1rd;
    wire t0rd_we, t1rd_we;
    // Sample the value at the exact stage where the selected implementation
    // captures CSR read data, rather than at a variable-latency retirement.
`ifdef DUAL_FIVE_STAGE
    wire csr_sample_valid = dut.u_cpu.ex_fire && dut.u_cpu.id_ex0_q.csr &&
                            !dut.u_cpu.id_ex0_q.csr_we;
    wire [11:0] csr_sample_addr = dut.u_cpu.id_ex0_q.csr_addr;
    wire perf_lsu = dut.u_cpu.mem_active_q || dut.d_req_valid;
    wire perf_lsu_store = dut.u_cpu.mem_active_q ? dut.u_cpu.response_entry.store :
                                                    dut.d_req_write;
    wire perf_mdu = !dut.u_cpu.mdu_ready;
`else
    wire csr_sample_valid = dut.u_cpu.issue0 && dut.u_cpu.d0_is_csr && !dut.u_cpu.d0_csr_we;
    wire [11:0] csr_sample_addr = dut.u_cpu.d0_csr_addr;
`endif
    pangu100proplus_dual_full_top #(
        .ROM_INIT_FILE("coremark.hex"), .MEM_DEPTH(16384), .MEM_AW(14),
        .UART_DIV(UART_DIV), .M_MODE(2), .DUAL_ISSUE_EN(DUAL != 0),
        .PREDICT_ENABLE(PREDICT_ENABLE != 0),
        .PRED_MODE(PRED_MODE),
        .BTB_ENTRIES(BTB_ENTRIES),
        .ICACHE_ENABLE(ICACHE != 0), .DCACHE_ENABLE(DCACHE != 0),
        .ICACHE_NEXTLINE_PREFETCH(ICACHE_PREFETCH != 0)
`ifdef COREMARK_HAVE_WIDE_ICACHE
        , .WIDE_ICACHE_ENABLE(WIDE_ICACHE != 0)
`endif
    ) dut (
        .clk(clk), .rstn(rstn), .gpio_in(32'b0), .uart_rx(1'b1),
        .led(led), .gpio_out(gpio_out), .uart_tx(uart_tx),
        .trace0_valid(t0v), .trace0_order(), .trace0_pc(t0pc),
        .trace0_instr(t0ins), .trace0_rd(t0rd), .trace0_rd_data(t0rd_data),
        .trace0_rd_we(t0rd_we), .trace0_trap(t0trap), .trace0_cause(),
        .trace1_valid(t1v), .trace1_order(), .trace1_pc(t1pc), .trace1_instr(t1ins),
        .trace1_rd(t1rd), .trace1_rd_data(t1rd_data), .trace1_rd_we(t1rd_we),
        .trace1_trap(t1trap), .trace1_cause(), .pc_debug(pc)
    );

    longint unsigned total_cycles = 0, cycles = 0, max_cycles = 3000000;
    longint unsigned next_progress_cycle = 1000000;
    longint unsigned window_cycles = 2000000;
    longint unsigned issue0 = 0, issue1 = 0, retire0 = 0, retire1 = 0;
    longint unsigned redirect = 0, lsu = 0, mdu = 0, csr = 0;
    longint unsigned fetch = 0, progress = 0, other = 0;
    longint unsigned overlap_lsu = 0, overlap_mdu = 0, overlap_csr = 0;
    longint unsigned overlap_empty = 0, overlap_redirect = 0;
    longint unsigned raw_rs1 = 0, raw_rs2 = 0, waw = 0;
    longint unsigned offer1 = 0, blocked1 = 0, d_backpressure = 0;
    longint unsigned lane1_backend_blocked = 0;
    longint unsigned lane1_backend_redirect = 0, lane1_backend_lsu = 0;
    longint unsigned lane1_backend_mdu = 0, lane1_backend_csr = 0;
    longint unsigned lane1_backend_other = 0;
    longint unsigned lane1_lsu_lane0_nonalu = 0, lane1_lsu_lane0_hazard = 0;
    longint unsigned lane1_lsu_lane0_no_credit = 0, lane1_lsu_lane0_commit = 0;
    longint unsigned lane1_lsu_lane0_other = 0;
    longint unsigned lane1_lsu_lane0_mem = 0, lane1_lsu_lane0_mdu = 0;
    longint unsigned lane1_lsu_lane0_control = 0, lane1_lsu_lane0_csr_sys = 0;
    longint unsigned lane1_lsu_lane0_unknown = 0;
    longint unsigned lane1_pair_nonpairable = 0, lane1_pair_raw = 0;
    longint unsigned lane1_pair_waw = 0, lane1_pair_other = 0;
    longint unsigned lsu_primary_load = 0, lsu_primary_store = 0;
    longint unsigned lsu_state_idle = 0, lsu_state_req_wait = 0;
    longint unsigned lsu_state_wait_rsp = 0, lsu_state_misaligned = 0;
    longint unsigned lsu_state_unknown = 0;
    longint unsigned lsu_req_wait = 0, lsu_rsp_wait = 0, lsu_dcache_fill = 0;
    longint unsigned lsu_dcache_write = 0, lsu_dcache_resp = 0, lsu_pair_hold = 0;
    longint unsigned trap0 = 0, trap1 = 0, not_taken_redirect = 0;
    longint unsigned young_issue0 = 0, young_issue1 = 0;
    longint unsigned young_retire0 = 0, young_retire1 = 0;
    longint unsigned completion_replace0 = 0, completion_replace1 = 0;
    longint unsigned ih0 = 0, im0 = 0, dh0 = 0, dm0 = 0;
    longint unsigned quiet_cycles = 0;
    integer full_run = 0, start_kind = 0, use_start_pc = 0, uart_file;
    reg [31:0] start_pc = 0;
    reg active = 0, validation_seen = 0;
    integer mcycle_seq_state = 0, mcycle_samples = 0, mcycle_retries = 0;
    reg [31:0] mcycle_high_before = 0, mcycle_low_sample = 0;
    longint unsigned mcycle_window_start = 0, mcycle_window_stop = 0;
    longint unsigned mcycle_window_start_cycle = 0, mcycle_window_stop_cycle = 0;
    longint unsigned mcycle_candidate_cycle = 0;
    localparam integer PERF_METRIC_COUNT = 170;
    longint unsigned perf_candidate [0:PERF_METRIC_COUNT-1];
    longint unsigned perf_start [0:PERF_METRIC_COUNT-1];
    longint unsigned perf_stop [0:PERF_METRIC_COUNT-1];
    integer metric_i;
    longint unsigned ihc = 0, imc = 0, dhc = 0, dmc = 0;
    longint unsigned zr_redirect = 0, zr_head_ready = 0, zr_head_mem_wait = 0;
    longint unsigned zr_head_mdu_wait = 0, zr_head_ex_wait = 0;
    longint unsigned zr_no_completion_fetch_empty = 0, zr_other = 0;
    longint unsigned rom_read_accept = 0, rom_read_rsp = 0;
    longint unsigned rom_read_latency_sum = 0, rom_read_latency_max = 0;
    longint unsigned rom_read_start_cycle = 0;
    reg rom_read_pending = 0, rom_read_latency_in_window = 0;
    longint unsigned rom_latency_sum_start = 0, rom_latency_sum_stop = 0;
    longint unsigned rom_latency_max_start = 0, rom_latency_max_stop = 0;
    longint unsigned bp_query = 0, bp_hit = 0, bp_mispredict = 0;
    longint unsigned bpq0 = 0, bph0 = 0, bpm0 = 0, bpq1 = 0, bph1 = 0, bpm1 = 0;
    longint unsigned zr_head_mem_active = 0, zr_head_mem_held = 0;
    longint unsigned zr_head_mem_queued = 0, zr_head_mem_unclassified = 0;
    longint unsigned zr_head_mem_load = 0, zr_head_mem_store = 0;
    longint unsigned zr_head_mem_cacheable = 0, zr_head_mem_bypass = 0, zr_head_mem_refill = 0;
    longint unsigned zr_head_mem_dcache_idle = 0, zr_head_mem_dcache_write = 0;
    longint unsigned zr_head_mem_dcache_resp = 0, zr_head_mem_dcache_other = 0;
    longint unsigned zr_head_mem_dcache_resp_handoff = 0;
    longint unsigned zr_head_mem_dcache_write_accept = 0, zr_head_mem_dcache_write_wait = 0;
    longint unsigned zr_head_mem_dcache_write_rsp = 0;
    longint unsigned zr_other_front_valid = 0, zr_other_fq_slot1_only = 0, zr_other_head_invalid = 0;
    longint unsigned zr_other_head_exec_wait = 0, zr_other_head_exec_not_in_idex = 0;
    longint unsigned zr_other_head_executed_wait = 0, zr_other_residual = 0;
    longint unsigned zr_head_ready_next_commit0 = 0, zr_head_ready_next_commit1 = 0;
    longint unsigned zr_head_ready_next_no_match = 0;
    longint unsigned zr_other_head_exec_wait_ex_fire = 0;
    longint unsigned zr_other_head_executed_wait_mdu_done = 0;
    longint unsigned zr_other_head_executed_wait_mem_rsp = 0;
    longint unsigned zr_other_head_executed_wait_residual = 0;
    longint unsigned zr_other_front_issue0 = 0, zr_other_front_not_present = 0;
    longint unsigned zr_other_front_ex_slot_busy = 0, zr_other_front_branch_pair_kill = 0;
    longint unsigned zr_other_front_serial_busy = 0, zr_other_front_credit_full = 0;
    longint unsigned zr_other_front_serial_gate = 0, zr_other_front_issue_residual = 0;
    longint unsigned ex_source_wait_cycles = 0, ex_load_use_wait_cycles = 0;
    longint unsigned ex_nonload_dep_wait_cycles = 0, ex_load_use_wait_zero_retire = 0;
    longint unsigned zr_lu_redirect = 0, zr_lu_head_ready = 0, zr_lu_head_mem = 0;
    longint unsigned zr_lu_head_mdu = 0, zr_lu_head_ex = 0, zr_lu_fetch_empty = 0, zr_lu_other = 0;
    longint unsigned zr_rec_redirect = 0, zr_rec_head_ready = 0, zr_rec_head_mem = 0;
    longint unsigned zr_rec_head_mdu = 0, zr_rec_head_ex = 0, zr_rec_fetch_empty = 0, zr_rec_other = 0;
    longint unsigned zr_lsu_redirect = 0, zr_lsu_head_ready = 0, zr_lsu_head_mem = 0;
    longint unsigned zr_lsu_head_mdu = 0, zr_lsu_head_ex = 0, zr_lsu_fetch_empty = 0, zr_lsu_other = 0;
    integer zr_reason_sample = 0;
    longint unsigned branch_recovery_events = 0, branch_recovery_done = 0, branch_recovery_superseded = 0;
    longint unsigned branch_recovery_latency_sum = 0, branch_recovery_zero_retire = 0, branch_recovery_fq_empty = 0;
    reg branch_recovery_pending = 0, branch_recovery_active_sample = 0;
    reg [31:0] branch_recovery_target = 0;
    longint unsigned branch_recovery_start_cycle = 0;
    longint unsigned icpu_req_count = 0, icpu_rsp_count = 0, icpu_latency_sum = 0;
    longint unsigned icpu_miss_rsp_count = 0, icpu_miss_latency_sum = 0;
    longint unsigned icache_fill_done_count = 0, icache_fill_latency_sum = 0;
    reg icpu_pending = 0, icpu_pending_miss = 0, icache_fill_pending = 0;
    longint unsigned icpu_start_cycle = 0, icpu_miss_start_count = 0, icache_fill_start_cycle = 0;
    longint unsigned icpu_pending_zero_retire = 0;
    longint unsigned dcpu_req_count = 0, dcpu_rsp_count = 0, dcpu_latency_sum = 0;
    longint unsigned dcpu_miss_load_rsp_count = 0, dcpu_miss_store_rsp_count = 0, dcpu_miss_latency_sum = 0;
    longint unsigned dcache_load_fill_done_count = 0, dcache_load_fill_latency_sum = 0;
    reg dcpu_pending = 0, dcpu_pending_miss = 0, dcpu_pending_store = 0, dcache_load_fill_pending = 0;
    longint unsigned dcpu_start_cycle = 0, dcpu_miss_start_count = 0, dcache_load_fill_start_cycle = 0;
    longint unsigned dcpu_pending_zero_retire = 0;
    longint unsigned fetch_req_fire_count = 0, fetch_rsp_fire_count = 0;
    longint unsigned fetch_push_two_count = 0, fetch_push_low_count = 0, fetch_push_high_count = 0;
    longint unsigned fetch_redirect_halfblock_count = 0;
    reg zr_prev_head_ready = 0;
    reg [2:0] zr_prev_head_tag = 0;
`ifdef DUAL_FIVE_STAGE
    wire perf_load_use_dep =
        (dut.u_cpu.id_ex0_q.src1_pending && dut.u_cpu.q_valid[dut.u_cpu.id_ex0_q.src1_tag] &&
         !dut.u_cpu.q_ready[dut.u_cpu.id_ex0_q.src1_tag] &&
         dut.u_cpu.q_payload[dut.u_cpu.id_ex0_q.src1_tag][260:254] == 7'h03) ||
        (dut.u_cpu.id_ex0_q.src2_pending && dut.u_cpu.q_valid[dut.u_cpu.id_ex0_q.src2_tag] &&
         !dut.u_cpu.q_ready[dut.u_cpu.id_ex0_q.src2_tag] &&
         dut.u_cpu.q_payload[dut.u_cpu.id_ex0_q.src2_tag][260:254] == 7'h03) ||
        (dut.u_cpu.id_ex1_q.valid && dut.u_cpu.id_ex1_q.src1_pending &&
         dut.u_cpu.q_valid[dut.u_cpu.id_ex1_q.src1_tag] &&
         !dut.u_cpu.q_ready[dut.u_cpu.id_ex1_q.src1_tag] &&
         dut.u_cpu.q_payload[dut.u_cpu.id_ex1_q.src1_tag][260:254] == 7'h03) ||
        (dut.u_cpu.id_ex1_q.valid && dut.u_cpu.id_ex1_q.src2_pending &&
         dut.u_cpu.q_valid[dut.u_cpu.id_ex1_q.src2_tag] &&
         !dut.u_cpu.q_ready[dut.u_cpu.id_ex1_q.src2_tag] &&
         dut.u_cpu.q_payload[dut.u_cpu.id_ex1_q.src2_tag][260:254] == 7'h03);
    wire perf_load_use_wait = dut.u_cpu.id_ex0_q.valid && !dut.u_cpu.ex_sources_ready && perf_load_use_dep;
`endif
    longint unsigned ih1 = 0, im1 = 0, dh1 = 0, dm1 = 0;
    longint unsigned ipfc = 0, ipfhc = 0, ipf0 = 0, ipfh0 = 0, ipf1 = 0, ipfh1 = 0;
    string uart_line = "";
    task automatic capture_perf_candidate;
        begin
            perf_candidate[0] = issue0;
            perf_candidate[1] = issue1;
            perf_candidate[2] = retire0;
            perf_candidate[3] = retire1;
            perf_candidate[4] = redirect;
            perf_candidate[5] = lsu;
            perf_candidate[6] = mdu;
            perf_candidate[7] = csr;
            perf_candidate[8] = fetch;
            perf_candidate[9] = progress;
            perf_candidate[10] = other;
            perf_candidate[11] = overlap_lsu;
            perf_candidate[12] = overlap_mdu;
            perf_candidate[13] = overlap_csr;
            perf_candidate[14] = overlap_empty;
            perf_candidate[15] = overlap_redirect;
            perf_candidate[16] = raw_rs1;
            perf_candidate[17] = raw_rs2;
            perf_candidate[18] = waw;
            perf_candidate[19] = offer1;
            perf_candidate[20] = blocked1;
            perf_candidate[21] = lane1_backend_blocked;
            perf_candidate[22] = lane1_backend_redirect;
            perf_candidate[23] = lane1_backend_lsu;
            perf_candidate[24] = lane1_backend_mdu;
            perf_candidate[25] = lane1_backend_csr;
            perf_candidate[26] = lane1_backend_other;
            perf_candidate[27] = lane1_pair_nonpairable;
            perf_candidate[28] = lane1_pair_raw;
            perf_candidate[29] = lane1_pair_waw;
            perf_candidate[30] = lane1_pair_other;
            perf_candidate[31] = lsu_primary_load;
            perf_candidate[32] = lsu_primary_store;
            perf_candidate[33] = lsu_state_idle;
            perf_candidate[34] = lsu_state_req_wait;
            perf_candidate[35] = lsu_state_wait_rsp;
            perf_candidate[36] = lsu_state_misaligned;
            perf_candidate[37] = lsu_state_unknown;
            perf_candidate[38] = d_backpressure;
            perf_candidate[39] = lsu_req_wait;
            perf_candidate[40] = lsu_rsp_wait;
            perf_candidate[41] = lsu_dcache_fill;
            perf_candidate[42] = lsu_dcache_write;
            perf_candidate[43] = lsu_dcache_resp;
            perf_candidate[44] = lsu_pair_hold;
            perf_candidate[45] = trap0;
            perf_candidate[46] = trap1;
            perf_candidate[47] = not_taken_redirect;
            perf_candidate[48] = young_issue0;
            perf_candidate[49] = young_issue1;
            perf_candidate[50] = young_retire0;
            perf_candidate[51] = young_retire1;
            perf_candidate[52] = completion_replace0;
            perf_candidate[53] = completion_replace1;
            perf_candidate[54] = lane1_lsu_lane0_nonalu;
            perf_candidate[55] = lane1_lsu_lane0_hazard;
            perf_candidate[56] = lane1_lsu_lane0_no_credit;
            perf_candidate[57] = lane1_lsu_lane0_commit;
            perf_candidate[58] = lane1_lsu_lane0_other;
            perf_candidate[59] = lane1_lsu_lane0_mem;
            perf_candidate[60] = lane1_lsu_lane0_mdu;
            perf_candidate[61] = lane1_lsu_lane0_control;
            perf_candidate[62] = lane1_lsu_lane0_csr_sys;
            perf_candidate[63] = lane1_lsu_lane0_unknown;
            perf_candidate[64] = zr_redirect;
            perf_candidate[65] = zr_head_ready;
            perf_candidate[66] = zr_head_mem_wait;
            perf_candidate[67] = zr_head_mdu_wait;
            perf_candidate[68] = zr_head_ex_wait;
            perf_candidate[69] = zr_no_completion_fetch_empty;
            perf_candidate[70] = zr_other;
            perf_candidate[71] = rom_read_accept;
            perf_candidate[72] = rom_read_rsp;
            bp_query = dut.u_cpu.u_fetch.g_predictor.u_predictor.stat_query;
            bp_hit = dut.u_cpu.u_fetch.g_predictor.u_predictor.stat_hit;
            bp_mispredict = dut.u_cpu.u_fetch.g_predictor.u_predictor.stat_mispredict;
            perf_candidate[73] = bp_query;
            perf_candidate[74] = bp_hit;
            perf_candidate[75] = bp_mispredict;
            perf_candidate[76] = zr_head_mem_active;
            perf_candidate[77] = zr_head_mem_held;
            perf_candidate[78] = zr_head_mem_queued;
            perf_candidate[79] = zr_head_mem_unclassified;
            perf_candidate[80] = zr_head_mem_load;
            perf_candidate[81] = zr_head_mem_store;
            perf_candidate[82] = zr_head_mem_cacheable;
            perf_candidate[83] = zr_head_mem_bypass;
            perf_candidate[84] = zr_head_mem_refill;
            perf_candidate[85] = zr_other_front_valid;
            perf_candidate[86] = zr_other_fq_slot1_only;
            perf_candidate[87] = zr_other_head_invalid;
            perf_candidate[88] = zr_other_head_exec_wait;
            perf_candidate[89] = zr_other_head_exec_not_in_idex;
            perf_candidate[90] = zr_other_head_executed_wait;
            perf_candidate[91] = zr_other_residual;
            perf_candidate[92] = zr_head_ready_next_commit0;
            perf_candidate[93] = zr_head_ready_next_commit1;
            perf_candidate[94] = zr_head_ready_next_no_match;
            perf_candidate[95] = zr_other_head_exec_wait_ex_fire;
            perf_candidate[96] = zr_other_head_executed_wait_mdu_done;
            perf_candidate[97] = zr_other_head_executed_wait_mem_rsp;
            perf_candidate[98] = zr_other_head_executed_wait_residual;
            perf_candidate[99] = zr_other_front_issue0;
            perf_candidate[100] = zr_other_front_not_present;
            perf_candidate[101] = zr_other_front_ex_slot_busy;
            perf_candidate[102] = zr_other_front_branch_pair_kill;
            perf_candidate[103] = zr_other_front_serial_busy;
            perf_candidate[104] = zr_other_front_credit_full;
            perf_candidate[105] = zr_other_front_serial_gate;
            perf_candidate[106] = zr_other_front_issue_residual;
            perf_candidate[107] = ex_source_wait_cycles;
            perf_candidate[108] = ex_load_use_wait_cycles;
            perf_candidate[109] = ex_nonload_dep_wait_cycles;
            perf_candidate[110] = ex_load_use_wait_zero_retire;
            perf_candidate[111] = branch_recovery_events;
            perf_candidate[112] = branch_recovery_done;
            perf_candidate[113] = branch_recovery_superseded;
            perf_candidate[114] = branch_recovery_latency_sum;
            perf_candidate[115] = branch_recovery_zero_retire;
            perf_candidate[116] = branch_recovery_fq_empty;
            perf_candidate[117] = icpu_req_count;
            perf_candidate[118] = icpu_rsp_count;
            perf_candidate[119] = icpu_latency_sum;
            perf_candidate[120] = icpu_miss_rsp_count;
            perf_candidate[121] = icpu_miss_latency_sum;
            perf_candidate[122] = icache_fill_done_count;
            perf_candidate[123] = icache_fill_latency_sum;
            perf_candidate[124] = dcpu_req_count;
            perf_candidate[125] = dcpu_rsp_count;
            perf_candidate[126] = dcpu_latency_sum;
            perf_candidate[127] = dcpu_miss_load_rsp_count;
            perf_candidate[128] = dcpu_miss_store_rsp_count;
            perf_candidate[129] = dcpu_miss_latency_sum;
            perf_candidate[130] = dcache_load_fill_done_count;
            perf_candidate[131] = dcache_load_fill_latency_sum;
            perf_candidate[132] = fetch_req_fire_count;
            perf_candidate[133] = fetch_rsp_fire_count;
            perf_candidate[134] = fetch_push_two_count;
            perf_candidate[135] = fetch_push_low_count;
            perf_candidate[136] = fetch_push_high_count;
            perf_candidate[137] = fetch_redirect_halfblock_count;
            perf_candidate[138] = icpu_pending_zero_retire;
            perf_candidate[139] = dcpu_pending_zero_retire;
            perf_candidate[140] = zr_lu_redirect;
            perf_candidate[141] = zr_lu_head_ready;
            perf_candidate[142] = zr_lu_head_mem;
            perf_candidate[143] = zr_lu_head_mdu;
            perf_candidate[144] = zr_lu_head_ex;
            perf_candidate[145] = zr_lu_fetch_empty;
            perf_candidate[146] = zr_lu_other;
            perf_candidate[147] = zr_rec_redirect;
            perf_candidate[148] = zr_rec_head_ready;
            perf_candidate[149] = zr_rec_head_mem;
            perf_candidate[150] = zr_rec_head_mdu;
            perf_candidate[151] = zr_rec_head_ex;
            perf_candidate[152] = zr_rec_fetch_empty;
            perf_candidate[153] = zr_rec_other;
            perf_candidate[154] = zr_lsu_redirect;
            perf_candidate[155] = zr_lsu_head_ready;
            perf_candidate[156] = zr_lsu_head_mem;
            perf_candidate[157] = zr_lsu_head_mdu;
            perf_candidate[158] = zr_lsu_head_ex;
            perf_candidate[159] = zr_lsu_fetch_empty;
            perf_candidate[160] = zr_lsu_other;
            perf_candidate[161] = zr_head_mem_dcache_idle;
            perf_candidate[162] = zr_head_mem_refill;
            perf_candidate[163] = zr_head_mem_dcache_write;
            perf_candidate[164] = zr_head_mem_dcache_resp;
            perf_candidate[165] = zr_head_mem_dcache_other;
            perf_candidate[166] = zr_head_mem_dcache_resp_handoff;
            perf_candidate[167] = zr_head_mem_dcache_write_accept;
            perf_candidate[168] = zr_head_mem_dcache_write_wait;
            perf_candidate[169] = zr_head_mem_dcache_write_rsp;
            ihc = dut.u_mem.u_icache.stat_hit;
            imc = dut.u_mem.u_icache.stat_miss;
            ipfc = dut.u_mem.u_icache.stat_prefetch;
            ipfhc = dut.u_mem.u_icache.stat_prefetch_hit;
            dhc = dut.u_mem.u_dcache.stat_hit;
            dmc = dut.u_mem.u_dcache.stat_miss;
            rom_latency_sum_start = rom_read_latency_sum;
            rom_read_latency_max = 0;
            bpq0 = bp_query;
            bph0 = bp_hit;
            bpm0 = bp_mispredict;
        end
    endtask

    task automatic commit_perf_start;
        begin
            for (metric_i = 0; metric_i < PERF_METRIC_COUNT; metric_i = metric_i + 1)
                perf_start[metric_i] = perf_candidate[metric_i];
            ih0 = ihc;
            im0 = imc;
            ipf0 = ipfc;
            ipfh0 = ipfhc;
            dh0 = dhc;
            dm0 = dmc;
        end
    endtask

    task automatic commit_perf_stop;
        begin
            for (metric_i = 0; metric_i < PERF_METRIC_COUNT; metric_i = metric_i + 1)
                perf_stop[metric_i] = perf_candidate[metric_i];
            ih1 = ihc;
            im1 = imc;
            ipf1 = ipfc;
            ipfh1 = ipfhc;
            dh1 = dhc;
            dm1 = dmc;
            rom_latency_sum_stop = rom_read_latency_sum;
            rom_latency_max_stop = rom_read_latency_max;
            bpq1 = bp_query;
            bph1 = bp_hit;
            bpm1 = bp_mispredict;
        end
    endtask

    function automatic longint unsigned perf_delta(input integer index);
        perf_delta = perf_stop[index] - perf_start[index];
    endfunction

    function automatic bit contains(input string haystack, input string needle);
        integer k;
        contains = 0;
        if (haystack.len() >= needle.len())
            for (k = 0; k <= haystack.len() - needle.len(); k = k + 1)
                if (haystack.substr(k, k + needle.len() - 1) == needle)
                    contains = 1;
    endfunction

    task automatic summary;
        $display("PERF_JSON {\"cycles\":%0d,\"total_cycles\":%0d,\"mcycle_samples\":%0d,\"mcycle_retries\":%0d,\"mcycle_window_start\":%0d,\"mcycle_window_stop\":%0d,\"mcycle_window_start_cycle\":%0d,\"mcycle_window_stop_cycle\":%0d,\"issue0\":%0d,\"issue1\":%0d,\"retire0\":%0d,\"retire1\":%0d,\"primary_redirect\":%0d,\"primary_lsu\":%0d,\"primary_mdu\":%0d,\"primary_csr\":%0d,\"primary_fetch_wait\":%0d,\"primary_issue_progress\":%0d,\"primary_other_wait\":%0d,\"overlap_lsu\":%0d,\"overlap_mdu\":%0d,\"overlap_csr\":%0d,\"overlap_fq_empty\":%0d,\"overlap_redirect\":%0d,\"pair_raw_rs1\":%0d,\"pair_raw_rs2\":%0d,\"pair_waw\":%0d,\"lane1_offer\":%0d,\"lane1_blocked\":%0d,\"lane1_backend_blocked\":%0d,\"lane1_backend_redirect\":%0d,\"lane1_backend_lsu\":%0d,\"lane1_backend_mdu\":%0d,\"lane1_backend_csr\":%0d,\"lane1_backend_other\":%0d,\"lane1_pair_nonpairable\":%0d,\"lane1_pair_raw\":%0d,\"lane1_pair_waw\":%0d,\"lane1_pair_other\":%0d,\"lsu_primary_load\":%0d,\"lsu_primary_store\":%0d,\"lsu_state_idle\":%0d,\"lsu_state_req_wait\":%0d,\"lsu_state_wait_rsp\":%0d,\"lsu_state_misaligned\":%0d,\"lsu_state_unknown\":%0d,\"dreq_backpressure\":%0d,\"lsu_req_wait\":%0d,\"lsu_rsp_wait\":%0d,\"lsu_dcache_fill\":%0d,\"lsu_dcache_write\":%0d,\"lsu_dcache_resp\":%0d,\"lsu_pair_hold\":%0d,\"trap0\":%0d,\"trap1\":%0d,\"not_taken_redirect\":%0d,\"young_issue0\":%0d,\"young_issue1\":%0d,\"young_retire0\":%0d,\"young_retire1\":%0d,\"completion_replace_issue0\":%0d,\"completion_replace_issue1\":%0d,\"icache_hits\":%0d,\"icache_misses\":%0d,\"icache_prefetch_started\":%0d,\"icache_prefetch_served\":%0d,\"dcache_hits\":%0d,\"dcache_misses\":%0d}",
            cycles, total_cycles, mcycle_samples, mcycle_retries,
            mcycle_window_start, mcycle_window_stop,
            mcycle_window_start_cycle, mcycle_window_stop_cycle,
            perf_delta(0), perf_delta(1), perf_delta(2), perf_delta(3),
            perf_delta(4), perf_delta(5), perf_delta(6), perf_delta(7), perf_delta(8), perf_delta(9), perf_delta(10),
            perf_delta(11), perf_delta(12), perf_delta(13), perf_delta(14), perf_delta(15),
            perf_delta(16), perf_delta(17), perf_delta(18), perf_delta(19), perf_delta(20),
            perf_delta(21), perf_delta(22), perf_delta(23), perf_delta(24), perf_delta(25), perf_delta(26),
            perf_delta(27), perf_delta(28), perf_delta(29), perf_delta(30),
            perf_delta(31), perf_delta(32), perf_delta(33), perf_delta(34), perf_delta(35),
            perf_delta(36), perf_delta(37), perf_delta(38), perf_delta(39), perf_delta(40),
            perf_delta(41), perf_delta(42), perf_delta(43), perf_delta(44),
            perf_delta(45), perf_delta(46), perf_delta(47),
            perf_delta(48), perf_delta(49), perf_delta(50), perf_delta(51),
            perf_delta(52), perf_delta(53),
            full_run ? ih1 - ih0 : dut.u_mem.u_icache.stat_hit - ih0,
            full_run ? im1 - im0 : dut.u_mem.u_icache.stat_miss - im0,
            full_run ? ipf1 - ipf0 : dut.u_mem.u_icache.stat_prefetch - ipf0,
            full_run ? ipfh1 - ipfh0 : dut.u_mem.u_icache.stat_prefetch_hit - ipfh0,
            full_run ? dh1 - dh0 : dut.u_mem.u_dcache.stat_hit - dh0,
            full_run ? dm1 - dm0 : dut.u_mem.u_dcache.stat_miss - dm0);
        $display("PERF_DETAIL_JSON {\"lane1_lsu_lane0_nonalu\":%0d,\"lane1_lsu_lane0_hazard\":%0d,\"lane1_lsu_lane0_no_credit\":%0d,\"lane1_lsu_lane0_commit\":%0d,\"lane1_lsu_lane0_other\":%0d}",
                 perf_delta(54), perf_delta(55), perf_delta(56), perf_delta(57), perf_delta(58));
        $display("PERF_CLASS_JSON {\"lane1_lsu_lane0_mem\":%0d,\"lane1_lsu_lane0_mdu\":%0d,\"lane1_lsu_lane0_control\":%0d,\"lane1_lsu_lane0_csr_sys\":%0d,\"lane1_lsu_lane0_unknown\":%0d}",
                 perf_delta(59), perf_delta(60), perf_delta(61), perf_delta(62), perf_delta(63));
        $display("PERF_ATTR_JSON {\"zero_retire_redirect\":%0d,\"zero_retire_head_ready\":%0d,\"zero_retire_head_mem_wait\":%0d,\"zero_retire_head_mdu_wait\":%0d,\"zero_retire_head_ex_wait\":%0d,\"zero_retire_no_completion_fetch_empty\":%0d,\"zero_retire_other\":%0d,\"rom_read_accept\":%0d,\"rom_read_response\":%0d,\"rom_read_latency_sum_cycles\":%0d,\"rom_read_latency_max_cycles\":%0d,\"predictor_query\":%0d,\"predictor_hit\":%0d,\"predictor_mispredict\":%0d,\"zero_retire_head_mem_active\":%0d,\"zero_retire_head_mem_held_request\":%0d,\"zero_retire_head_mem_queued_offer\":%0d,\"zero_retire_head_mem_unclassified\":%0d,\"zero_retire_head_mem_load\":%0d,\"zero_retire_head_mem_store\":%0d,\"zero_retire_head_mem_cacheable\":%0d,\"zero_retire_head_mem_bypass\":%0d,\"zero_retire_head_mem_refill\":%0d,\"zero_retire_other_front_valid\":%0d,\"zero_retire_other_fq_slot1_only\":%0d,\"zero_retire_other_head_invalid\":%0d,\"zero_retire_other_head_exec_wait\":%0d,\"zero_retire_other_head_exec_not_in_idex\":%0d,\"zero_retire_other_head_executed_wait\":%0d,\"zero_retire_other_residual\":%0d,\"zero_retire_head_ready_next_commit0\":%0d,\"zero_retire_head_ready_next_commit1\":%0d,\"zero_retire_head_ready_next_no_match\":%0d,\"zero_retire_other_head_exec_wait_ex_fire\":%0d,\"zero_retire_other_head_executed_wait_mdu_done\":%0d,\"zero_retire_other_head_executed_wait_mem_rsp\":%0d,\"zero_retire_other_head_executed_wait_residual\":%0d}",
                 perf_delta(64), perf_delta(65), perf_delta(66), perf_delta(67), perf_delta(68),
                 perf_delta(69), perf_delta(70), perf_delta(71), perf_delta(72),
                 rom_latency_sum_stop - rom_latency_sum_start,
                 rom_latency_max_stop,
                 perf_delta(73), perf_delta(74), perf_delta(75),
                 perf_delta(76), perf_delta(77), perf_delta(78), perf_delta(79),
                 perf_delta(80), perf_delta(81), perf_delta(82), perf_delta(83), perf_delta(84),
                 perf_delta(85), perf_delta(86), perf_delta(87), perf_delta(88), perf_delta(89),
                 perf_delta(90), perf_delta(91), perf_delta(92), perf_delta(93), perf_delta(94),
                 perf_delta(95), perf_delta(96), perf_delta(97), perf_delta(98));
        $display("PERF_FRONT_JSON {\"other_front_issue0\":%0d,\"other_front_not_present\":%0d,\"other_front_ex_slot_busy\":%0d,\"other_front_branch_pair_kill\":%0d,\"other_front_serial_busy\":%0d,\"other_front_credit_full\":%0d,\"other_front_serial_gate\":%0d,\"other_front_issue_residual\":%0d}",
                 perf_delta(99), perf_delta(100), perf_delta(101), perf_delta(102),
                 perf_delta(103), perf_delta(104), perf_delta(105), perf_delta(106));
        $display("PERF_DEP_JSON {\"ex_source_wait_cycles\":%0d,\"ex_load_use_wait_cycles\":%0d,\"ex_nonload_dep_wait_cycles\":%0d,\"ex_load_use_wait_zero_retire\":%0d}",
                 perf_delta(107), perf_delta(108), perf_delta(109), perf_delta(110));
        $display("PERF_RECOVERY_JSON {\"branch_recovery_events\":%0d,\"branch_recovery_done\":%0d,\"branch_recovery_superseded\":%0d,\"branch_recovery_latency_sum\":%0d,\"branch_recovery_zero_retire\":%0d,\"branch_recovery_fq_empty\":%0d}",
                 perf_delta(111), perf_delta(112), perf_delta(113), perf_delta(114), perf_delta(115), perf_delta(116));
        $display("PERF_CACHE_LATENCY_JSON {\"icpu_req_count\":%0d,\"icpu_rsp_count\":%0d,\"icpu_latency_sum\":%0d,\"icpu_miss_rsp_count\":%0d,\"icpu_miss_latency_sum\":%0d,\"icache_fill_done_count\":%0d,\"icache_fill_latency_sum\":%0d,\"icpu_pending_zero_retire\":%0d,\"dcpu_req_count\":%0d,\"dcpu_rsp_count\":%0d,\"dcpu_latency_sum\":%0d,\"dcpu_miss_load_rsp_count\":%0d,\"dcpu_miss_store_rsp_count\":%0d,\"dcpu_miss_latency_sum\":%0d,\"dcache_load_fill_done_count\":%0d,\"dcache_load_fill_latency_sum\":%0d,\"dcpu_pending_zero_retire\":%0d}",
                 perf_delta(117), perf_delta(118), perf_delta(119), perf_delta(120), perf_delta(121), perf_delta(122), perf_delta(123),
                 perf_delta(138), perf_delta(124), perf_delta(125), perf_delta(126), perf_delta(127), perf_delta(128), perf_delta(129),
                 perf_delta(130), perf_delta(131), perf_delta(139));
        $display("PERF_FETCH_JSON {\"fetch_req_fire\":%0d,\"fetch_rsp_fire\":%0d,\"fetch_push_two\":%0d,\"fetch_push_low\":%0d,\"fetch_push_high\":%0d,\"redirect_halfblock\":%0d}",
                 perf_delta(132), perf_delta(133), perf_delta(134), perf_delta(135), perf_delta(136), perf_delta(137));
        $display("PERF_CROSS_JSON {\"loaduse_redirect\":%0d,\"loaduse_head_ready\":%0d,\"loaduse_head_mem\":%0d,\"loaduse_head_mdu\":%0d,\"loaduse_head_ex\":%0d,\"loaduse_fetch_empty\":%0d,\"loaduse_other\":%0d,\"recovery_redirect\":%0d,\"recovery_head_ready\":%0d,\"recovery_head_mem\":%0d,\"recovery_head_mdu\":%0d,\"recovery_head_ex\":%0d,\"recovery_fetch_empty\":%0d,\"recovery_other\":%0d,\"lsu_redirect\":%0d,\"lsu_head_ready\":%0d,\"lsu_head_mem\":%0d,\"lsu_head_mdu\":%0d,\"lsu_head_ex\":%0d,\"lsu_fetch_empty\":%0d,\"lsu_other\":%0d}",
                 perf_delta(140), perf_delta(141), perf_delta(142), perf_delta(143), perf_delta(144),
                 perf_delta(145), perf_delta(146), perf_delta(147), perf_delta(148), perf_delta(149),
                 perf_delta(150), perf_delta(151), perf_delta(152), perf_delta(153), perf_delta(154),
                 perf_delta(155), perf_delta(156), perf_delta(157), perf_delta(158), perf_delta(159),
                 perf_delta(160));
        $display("PERF_HEAD_MEMSTATE_JSON {\"dcache_idle\":%0d,\"dcache_fill\":%0d,\"dcache_write\":%0d,\"dcache_resp\":%0d,\"dcache_other\":%0d,\"dcache_resp_handoff\":%0d}",
                 perf_delta(161), perf_delta(162), perf_delta(163), perf_delta(164), perf_delta(165),
                 perf_delta(166));
        $display("PERF_HEAD_MEMWRITE_JSON {\"write_beat_accept\":%0d,\"write_beat_wait\":%0d,\"cpu_rsp_handoff\":%0d}",
                 perf_delta(167), perf_delta(168), perf_delta(169));
    endtask

    // Observe the physical UART output, not a testbench-generated expected value.
    reg [7:0] uart_byte;
    integer bit_index;
    initial begin
        uart_file = $fopen("uart.raw", "wb");
        if (uart_file == 0) $fatal(1, "SIM_ERROR cannot open uart.raw");
        forever begin
            @(negedge uart_tx);
            if (rstn) begin
                repeat (UART_DIV / 2) @(posedge clk);
                if (uart_tx == 0) begin
                    for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                        repeat (UART_DIV) @(posedge clk);
                        uart_byte[bit_index] = uart_tx;
                    end
                    repeat (UART_DIV) @(posedge clk);
                    if (uart_tx != 1) $fatal(1, "SIM_ERROR UART framing error");
                    $fwrite(uart_file, "%c", uart_byte);
                    $fflush(uart_file);
                    quiet_cycles = 0;
                    if (uart_byte == 8'h0a) begin
                        $display("UART_LINE %s", uart_line);
                        if (contains(uart_line, "Correct operation validated") ||
                            contains(uart_line, "Errors detected") ||
                            contains(uart_line, "Cannot validate operation"))
                            validation_seen = 1;
                        uart_line = "";
                    end else if (uart_byte != 8'h0d) begin
                        uart_line = {uart_line, string'(uart_byte)};
                    end
                end
            end
        end
    end

    initial begin
        if ($value$plusargs("window_cycles=%d", window_cycles)) begin end
        if ($value$plusargs("max_cycles=%d", max_cycles)) begin end
        if ($value$plusargs("full_run=%d", full_run)) begin end
        if ($value$plusargs("start_kind=%d", start_kind)) begin end
        if ($value$plusargs("start_pc=%h", start_pc)) use_start_pc = 1;
        repeat (8) @(negedge clk);
        rstn = 1;
    end

    always @(posedge clk) begin
        if (rstn) begin
            total_cycles = total_cycles + 1;
            if (total_cycles >= next_progress_cycle) begin
`ifdef DUAL_FIVE_STAGE
                $display("SIM_PROGRESS total=%0d active=%0d pc=%08x retire=%b:%08x:%08x occupancy=%0d head=%0d tail=%0d ex=%b sources=%b mem=%b req=%b/%b rsp=%b cache=%0d",
                         total_cycles, active, pc, t0v, t0pc, t0ins,
                         dut.u_cpu.count_q, dut.u_cpu.head_q, dut.u_cpu.tail_q,
                         dut.u_cpu.ex_fire, dut.u_cpu.ex_sources_ready,
                         dut.u_cpu.mem_active_q, dut.d_req_valid, dut.d_req_ready,
                         dut.d_rsp_valid, dut.u_mem.u_dcache.state);
`else
                $display("SIM_PROGRESS total=%0d active=%0d pc=%08x retire=%b:%08x:%08x a0=%08x a1=%08x a2=%08x a3=%08x a4=%08x a5=%08x a6=%08x s2=%08x young=%0d/%b%b lsu=%b:%0d req=%b/%b rsp=%b cache=%0d",
                         total_cycles, active, pc, t0v, t0pc, t0ins,
                         dut.u_cpu.u_rf.regs[10], dut.u_cpu.u_rf.regs[11],
                         dut.u_cpu.u_rf.regs[12], dut.u_cpu.u_rf.regs[13],
                         dut.u_cpu.u_rf.regs[14], dut.u_cpu.u_rf.regs[15],
                         dut.u_cpu.u_rf.regs[16], dut.u_cpu.u_rf.regs[18],
                         dut.u_cpu.young_count_q, dut.u_cpu.young_ex0_valid_q,
                         dut.u_cpu.young_ex1_valid_q,
                         dut.u_cpu.r0_mem_pending_q, dut.u_cpu.u_lsu.state_q,
                         dut.d_req_valid, dut.d_req_ready, dut.d_rsp_valid,
                         dut.u_mem.u_dcache.state);
`endif
                $display("SIM_DPATH addr=%08x wr=%b rsp_ready=%b dcache_req=%b/%b rsp_q=%b cache_lock=%b cache_sel=%b cache_owner=%b cache_rsp=%b/%b bridge_state=%0d adapter_owner=%b",
                         dut.d_req_addr, dut.d_req_write, dut.d_rsp_ready,
                         dut.u_mem.d_cp_cache_req_valid, dut.u_mem.d_cp_cache_req_ready,
                         dut.u_mem.u_dcache.rsp_valid_q,
                         dut.u_mem.u_cache_path_d.path_locked,
                         dut.u_mem.u_cache_path_d.path_sel_q,
                         dut.u_mem.u_cache_path_d.cache_response_owner,
                         dut.u_mem.u_cache_path_d.cache_rsp_valid,
                         dut.u_mem.u_cache_path_d.cache_rsp_ready,
                         dut.u_mem.u_bridge_d.state, dut.u_mem.d_path_drives_adp);
                next_progress_cycle = next_progress_cycle + 1000000;
            end
            // Sample the CSR value at issue, where the core latches it into
            // the instruction's retirement shadow. Using retirement trace
            // timestamps shifts the window by variable pipeline latency.
            if (full_run && csr_sample_valid) begin
                case (csr_sample_addr)
                    12'hB80: begin
                        if (mcycle_seq_state == 2) begin
                            if (dut.u_cpu.csr_rdata == mcycle_high_before) begin
                                if (mcycle_samples == 0) begin
                                    mcycle_window_start = {mcycle_high_before, mcycle_low_sample};
                                    mcycle_window_start_cycle = mcycle_candidate_cycle;
                                    mcycle_samples = 1;
                                    commit_perf_start();
                                end else if (mcycle_samples == 1) begin
                                    mcycle_window_stop = {mcycle_high_before, mcycle_low_sample};
                                    mcycle_window_stop_cycle = mcycle_candidate_cycle;
                                    cycles = mcycle_window_stop_cycle - mcycle_window_start_cycle;
                                    mcycle_samples = 2;
                                    commit_perf_stop();
                                end
                                mcycle_seq_state = 0;
                            end else begin
                                // This high read detected a wrap; it is also
                                // the first high half of the retry sequence.
                                mcycle_retries = mcycle_retries + 1;
                                mcycle_high_before = dut.u_cpu.csr_rdata;
                                mcycle_seq_state = 1;
                            end
                        end else begin
                            mcycle_high_before = dut.u_cpu.csr_rdata;
                            mcycle_seq_state = 1;
                        end
                    end
                    12'hB00: begin
                        if (mcycle_seq_state == 1) begin
                            mcycle_low_sample = dut.u_cpu.csr_rdata;
                            mcycle_candidate_cycle = total_cycles;
                            capture_perf_candidate();
                            mcycle_seq_state = 2;
                        end else begin
                            mcycle_seq_state = 0;
                        end
                    end
                    default: begin end
                endcase
            end
            if (!full_run && !active && (
                (use_start_pc && t0v && t0pc == start_pc) ||
                (!use_start_pc && start_kind == 3) ||
                (!use_start_pc && (start_kind == 0 || start_kind == 1) &&
                 dut.d_req_valid && dut.d_req_ready && !dut.d_req_write &&
                 dut.d_req_addr == 32'h10000020) ||
                (!use_start_pc && (start_kind == 0 || start_kind == 2) &&
                 t0v && t0ins[6:0] == 7'b1110011 &&
                 (t0ins[31:20] == 12'hb00 || t0ins[31:20] == 12'hb80)))) begin
                active = 1;
                capture_perf_candidate();
                commit_perf_start();
                $display("SIM_WINDOW_START total_cycles=%0d pc=%08x", total_cycles, pc);
            end
            if (active || full_run) begin
                cycles = cycles + longint'(active && !full_run);
                issue0 = issue0 + longint'(dut.u_cpu.issue0);
                issue1 = issue1 + longint'(dut.u_cpu.issue1);
                retire0 = retire0 + longint'(dut.u_cpu.retire0_valid);
                retire1 = retire1 + longint'(dut.u_cpu.retire1_valid);
                trap0 = trap0 + longint'(t0v && t0trap);
                trap1 = trap1 + longint'(t1v && t1trap);
`ifdef DUAL_FIVE_STAGE
                if (dut.u_cpu.u_fetch.req_fire) fetch_req_fire_count = fetch_req_fire_count + 1;
                if (dut.u_cpu.u_fetch.rsp_fire) fetch_rsp_fire_count = fetch_rsp_fire_count + 1;
                if (dut.u_cpu.u_fetch.push_both) fetch_push_two_count = fetch_push_two_count + 1;
                if (dut.u_cpu.u_fetch.push_low && !dut.u_cpu.u_fetch.push_both)
                    fetch_push_low_count = fetch_push_low_count + 1;
                if (dut.u_cpu.u_fetch.push_high) fetch_push_high_count = fetch_push_high_count + 1;
                if (dut.u_cpu.ex_redirect && dut.u_cpu.bp_update_valid && dut.u_cpu.ex_redirect_target[2])
                    fetch_redirect_halfblock_count = fetch_redirect_halfblock_count + 1;

                branch_recovery_active_sample = branch_recovery_pending;
                if (branch_recovery_pending) begin
                    if (!dut.u_cpu.retire0_valid && !dut.u_cpu.retire1_valid)
                        branch_recovery_zero_retire = branch_recovery_zero_retire + 1;
                    if (!dut.u_cpu.fq_valid[0]) branch_recovery_fq_empty = branch_recovery_fq_empty + 1;
                    if (!dut.u_cpu.redirect_any &&
                        ((dut.u_cpu.wf_valid[0] && dut.u_cpu.fq_credit >= 2'd1 &&
                          dut.u_cpu.wf_pc[0] == branch_recovery_target) ||
                         (dut.u_cpu.wf_valid[1] && dut.u_cpu.fq_credit >= 2'd2 &&
                          dut.u_cpu.wf_pc[1] == branch_recovery_target))) begin
                        branch_recovery_done = branch_recovery_done + 1;
                        branch_recovery_latency_sum = branch_recovery_latency_sum +
                            (total_cycles - branch_recovery_start_cycle);
                        branch_recovery_pending = 1'b0;
                    end else if (dut.u_cpu.redirect_any && !dut.u_cpu.ex_redirect) begin
                        branch_recovery_superseded = branch_recovery_superseded + 1;
                        branch_recovery_pending = 1'b0;
                    end
                end
                if (dut.u_cpu.ex_redirect && dut.u_cpu.bp_update_valid) begin
                    if (branch_recovery_pending) branch_recovery_superseded = branch_recovery_superseded + 1;
                    branch_recovery_events = branch_recovery_events + 1;
                    branch_recovery_pending = 1'b1;
                    branch_recovery_target = dut.u_cpu.ex_redirect_target;
                    branch_recovery_start_cycle = total_cycles;
                end

                if (icpu_pending && dut.u_mem.u_icache.stat_miss > icpu_miss_start_count)
                    icpu_pending_miss = 1'b1;
                if (!icache_fill_pending && dut.u_mem.u_icache.state == 2'b01) begin
                    icache_fill_pending = 1'b1;
                    icache_fill_start_cycle = total_cycles;
                end
                if (icache_fill_pending && dut.u_mem.i_cp_beat_valid && dut.u_mem.i_cp_beat_ready &&
                    dut.u_mem.i_cp_beat_last) begin
                    icache_fill_done_count = icache_fill_done_count + 1;
                    icache_fill_latency_sum = icache_fill_latency_sum + (total_cycles - icache_fill_start_cycle);
                    icache_fill_pending = 1'b0;
                end
                if (icpu_pending && !dut.u_cpu.retire0_valid && !dut.u_cpu.retire1_valid)
                    icpu_pending_zero_retire = icpu_pending_zero_retire + 1;
                if (icpu_pending && dut.core_i_rsp_valid && dut.core_i_rsp_ready) begin
                    icpu_rsp_count = icpu_rsp_count + 1;
                    icpu_latency_sum = icpu_latency_sum + (total_cycles - icpu_start_cycle);
                    if (icpu_pending_miss || dut.u_mem.u_icache.stat_miss > icpu_miss_start_count) begin
                        icpu_miss_rsp_count = icpu_miss_rsp_count + 1;
                        icpu_miss_latency_sum = icpu_miss_latency_sum + (total_cycles - icpu_start_cycle);
                    end
                    icpu_pending = 1'b0;
                    icpu_pending_miss = 1'b0;
                end
                if (dut.core_i_req_valid && dut.core_i_req_ready) begin
                    icpu_req_count = icpu_req_count + 1;
                    icpu_pending = 1'b1;
                    icpu_pending_miss = 1'b0;
                    icpu_start_cycle = total_cycles;
                    icpu_miss_start_count = dut.u_mem.u_icache.stat_miss;
                end

                if (dcpu_pending && dut.u_mem.u_dcache.stat_miss > dcpu_miss_start_count)
                    dcpu_pending_miss = 1'b1;
                if (!dcache_load_fill_pending && dut.u_mem.u_dcache.state == 2'b01) begin
                    dcache_load_fill_pending = 1'b1;
                    dcache_load_fill_start_cycle = total_cycles;
                end
                if (dcache_load_fill_pending && dut.u_mem.d_cp_beat_valid && dut.u_mem.d_cp_beat_ready &&
                    dut.u_mem.d_cp_beat_last) begin
                    dcache_load_fill_done_count = dcache_load_fill_done_count + 1;
                    dcache_load_fill_latency_sum = dcache_load_fill_latency_sum +
                        (total_cycles - dcache_load_fill_start_cycle);
                    dcache_load_fill_pending = 1'b0;
                end
                if (dcpu_pending && !dut.u_cpu.retire0_valid && !dut.u_cpu.retire1_valid)
                    dcpu_pending_zero_retire = dcpu_pending_zero_retire + 1;
                if (dcpu_pending && dut.d_rsp_valid && dut.d_rsp_ready) begin
                    dcpu_rsp_count = dcpu_rsp_count + 1;
                    dcpu_latency_sum = dcpu_latency_sum + (total_cycles - dcpu_start_cycle);
                    if (dcpu_pending_miss || dut.u_mem.u_dcache.stat_miss > dcpu_miss_start_count) begin
                        dcpu_miss_latency_sum = dcpu_miss_latency_sum + (total_cycles - dcpu_start_cycle);
                        if (dcpu_pending_store) dcpu_miss_store_rsp_count = dcpu_miss_store_rsp_count + 1;
                        else dcpu_miss_load_rsp_count = dcpu_miss_load_rsp_count + 1;
                    end
                    dcpu_pending = 1'b0;
                    dcpu_pending_miss = 1'b0;
                end
                if (dut.d_req_valid && dut.d_req_ready) begin
                    dcpu_req_count = dcpu_req_count + 1;
                    dcpu_pending = 1'b1;
                    dcpu_pending_miss = 1'b0;
                    dcpu_pending_store = dut.d_req_write;
                    dcpu_start_cycle = total_cycles;
                    dcpu_miss_start_count = dut.u_mem.u_dcache.stat_miss;
                end
                if (dut.u_cpu.id_ex0_q.valid && !dut.u_cpu.ex_sources_ready) begin
                    ex_source_wait_cycles = ex_source_wait_cycles + 1;
                    if (perf_load_use_wait) begin
                        ex_load_use_wait_cycles = ex_load_use_wait_cycles + 1;
                        if (!dut.u_cpu.retire0_valid && !dut.u_cpu.retire1_valid)
                            ex_load_use_wait_zero_retire = ex_load_use_wait_zero_retire + 1;
                    end else ex_nonload_dep_wait_cycles = ex_nonload_dep_wait_cycles + 1;
                end
                if (zr_prev_head_ready) begin
                    if (dut.u_cpu.retire0_valid && dut.u_cpu.mem_wb0_q.tag == zr_prev_head_tag)
                        zr_head_ready_next_commit0 = zr_head_ready_next_commit0 + 1;
                    else if (dut.u_cpu.retire1_valid && dut.u_cpu.mem_wb1_q.tag == zr_prev_head_tag)
                        zr_head_ready_next_commit1 = zr_head_ready_next_commit1 + 1;
                    else zr_head_ready_next_no_match = zr_head_ready_next_no_match + 1;
                end
                zr_prev_head_ready = !dut.u_cpu.retire0_valid && !dut.u_cpu.retire1_valid &&
                    !dut.u_cpu.redirect_any && dut.u_cpu.visible_count != 0 &&
                    dut.u_cpu.q_valid[dut.u_cpu.visible_head] && dut.u_cpu.q_ready[dut.u_cpu.visible_head];
                if (zr_prev_head_ready) zr_prev_head_tag = dut.u_cpu.visible_head;
                if (!dut.u_cpu.retire0_valid && !dut.u_cpu.retire1_valid) begin
                    if (dut.u_cpu.redirect_any) begin
                        zr_redirect = zr_redirect + 1;
                        zr_reason_sample = 0;
                    end
                    else if (dut.u_cpu.visible_count != 0 && dut.u_cpu.q_valid[dut.u_cpu.visible_head] &&
                             dut.u_cpu.q_ready[dut.u_cpu.visible_head]) begin
                        zr_head_ready = zr_head_ready + 1;
                        zr_reason_sample = 1;
                    end
                    else if (dut.u_cpu.visible_count != 0 && dut.u_cpu.q_valid[dut.u_cpu.visible_head] &&
                             !dut.u_cpu.q_ready[dut.u_cpu.visible_head] &&
                             ((dut.u_cpu.mem_active_q && dut.u_cpu.mem_tag_q == dut.u_cpu.visible_head) ||
                              (dut.u_cpu.memq_count_q != 0 && dut.u_cpu.mem_candidate_tag == dut.u_cpu.visible_head)))
                    begin
                        zr_head_mem_wait = zr_head_mem_wait + 1;
                        zr_reason_sample = 2;
                        if (dut.u_cpu.mem_active_q && dut.u_cpu.mem_tag_q == dut.u_cpu.visible_head)
                            zr_head_mem_active = zr_head_mem_active + 1;
                        else if (dut.u_cpu.request_hold_q && dut.u_cpu.request_tag_q == dut.u_cpu.visible_head)
                            zr_head_mem_held = zr_head_mem_held + 1;
                        else if (dut.u_cpu.memq_count_q != 0 && dut.u_cpu.mem_candidate_tag == dut.u_cpu.visible_head)
                            zr_head_mem_queued = zr_head_mem_queued + 1;
                        else zr_head_mem_unclassified = zr_head_mem_unclassified + 1;
                        if (dut.u_cpu.mem_active_q && dut.u_cpu.mem_tag_q == dut.u_cpu.visible_head) begin
                            if (dut.u_cpu.response_entry.store) zr_head_mem_store = zr_head_mem_store + 1;
                            else zr_head_mem_load = zr_head_mem_load + 1;
                            case (dut.u_mem.u_dcache.state)
                                2'b00: zr_head_mem_dcache_idle = zr_head_mem_dcache_idle + 1;
                                2'b01: zr_head_mem_refill = zr_head_mem_refill + 1;
                                2'b10: begin
                                    zr_head_mem_dcache_write = zr_head_mem_dcache_write + 1;
                                    if (dut.u_mem.d_cp_wr_beat_valid && dut.u_mem.d_cp_wr_beat_ready)
                                        zr_head_mem_dcache_write_accept = zr_head_mem_dcache_write_accept + 1;
                                    else if (dut.u_mem.d_cp_wr_beat_valid && !dut.u_mem.d_cp_wr_beat_ready)
                                        zr_head_mem_dcache_write_wait = zr_head_mem_dcache_write_wait + 1;
                                    if (dut.d_rsp_valid && dut.d_rsp_ready)
                                        zr_head_mem_dcache_write_rsp = zr_head_mem_dcache_write_rsp + 1;
                                end
                                2'b11: begin
                                    zr_head_mem_dcache_resp = zr_head_mem_dcache_resp + 1;
                                    if (dut.d_rsp_valid && dut.d_rsp_ready)
                                        zr_head_mem_dcache_resp_handoff = zr_head_mem_dcache_resp_handoff + 1;
                                end
                                default: zr_head_mem_dcache_other = zr_head_mem_dcache_other + 1;
                            endcase
                            if (dut.u_cpu.response_entry.addr >= 32'h8000_0000 &&
                                dut.u_cpu.response_entry.addr < 32'h8001_0000)
                                zr_head_mem_cacheable = zr_head_mem_cacheable + 1;
                            else zr_head_mem_bypass = zr_head_mem_bypass + 1;
                        end else if (dut.u_cpu.memq_count_q != 0 && dut.u_cpu.mem_candidate_tag == dut.u_cpu.visible_head) begin
                            if (dut.u_cpu.mem_candidate.store) zr_head_mem_store = zr_head_mem_store + 1;
                            else zr_head_mem_load = zr_head_mem_load + 1;
                            if (dut.u_cpu.mem_candidate.addr >= 32'h8000_0000 &&
                                dut.u_cpu.mem_candidate.addr < 32'h8001_0000)
                                zr_head_mem_cacheable = zr_head_mem_cacheable + 1;
                            else zr_head_mem_bypass = zr_head_mem_bypass + 1;
                        end
                    end
                    else if (dut.u_cpu.visible_count != 0 && dut.u_cpu.q_valid[dut.u_cpu.visible_head] &&
                             !dut.u_cpu.q_ready[dut.u_cpu.visible_head] &&
                             dut.u_cpu.mdu_tag_q == dut.u_cpu.visible_head && !dut.u_cpu.mdu_ready) begin
                        zr_head_mdu_wait = zr_head_mdu_wait + 1;
                        zr_reason_sample = 3;
                    end
                    else if ((dut.u_cpu.id_ex0_q.valid && dut.u_cpu.id_ex0_q.tag == dut.u_cpu.visible_head &&
                              !dut.u_cpu.ex_sources_ready) ||
                             (dut.u_cpu.id_ex1_q.valid && dut.u_cpu.id_ex1_q.tag == dut.u_cpu.visible_head &&
                              !dut.u_cpu.ex_sources_ready)) begin
                        zr_head_ex_wait = zr_head_ex_wait + 1;
                        zr_reason_sample = 4;
                    end
                    else if (dut.u_cpu.visible_count == 0 && !dut.u_cpu.fq_valid[0]) begin
                        zr_no_completion_fetch_empty = zr_no_completion_fetch_empty + 1;
                        zr_reason_sample = 5;
                    end
                    else begin
                        zr_other = zr_other + 1;
                        zr_reason_sample = 6;
                        if (dut.u_cpu.visible_count == 0) begin
                            if (dut.u_cpu.fq_valid[0]) zr_other_front_valid = zr_other_front_valid + 1;
                            else if (dut.u_cpu.fq_valid[1]) zr_other_fq_slot1_only = zr_other_fq_slot1_only + 1;
                            else zr_other_residual = zr_other_residual + 1;
                        end else if (!dut.u_cpu.q_valid[dut.u_cpu.visible_head])
                            zr_other_head_invalid = zr_other_head_invalid + 1;
                        else if (!dut.u_cpu.q_executed[dut.u_cpu.visible_head]) begin
                            if ((dut.u_cpu.id_ex0_q.valid && dut.u_cpu.id_ex0_q.tag == dut.u_cpu.visible_head) ||
                                (dut.u_cpu.id_ex1_q.valid && dut.u_cpu.id_ex1_q.tag == dut.u_cpu.visible_head))
                                zr_other_head_exec_wait = zr_other_head_exec_wait + 1;
                            else zr_other_head_exec_not_in_idex = zr_other_head_exec_not_in_idex + 1;
                        end else begin
                            zr_other_head_executed_wait = zr_other_head_executed_wait + 1;
                            if (dut.u_cpu.mdu_done && dut.u_cpu.mdu_tag_q == dut.u_cpu.visible_head)
                                zr_other_head_executed_wait_mdu_done = zr_other_head_executed_wait_mdu_done + 1;
                            else if (dut.u_cpu.mem_rsp_fire && dut.u_cpu.response_tag == dut.u_cpu.visible_head)
                                zr_other_head_executed_wait_mem_rsp = zr_other_head_executed_wait_mem_rsp + 1;
                            else zr_other_head_executed_wait_residual = zr_other_head_executed_wait_residual + 1;
                        end
                        if (!dut.u_cpu.q_executed[dut.u_cpu.visible_head] &&
                            ((dut.u_cpu.id_ex0_q.valid && dut.u_cpu.id_ex0_q.tag == dut.u_cpu.visible_head) ||
                             (dut.u_cpu.id_ex1_q.valid && dut.u_cpu.id_ex1_q.tag == dut.u_cpu.visible_head)) &&
                            dut.u_cpu.ex_fire)
                            zr_other_head_exec_wait_ex_fire = zr_other_head_exec_wait_ex_fire + 1;
                        if (dut.u_cpu.visible_count == 0 && dut.u_cpu.fq_valid[0]) begin
                            if (dut.u_cpu.issue0) zr_other_front_issue0 = zr_other_front_issue0 + 1;
                            else if (!dut.u_cpu.fq_present[0]) zr_other_front_not_present = zr_other_front_not_present + 1;
                            else if (!dut.u_cpu.ex_slot_free) zr_other_front_ex_slot_busy = zr_other_front_ex_slot_busy + 1;
                            else if (dut.u_cpu.branch_pair_kill) zr_other_front_branch_pair_kill = zr_other_front_branch_pair_kill + 1;
                            else if (dut.u_cpu.serial_busy_q) zr_other_front_serial_busy = zr_other_front_serial_busy + 1;
                            else if (dut.u_cpu.count_q >= 8) zr_other_front_credit_full = zr_other_front_credit_full + 1;
                            else if (dut.u_cpu.serial0 && !((dut.u_cpu.count_q == 0) && !dut.u_cpu.id_ex0_q.valid))
                                zr_other_front_serial_gate = zr_other_front_serial_gate + 1;
                            else zr_other_front_issue_residual = zr_other_front_issue_residual + 1;
                        end
                    end
                    if (perf_load_use_wait) begin
                        case (zr_reason_sample)
                            0: zr_lu_redirect = zr_lu_redirect + 1;
                            1: zr_lu_head_ready = zr_lu_head_ready + 1;
                            2: zr_lu_head_mem = zr_lu_head_mem + 1;
                            3: zr_lu_head_mdu = zr_lu_head_mdu + 1;
                            4: zr_lu_head_ex = zr_lu_head_ex + 1;
                            5: zr_lu_fetch_empty = zr_lu_fetch_empty + 1;
                            default: zr_lu_other = zr_lu_other + 1;
                        endcase
                    end
                    if (branch_recovery_active_sample) begin
                        case (zr_reason_sample)
                            0: zr_rec_redirect = zr_rec_redirect + 1;
                            1: zr_rec_head_ready = zr_rec_head_ready + 1;
                            2: zr_rec_head_mem = zr_rec_head_mem + 1;
                            3: zr_rec_head_mdu = zr_rec_head_mdu + 1;
                            4: zr_rec_head_ex = zr_rec_head_ex + 1;
                            5: zr_rec_fetch_empty = zr_rec_fetch_empty + 1;
                            default: zr_rec_other = zr_rec_other + 1;
                        endcase
                    end
                    if (perf_lsu) begin
                        case (zr_reason_sample)
                            0: zr_lsu_redirect = zr_lsu_redirect + 1;
                            1: zr_lsu_head_ready = zr_lsu_head_ready + 1;
                            2: zr_lsu_head_mem = zr_lsu_head_mem + 1;
                            3: zr_lsu_head_mdu = zr_lsu_head_mdu + 1;
                            4: zr_lsu_head_ex = zr_lsu_head_ex + 1;
                            5: zr_lsu_fetch_empty = zr_lsu_fetch_empty + 1;
                            default: zr_lsu_other = zr_lsu_other + 1;
                        endcase
                    end
                end
                if (rom_read_pending && dut.d_rsp_valid && dut.d_rsp_ready) begin
                    rom_read_rsp = rom_read_rsp + 1;
                    if (rom_read_latency_in_window) begin
                        rom_read_latency_sum = rom_read_latency_sum + (total_cycles - rom_read_start_cycle);
                        if ((total_cycles - rom_read_start_cycle) > rom_read_latency_max)
                            rom_read_latency_max = total_cycles - rom_read_start_cycle;
                    end
                    rom_read_pending = 1'b0;
                    rom_read_latency_in_window = 1'b0;
                end
                if (dut.d_req_valid && dut.d_req_ready && !dut.d_req_write && dut.d_req_addr[31:16] == 16'h0000) begin
                    rom_read_accept = rom_read_accept + 1;
                    rom_read_pending = 1'b1;
                    rom_read_start_cycle = total_cycles;
                    rom_read_latency_in_window = active || full_run;
                end
                // Same exact partitions as the legacy report, with stage-
                // specific predicates. Legacy-only young/turnover fields stay
                // zero and are explicitly marked not applicable by the runner.
                if (dut.u_cpu.redirect_any) redirect = redirect + 1;
                else if (perf_lsu) lsu = lsu + 1;
                else if (perf_mdu) mdu = mdu + 1;
                else if (dut.u_cpu.serial_busy_q) csr = csr + 1;
                else if (!dut.u_cpu.fq_valid[0]) fetch = fetch + 1;
                else if (dut.u_cpu.issue0) progress = progress + 1;
                else other = other + 1;
                overlap_lsu = overlap_lsu + longint'(perf_lsu);
                overlap_mdu = overlap_mdu + longint'(perf_mdu);
                overlap_csr = overlap_csr + longint'(dut.u_cpu.serial_busy_q);
                overlap_empty = overlap_empty + longint'(!dut.u_cpu.fq_valid[0]);
                overlap_redirect = overlap_redirect + longint'(dut.u_cpu.redirect_any);
                if (dut.u_cpu.fq_valid[0] && dut.u_cpu.fq_valid[1] && !dut.u_cpu.issue0) begin
                    lane1_backend_blocked = lane1_backend_blocked + 1;
                    if (dut.u_cpu.redirect_any) lane1_backend_redirect = lane1_backend_redirect + 1;
                    else if (perf_lsu) begin
                        lane1_backend_lsu = lane1_backend_lsu + 1;
                        if (dut.u_cpu.dec0.mem || dut.u_cpu.dec0.mdu || dut.u_cpu.control0 ||
                            dut.u_cpu.serial0 || dut.u_cpu.bad0) begin
                            lane1_lsu_lane0_nonalu = lane1_lsu_lane0_nonalu + 1;
                            if (dut.u_cpu.dec0.mem) lane1_lsu_lane0_mem = lane1_lsu_lane0_mem + 1;
                            else if (dut.u_cpu.dec0.mdu) lane1_lsu_lane0_mdu = lane1_lsu_lane0_mdu + 1;
                            else if (dut.u_cpu.control0) lane1_lsu_lane0_control = lane1_lsu_lane0_control + 1;
                            else if (dut.u_cpu.serial0) lane1_lsu_lane0_csr_sys = lane1_lsu_lane0_csr_sys + 1;
                            else lane1_lsu_lane0_unknown = lane1_lsu_lane0_unknown + 1;
                        end else if (!dut.u_cpu.ex_sources_ready)
                            lane1_lsu_lane0_hazard = lane1_lsu_lane0_hazard + 1;
                        else if (dut.u_cpu.count_q == 8)
                            lane1_lsu_lane0_no_credit = lane1_lsu_lane0_no_credit + 1;
                        else lane1_lsu_lane0_other = lane1_lsu_lane0_other + 1;
                    end else if (perf_mdu) lane1_backend_mdu = lane1_backend_mdu + 1;
                    else if (dut.u_cpu.serial_busy_q) lane1_backend_csr = lane1_backend_csr + 1;
                    else lane1_backend_other = lane1_backend_other + 1;
                end
                if (dut.u_cpu.fq_valid[1] && dut.u_cpu.issue0) begin
                    offer1 = offer1 + 1;
                    raw_rs1 = raw_rs1 + longint'(dut.u_cpu.dec0.reg_we && dut.u_cpu.dec0.rd != 0 &&
                        dut.u_cpu.dec1.use_rs1 && dut.u_cpu.dec1.rs1 == dut.u_cpu.dec0.rd);
                    raw_rs2 = raw_rs2 + longint'(dut.u_cpu.dec0.reg_we && dut.u_cpu.dec0.rd != 0 &&
                        dut.u_cpu.dec1.use_rs2 && dut.u_cpu.dec1.rs2 == dut.u_cpu.dec0.rd);
                    waw = waw + longint'(dut.u_cpu.intra_waw);
                    if (!dut.u_cpu.issue1) begin
                        blocked1 = blocked1 + 1;
                        if (dut.u_cpu.intra_raw) lane1_pair_raw = lane1_pair_raw + 1;
                        else if (dut.u_cpu.intra_waw) lane1_pair_waw = lane1_pair_waw + 1;
                        else if (!(dut.u_cpu.pair_eligible_raw && dut.u_cpu.fq_present[1])) lane1_pair_nonpairable = lane1_pair_nonpairable + 1;
                        else lane1_pair_other = lane1_pair_other + 1;
                    end
                end
                d_backpressure = d_backpressure + longint'(dut.d_req_valid && !dut.d_req_ready);
                if (perf_lsu && !dut.u_cpu.redirect_any) begin
                    if (perf_lsu_store) lsu_primary_store = lsu_primary_store + 1;
                    else lsu_primary_load = lsu_primary_load + 1;
                    if (dut.u_cpu.mem_active_q) lsu_state_wait_rsp = lsu_state_wait_rsp + 1;
                    else lsu_state_req_wait = lsu_state_req_wait + 1;
                end
                if (dut.d_req_valid && !dut.d_req_ready) lsu_req_wait = lsu_req_wait + 1;
                if (dut.u_cpu.mem_active_q && !dut.d_rsp_valid) lsu_rsp_wait = lsu_rsp_wait + 1;
                if (dut.u_cpu.mem_active_q) begin
                    if (dut.u_mem.u_dcache.state == 2'b01) lsu_dcache_fill = lsu_dcache_fill + 1;
                    if (dut.u_mem.u_dcache.state == 2'b10) lsu_dcache_write = lsu_dcache_write + 1;
                    if (dut.u_mem.u_dcache.state == 2'b11) lsu_dcache_resp = lsu_dcache_resp + 1;
                end
                not_taken_redirect = not_taken_redirect + longint'(dut.u_cpu.ex_redirect &&
                    !(dut.u_cpu.mismatch0 ? dut.u_cpu.ex_taken[0] : dut.u_cpu.ex_taken[1]));
`else
                // Main categories are mutually exclusive; overlap_* counters
                // are raw signal-high cycles and must not be added as losses.
                if (dut.u_cpu.redirect_any) redirect = redirect + 1;
                else if (dut.u_cpu.r0_mem_pending_q) lsu = lsu + 1;
                else if (dut.u_cpu.mdu_pending_q) mdu = mdu + 1;
                else if (dut.u_cpu.r0_csr_pending_q) csr = csr + 1;
                else if (!dut.u_cpu.fq_out0_valid) fetch = fetch + 1;
                else if (dut.u_cpu.issue0) progress = progress + 1;
                else other = other + 1;
                overlap_lsu = overlap_lsu + longint'(dut.u_cpu.r0_mem_pending_q);
                overlap_mdu = overlap_mdu + longint'(dut.u_cpu.mdu_pending_q);
                overlap_csr = overlap_csr + longint'(dut.u_cpu.r0_csr_pending_q);
                overlap_empty = overlap_empty + longint'(!dut.u_cpu.fq_out0_valid);
                overlap_redirect = overlap_redirect + longint'(dut.u_cpu.redirect_any);
                // Classify lane1 cycles blocked before issue separately from
                // pair rejection after lane0 has issued. Backend reasons use
                // one priority order so their buckets are mutually exclusive.
                if (dut.u_cpu.s1_valid && dut.u_cpu.fq_out0_valid &&
                    dut.u_cpu.backend_stall && !dut.u_cpu.issue0) begin
                    lane1_backend_blocked = lane1_backend_blocked + 1;
                    if (dut.u_cpu.redirect_any)
                        lane1_backend_redirect = lane1_backend_redirect + 1;
                    else if (dut.u_cpu.r0_mem_pending_q)
                        begin
                            lane1_backend_lsu = lane1_backend_lsu + 1;
                            if (!dut.u_cpu.d0_is_alu)
                                begin
                                    lane1_lsu_lane0_nonalu = lane1_lsu_lane0_nonalu + 1;
                                    if (dut.u_cpu.d0_is_mem)
                                        lane1_lsu_lane0_mem = lane1_lsu_lane0_mem + 1;
                                    else if (dut.u_cpu.d0_is_mdu)
                                        lane1_lsu_lane0_mdu = lane1_lsu_lane0_mdu + 1;
                                    else if (dut.u_cpu.d0_is_ctl)
                                        lane1_lsu_lane0_control = lane1_lsu_lane0_control + 1;
                                    else if (dut.u_cpu.d0_is_csr || dut.u_cpu.d0_is_sys)
                                        lane1_lsu_lane0_csr_sys = lane1_lsu_lane0_csr_sys + 1;
                                    else
                                        lane1_lsu_lane0_unknown = lane1_lsu_lane0_unknown + 1;
                                end
                            else if (dut.u_cpu.young_hazard0)
                                lane1_lsu_lane0_hazard = lane1_lsu_lane0_hazard + 1;
                            else if (!dut.u_cpu.young_credit_one)
                                lane1_lsu_lane0_no_credit = lane1_lsu_lane0_no_credit + 1;
                            else if (dut.u_cpu.commit0_fire)
                                lane1_lsu_lane0_commit = lane1_lsu_lane0_commit + 1;
                            else
                                lane1_lsu_lane0_other = lane1_lsu_lane0_other + 1;
                        end
                    else if (dut.u_cpu.mdu_pending_q)
                        lane1_backend_mdu = lane1_backend_mdu + 1;
                    else if (dut.u_cpu.r0_csr_pending_q)
                        lane1_backend_csr = lane1_backend_csr + 1;
                    else
                        lane1_backend_other = lane1_backend_other + 1;
                end
                if (dut.u_cpu.s1_valid && dut.u_cpu.issue0) begin
                    offer1 = offer1 + 1;
                    raw_rs1 = raw_rs1 + longint'(dut.u_cpu.u_alu.u_issue.raw_rs1);
                    raw_rs2 = raw_rs2 + longint'(dut.u_cpu.u_alu.u_issue.raw_rs2);
                    waw = waw + longint'(dut.u_cpu.u_alu.u_issue.waw);
                end
                blocked1 = blocked1 + longint'(dut.u_cpu.slot1_stall);
                if (dut.u_cpu.slot1_stall) begin
                    if (!dut.u_cpu.d0_pair_eligible)
                        lane1_pair_nonpairable = lane1_pair_nonpairable + 1;
                    else if (dut.u_cpu.u_alu.u_issue.raw_rs1 ||
                             dut.u_cpu.u_alu.u_issue.raw_rs2)
                        lane1_pair_raw = lane1_pair_raw + 1;
                    else if (dut.u_cpu.u_alu.u_issue.waw)
                        lane1_pair_waw = lane1_pair_waw + 1;
                    else
                        lane1_pair_other = lane1_pair_other + 1;
                end
                d_backpressure = d_backpressure + longint'(dut.d_req_valid && !dut.d_req_ready);
                // These four state buckets are mutually exclusive and cover
                // primary LSU-stall cycles. Other LSU state counters below
                // are overlapping substate observations.
                if (dut.u_cpu.r0_mem_pending_q && !dut.u_cpu.redirect_any) begin
                    if (dut.u_cpu.r0_mem_we_q)
                        lsu_primary_store = lsu_primary_store + 1;
                    else
                        lsu_primary_load = lsu_primary_load + 1;
                    case (dut.u_cpu.u_lsu.state_q)
                        3'b000: lsu_state_idle = lsu_state_idle + 1;
                        3'b001: lsu_state_req_wait = lsu_state_req_wait + 1;
                        3'b010: lsu_state_wait_rsp = lsu_state_wait_rsp + 1;
                        3'b011: lsu_state_misaligned = lsu_state_misaligned + 1;
                        default: lsu_state_unknown = lsu_state_unknown + 1;
                    endcase
                end
                if (dut.u_cpu.r0_mem_pending_q) begin
                    if (dut.u_cpu.u_lsu.state_q == 3'b001 && !dut.u_cpu.d_req_ready)
                        lsu_req_wait = lsu_req_wait + 1;
                    if (dut.u_cpu.u_lsu.state_q == 3'b010 && !dut.u_cpu.d_rsp_valid)
                        lsu_rsp_wait = lsu_rsp_wait + 1;
                    if (dut.u_cpu.u_lsu.state_q == 3'b010) begin
                        if (dut.u_mem.u_dcache.state == 2'b01)
                            lsu_dcache_fill = lsu_dcache_fill + 1;
                        if (dut.u_mem.u_dcache.state == 2'b10)
                            lsu_dcache_write = lsu_dcache_write + 1;
                        if (dut.u_mem.u_dcache.state == 2'b11)
                            lsu_dcache_resp = lsu_dcache_resp + 1;
                    end
                end
                lsu_pair_hold = lsu_pair_hold + longint'(dut.u_cpu.r1_mem_pair_pending_q);
                not_taken_redirect = not_taken_redirect + longint'(
                    dut.u_cpu.branch_redirect && !dut.u_cpu.ex0_branch_taken);
                young_issue0 = young_issue0 + longint'(dut.u_cpu.young_long_pending && dut.u_cpu.issue0);
                young_issue1 = young_issue1 + longint'(dut.u_cpu.young_long_pending && dut.u_cpu.issue1);
                completion_replace0 = completion_replace0 + longint'(dut.u_cpu.young_completion_replace && dut.u_cpu.issue0);
                completion_replace1 = completion_replace1 + longint'(dut.u_cpu.young_completion_replace && dut.u_cpu.issue1);
                young_retire0 = young_retire0 + longint'(dut.u_cpu.young_queue_drain && dut.u_cpu.commit0_fire);
                young_retire1 = young_retire1 + longint'(dut.u_cpu.young_queue_drain && dut.u_cpu.commit1_fire);
`endif
                if (!full_run && cycles >= window_cycles) begin
                    capture_perf_candidate();
                    commit_perf_stop();
                    summary();
                    $display("SIM_WINDOW_DONE");
                    $fclose(uart_file);
                    $finish;
                end
            end
            if (full_run && validation_seen) begin
                quiet_cycles = quiet_cycles + 1;
                // Drain trailing score/report lines after validation, then
                // finish only after 100 UART bit periods with no new byte.
                if (quiet_cycles >= UART_DIV * 100) begin
                    if (mcycle_samples != 2)
                        $fatal(1, "SIM_ERROR expected two verified mcycle windows, observed %0d", mcycle_samples);
                    summary();
                    $display("SIM_UART_DONE");
                    $fclose(uart_file);
                    $finish;
                end
            end
            if (total_cycles >= max_cycles) begin
                summary();
`ifdef DUAL_FIVE_STAGE
                $display("SIM_DIAG occupancy=%0d head=%0d tail=%0d idex=%b:%08x ex_ready=%b mem=%b dreq=%b/%b/%08x/%b drsp=%b dcache_state=%0d",
                         dut.u_cpu.count_q, dut.u_cpu.head_q, dut.u_cpu.tail_q,
                         dut.u_cpu.id_ex0_q.valid, dut.u_cpu.id_ex0_q.pc, dut.u_cpu.ex_sources_ready,
                         dut.u_cpu.mem_active_q, dut.d_req_valid, dut.d_req_ready,
                         dut.d_req_addr, dut.d_req_write, dut.d_rsp_valid, dut.u_mem.u_dcache.state);
`else
                $display("SIM_DIAG r0_pc=%08x r0_instr=%08x pending_mem=%b mdu=%b young_count=%0d head=%0d tail=%0d ex=%b%b lsu_state=%0d dreq=%b/%b/%08x/%b drsp=%b dcache_state=%0d",
                         dut.u_cpu.r0_pc_q, dut.u_cpu.r0_instr_q,
                         dut.u_cpu.r0_mem_pending_q, dut.u_cpu.mdu_pending_q,
                         dut.u_cpu.young_count_q, dut.u_cpu.young_head_q,
                         dut.u_cpu.young_tail_q, dut.u_cpu.young_ex0_valid_q,
                         dut.u_cpu.young_ex1_valid_q, dut.u_cpu.u_lsu.state_q,
                         dut.d_req_valid, dut.d_req_ready, dut.d_req_addr,
                         dut.d_req_write, dut.d_rsp_valid,
                         dut.u_mem.u_dcache.state);
`endif
                $fatal(1, "SIM_TIMEOUT max_cycles=%0d active=%0d pc=%08x",
                       max_cycles, active, pc);
            end
        end
    end

endmodule
