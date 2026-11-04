`timescale 1ns/1ps
`include "defines.sv"

// Black-box architectural scoreboard. No legacy pending/young/queue hierarchy
// is used: every retirement is interpreted independently from RV32 encodings,
// and every accepted store is checked against the architectural store stream.
module tb_dual_5stage_waw;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg timer_irq = 0;
    wire i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    reg i_rsp_valid = 0;
    reg [63:0] i_rsp_data = 0;
    reg [1:0] i_rsp_error = 0;
    wire d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_ready;
    wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
    wire [3:0] d_req_wstrb;
    wire d_rsp_error;
    wire issue0, issue1, retire0_valid, retire1_valid;
    wire trace0_valid, trace0_rd_we, trace0_trap;
    wire trace1_valid, trace1_rd_we, trace1_trap;
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] trace0_pc, trace0_instr, trace0_rd_data, trace0_cause;
    wire [31:0] trace1_pc, trace1_instr, trace1_rd_data, trace1_cause;
    wire [4:0] trace0_rd, trace1_rd;

    dual_issue_5stage_core #(.M_MODE(2), .PREDICT_ENABLE(1), .BTB_ENTRIES(128)) dut (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_req_write(d_req_write), .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
        .timer_irq_i(timer_irq), .ext_irq_i(1'b0),
        .issue0(issue0), .issue1(issue1), .retire0_valid(retire0_valid), .retire1_valid(retire1_valid),
        .trace0_valid(trace0_valid), .trace0_order(trace0_order), .trace0_pc(trace0_pc),
        .trace0_instr(trace0_instr), .trace0_rd(trace0_rd), .trace0_rd_data(trace0_rd_data),
        .trace0_rd_we(trace0_rd_we), .trace0_trap(trace0_trap), .trace0_cause(trace0_cause),
        .trace1_valid(trace1_valid), .trace1_order(trace1_order), .trace1_pc(trace1_pc),
        .trace1_instr(trace1_instr), .trace1_rd(trace1_rd), .trace1_rd_data(trace1_rd_data),
        .trace1_rd_we(trace1_rd_we), .trace1_trap(trace1_trap), .trace1_cause(trace1_cause),
        .pc_debug()
    );

    reg [31:0] program_words [0:255];
    reg [7:0] memory_bytes [0:1023];
    reg [7:0] reference_bytes [0:1023];
    reg [31:0] reference_regs [0:31];
    reg [31:0] actual_store_addr [0:255], actual_store_data [0:255];
    reg [3:0] actual_store_mask [0:255];
    reg [31:0] expected_store_addr [0:255], expected_store_data [0:255];
    reg [3:0] expected_store_mask [0:255];
    integer cycles = 0, request_count = 0, accepted_stores = 0, expected_stores = 0;
    integer case_number = 0, latency_mode = 0, scenario = 0;
    integer dual_issues = 0, dual_retires = 0, checked_instructions = 0, checked_traps = 0;
    integer wait_cycles = 0;
    integer load_load = 0, store_load = 0, error_blocked = 0;
    reg response_was_write = 0;
    integer bus_turnovers = 0, bus_responses = 0, bus_requests = 0;
    integer stale_requests_tagged = 0;
    integer waw_pair_pc = 12, waw_exception_pair_pc = 36;
    integer waw_issue_seen = 0, waw_commit_seen = 0, waw_exception_pair_seen = 0;
    integer irq_waw_pair_pc = 28, irq_waw_issue_seen = 0, irq_waw_commit_seen = 0;
    reg pending = 0, response_valid_q = 0, response_error_q = 0;
    reg [31:0] response_data_q = 0;
    reg held_request = 0;
    reg [68:0] request_payload;
    reg stale_response_pending_q = 0;
    reg done = 0;
    reg irq_arm = 0, irq_seen = 0;
    reg bp_started = 0, bp_finished = 0, irq_with_read_pending = 0;
    integer bp_remaining = 0, stale_injections = 0;
    reg scenario7_read_outstanding = 0;
    reg [68:0] scenario7_read_payload = 0;
    integer allocated = 0, outstanding = 0, max_outstanding = 0, dual_turnovers = 0;
    reg [31:0] reference_pc = 0, done_pc = 0;
    reg [31:0] reference_mtvec = 0, reference_mepc = 0;
    reg [31:0] reference_mcause = 0, reference_mtval = 0;
    reg [31:0] reference_mstatus = 32'h1800, reference_mie = 0;
    reg [63:0] reference_order = 0;
    integer p, k;

    always @(negedge clk)
        if (rst || irq_seen) timer_irq = 0;
        else if (irq_arm) timer_irq = 1;

    function automatic [31:0] memory_word(input [31:0] addr);
        integer b;
        begin
            b = addr[9:0];
            memory_word = {memory_bytes[b+3], memory_bytes[b+2], memory_bytes[b+1], memory_bytes[b]};
        end
    endfunction

    wire request_fault = (scenario == 3) && (d_req_addr == 32'h8000_0300);
    wire instant_response = (latency_mode == 0) && d_req_valid && d_req_ready;
    wire force_read_backpressure = scenario == 7 && !bp_finished && !d_req_write;
    // Read the byte array explicitly: a continuous assignment calling a
    // function with hidden array reads need not refresh when only RAM changes.
    wire [31:0] live_memory_word = {memory_bytes[d_req_addr[9:0]+3], memory_bytes[d_req_addr[9:0]+2],
                                    memory_bytes[d_req_addr[9:0]+1], memory_bytes[d_req_addr[9:0]]};
    assign i_req_ready = !rst && (!i_rsp_valid || i_rsp_ready) && ((cycles % 5) != 1);
    assign d_req_ready = !rst && !pending && (!response_valid_q || d_rsp_ready) &&
                         !force_read_backpressure && ((cycles % 7) != 2);
    assign d_rsp_valid = response_valid_q || instant_response;
    assign d_rsp_rdata = response_valid_q ? response_data_q :
                         (d_req_write ? 32'd0 : live_memory_word);
    assign d_rsp_error = response_valid_q ? response_error_q : request_fault;

    always @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            bus_turnovers <= 0; bus_responses <= 0; bus_requests <= 0; load_load <= 0; store_load <= 0; error_blocked <= 0;
            i_rsp_valid <= 0;
            i_rsp_data <= 0;
            i_rsp_error <= 0;
            pending <= 0;
            response_valid_q <= 0;
            response_error_q <= 0;
            stale_response_pending_q <= 0;
            response_data_q <= 0;
            scenario7_read_outstanding <= 0;
            scenario7_read_payload <= 0;
            wait_cycles <= 0;
            request_count <= 0;
            held_request <= 0;
        end else begin
            cycles <= cycles + 1;
            if (d_rsp_valid && d_rsp_ready) bus_responses <= bus_responses + 1;
            if (d_req_valid && d_req_ready) bus_requests <= bus_requests + 1;
            if (response_valid_q && d_rsp_ready && d_rsp_error) begin
                if (d_req_valid && d_req_ready) $fatal(1,"FAIL: younger request accepted with error response");
                error_blocked <= error_blocked + 1;
            end
            if (response_valid_q && d_rsp_ready && d_req_valid && d_req_ready) begin
                bus_turnovers <= bus_turnovers + 1;
                if (!d_req_write && response_was_write) store_load <= store_load + 1;
                if (!d_req_write && !response_was_write) load_load <= load_load + 1;
            end
            if (scenario == 7 && !bp_started && d_req_valid && !d_req_write) begin
                bp_started = 1; bp_remaining = 24; irq_arm = 1;
            end else if (bp_started && !bp_finished) begin
                if (bp_remaining > 0) bp_remaining = bp_remaining - 1;
                else bp_finished = 1;
            end
            if (i_rsp_valid && i_rsp_ready) i_rsp_valid <= 0;
            if (i_req_valid && i_req_ready) begin
                if (i_req_addr[31:10] != 0) $fatal(1, "FAIL: instruction request outside test ROM %08x", i_req_addr);
                i_rsp_valid <= 1;
                i_rsp_data <= {program_words[i_req_addr[9:2]+1], program_words[i_req_addr[9:2]]};
                i_rsp_error <= (scenario == 5 && i_req_addr == 32'h0000_0040) ? 2'b01 : 2'b00;
            end
            if (response_valid_q && d_rsp_ready) begin
                response_valid_q <= 0;
                if (stale_response_pending_q && d_rsp_error) begin
                    stale_injections <= stale_injections + 1;
                    stale_response_pending_q <= 0;
                end
            end
            if (response_valid_q && d_rsp_ready && scenario7_read_outstanding)
                scenario7_read_outstanding <= 0;
            if (pending && wait_cycles > 0) wait_cycles <= wait_cycles - 1;
            else if (pending) begin pending <= 0; response_valid_q <= 1; end
            if (held_request && (!d_req_valid ||
                {d_req_addr,d_req_write,d_req_wdata,d_req_wstrb} !== request_payload))
                $fatal(1, "FAIL: memory request changed under backpressure");
            held_request <= d_req_valid && !d_req_ready;
            if (d_req_valid && !d_req_ready)
                request_payload <= {d_req_addr,d_req_write,d_req_wdata,d_req_wstrb};
            if (d_req_valid && d_req_ready) begin
                if (d_req_addr[31:10] != 22'h200000 || d_req_addr[1:0] != 0)
                    $fatal(1, "FAIL: malformed/out-of-range memory request %08x", d_req_addr);
                request_count <= request_count + 1;
                if (latency_mode != 0 || !d_rsp_ready) begin
                    response_was_write <= d_req_write;
                    response_data_q <= d_req_write ? 0 : memory_word(d_req_addr);
                    response_error_q <= request_fault;
                    if (latency_mode == 0) response_valid_q <= 1;
                    else begin
                        pending <= 1;
                        wait_cycles <= (latency_mode == 1) ? 1 : (latency_mode == 3) ? 31 : (request_count % 11) + 1;
                    end
                end
                if (scenario == 7 && !d_req_write) begin
                    scenario7_read_outstanding <= 1;
                    scenario7_read_payload <= {d_req_addr,d_req_write,d_req_wdata,d_req_wstrb};
                end
                if (d_req_write) begin
                    if (scenario == 6 && d_req_addr == 32'h8000_0000 && !irq_seen) irq_arm = 1;
                    if (accepted_stores >= 256) $fatal(1, "FAIL: duplicated/unbounded stores");
                    actual_store_addr[accepted_stores] = d_req_addr;
                    actual_store_data[accepted_stores] = d_req_wdata;
                    actual_store_mask[accepted_stores] = d_req_wstrb;
                    accepted_stores = accepted_stores + 1;
                    if (!request_fault) begin
                        for (k = 0; k < 4; k = k + 1)
                            if (d_req_wstrb[k]) memory_bytes[d_req_addr[9:0]+k] <= d_req_wdata[k*8 +: 8];
                    end
                end
            end
        end
    end

    function automatic [31:0] enc_i(input integer imm, input integer rs1, input integer f3,
                                     input integer rd, input integer opcode);
        enc_i = {imm[11:0],rs1[4:0],f3[2:0],rd[4:0],opcode[6:0]};
    endfunction
    function automatic [31:0] enc_r(input integer f7, input integer rs2, input integer rs1,
                                     input integer f3, input integer rd);
        enc_r = {f7[6:0],rs2[4:0],rs1[4:0],f3[2:0],rd[4:0],7'h33};
    endfunction
    function automatic [31:0] enc_s(input integer imm, input integer rs2, input integer rs1, input integer f3);
        enc_s = {imm[11:5],rs2[4:0],rs1[4:0],f3[2:0],imm[4:0],7'h23};
    endfunction
    function automatic [31:0] enc_b(input integer imm, input integer rs2, input integer rs1, input integer f3);
        enc_b = {imm[12],imm[10:5],rs2[4:0],rs1[4:0],f3[2:0],imm[4:1],imm[11],7'h63};
    endfunction
    function automatic [31:0] enc_j(input integer imm, input integer rd);
        enc_j = {imm[20],imm[10:1],imm[11],imm[19:12],rd[4:0],7'h6f};
    endfunction
    function automatic [31:0] m_result(input [31:0] a, input [31:0] b, input [2:0] f3);
        reg signed [63:0] ss;
        reg signed [64:0] su;
        reg [63:0] uu;
        begin
            ss = $signed(a) * $signed(b);
            su = $signed(a) * $signed({1'b0,b});
            uu = a * b;
            case (f3)
                0: m_result = uu[31:0];
                1: m_result = ss[63:32];
                2: m_result = su[63:32];
                3: m_result = uu[63:32];
                4: begin
                    if (b == 0) m_result = 32'hffff_ffff;
                    else if (a == 32'h8000_0000 && b == 32'hffff_ffff) m_result = a;
                    else m_result = $signed(a) / $signed(b);
                end
                5: m_result = (b == 0) ? 32'hffff_ffff : a / b;
                6: begin
                    if (b == 0) m_result = a;
                    else if (a == 32'h8000_0000 && b == 32'hffff_ffff) m_result = 0;
                    else m_result = $signed(a) % $signed(b);
                end
                7: m_result = (b == 0) ? a : a % b;
            endcase
        end
    endfunction

    task automatic emit(input [31:0] inst);
        begin program_words[p] = inst; p = p + 1; end
    endtask

    task automatic build_irq;
        begin
            emit(32'h8000_00b7);
            emit(enc_i('h300,0,0,2,'h13));
            emit(enc_i('h305,2,1,0,'h73));
            emit(enc_i(128,0,0,2,'h13));
            emit(enc_i('h304,2,1,0,'h73));
            emit(enc_i(8,0,0,2,'h13));
            emit(enc_i('h300,2,1,0,'h73));
            emit(enc_i(77,0,0,3,'h13));
            if (scenario == 6) emit(enc_s(0,3,1,2)); // IRQ while an accepted store waits.
            else begin
                emit(enc_i(17,0,0,3,'h13)); // same-rd WAW pair with x3=77
                // The not-taken slot0 branch forces a packet boundary after
                // the WAW pair. An independent ALU+LOAD pair then presents a
                // younger read while its older ALU reaches the IRQ boundary.
                emit(enc_b(8,0,0,1));
                emit(enc_i(17,0,0,5,'h13));
                emit(enc_i(0,1,2,4,3));
            end
            emit(enc_i(1,0,0,4,'h13));
            emit(enc_i(2,0,0,5,'h13));
            emit(enc_i(0,1,2,6,3));
            emit(enc_r(0,6,4,0,7));
            emit(enc_s('h24,7,1,2));
            done_pc = p*4;
            emit(enc_i('h5a5,0,0,31,'h13));
            emit(enc_j(0,0));
            p = 'h300/4;
            emit(enc_i('h342,0,2,12,'h73));
            emit(enc_i('h341,0,2,13,'h73));
            emit(enc_s('h30,12,1,2));
            emit(enc_s('h34,13,1,2));
            emit(32'h3020_0073); // An interrupt resumes at MEPC, without +4.
        end
    endtask
    task automatic build_normal;
        integer n;
        begin
            emit(32'h8000_00b7); // x1 = SRAM base
            emit(32'h1234_5137); // x2 = 0x12345000
            emit(enc_i('h678,2,0,2,'h13));
            emit(enc_s(0,2,1,2));
            emit(enc_i(0,1,0,3,3));
            emit(enc_i(1,1,4,4,3));
            emit(enc_i(-128,0,0,5,'h13));
            emit(enc_s(5,5,1,0));
            emit(enc_i(5,1,0,6,3));
            emit(enc_i(5,1,4,7,3));
            emit(enc_i(4,1,1,8,3));
            emit(enc_i(4,1,5,9,3));
            emit(enc_s(8,5,1,1));
            emit(enc_i(8,1,1,10,3));
            emit(enc_i(8,1,5,11,3));
            // One source producer retires while EX waits for its other source.
            // Later WAW versions and ring reuse must preserve the held value.
            emit(enc_i(91,0,0,15,'h13));
            emit(enc_i(0,1,2,12,3));
            emit(enc_r(0,12,15,0,16));
            emit(enc_i(7,0,0,15,'h13));
            emit(enc_r(0,15,16,0,17));
            // Delayed producer, independent pairs, then RAW and repeated WAW.
            emit(enc_i(0,1,2,12,3));
            for (n = 13; n <= 20; n = n + 1) emit(enc_i(n*3,0,0,n,'h13));
            emit(enc_r(0,12,13,0,21));
            emit(enc_i(1,21,0,21,'h13));
            emit(enc_i(2,21,0,21,'h13));
            emit(enc_i(-1,0,0,22,'h13));
            emit(enc_i(31,0,0,23,'h13));
            emit(enc_r(0,23,22,1,24));
            emit(enc_r('h20,23,22,5,25));
            emit(enc_r(0,23,22,5,26));
            emit(enc_r(0,23,22,2,27));
            emit(enc_r(0,23,22,3,28));
            emit(enc_r(0,23,22,4,29));
            emit(enc_r(0,23,22,6,30));
            emit(enc_r(0,23,22,7,3));
            // Multiply high variants and signed division overflow / zero.
            for (n = 0; n < 4; n = n + 1) emit(enc_r(1,22,2,n,4+n));
            emit(32'h8000_0437); // x8 = INT_MIN
            emit(enc_r(1,22,8,4,9));
            emit(enc_r(1,22,8,6,10));
            emit(enc_r(1,0,2,4,11));
            emit(enc_r(1,0,2,5,12));
            emit(enc_r(1,0,2,6,13));
            emit(enc_r(1,0,2,7,14));
            emit(enc_i(-13,0,0,15,'h13));
            emit(enc_i(5,0,0,16,'h13));
            emit(enc_r(1,16,15,4,17));
            emit(enc_r(1,16,15,6,18));
            // All six branch predicates, taken and not taken. Every taken
            // branch skips a store that would visibly corrupt the store log.
            emit(enc_b(8,0,0,0)); emit(enc_s('h80,2,1,2));
            emit(enc_b(8,0,22,1)); emit(enc_s('h84,2,1,2));
            emit(enc_b(8,0,22,4)); emit(enc_s('h88,2,1,2));
            emit(enc_b(8,22,0,5)); emit(enc_s('h8c,2,1,2));
            emit(enc_b(8,22,0,6)); emit(enc_s('h90,2,1,2));
            emit(enc_b(8,0,22,7)); emit(enc_s('h94,2,1,2));
            emit(enc_b(8,0,22,0)); emit(enc_i(77,0,0,19,'h13));
            emit(enc_j(12,20)); emit(enc_s('h98,2,1,2)); emit(enc_s('h9c,2,1,2));
            emit(enc_i(((p+4)*4)|1,0,0,24,'h13));
            emit(enc_i(0,24,0,25,'h67));
            emit(enc_s('ha0,2,1,2)); emit(enc_s('ha4,2,1,2));
            // Enough dispatch/retire cycles to wrap any eight-slot structure.
            for (n = 0; n < 32; n = n + 1) begin
                emit(enc_i(n+1,19,0,19,'h13));
                emit(enc_i(n+3,20,4,20,'h13));
            end
            emit(enc_s('h20,19,1,2));
            emit(enc_s('h24,20,1,2));
            done_pc = p * 4;
            emit(enc_i('h5a5,0,0,31,'h13));
            emit(enc_j(0,0));
        end
    endtask

    task automatic build_trap(input integer kind);
        integer resume_word;
        begin
            emit(32'h8000_00b7);
            emit(enc_i('h300,0,0,2,'h13));
            emit(enc_i('h305,2,1,0,'h73)); // CSRRW mtvec
            emit(enc_i(42,0,0,3,'h13));
            if (kind == 1) emit(32'hffff_ffff);
            if (kind == 2) emit(enc_i(1,1,2,4,3));
            if (kind == 3) begin emit(enc_i('h300,1,2,4,3)); emit(enc_i(0,1,2,5,3)); end
            if (kind == 4) emit(enc_j(2,4));
            if (kind == 5) begin
                emit(enc_j('h40-p*4,0));
                p = 'h40/4;
                emit(enc_i(99,0,0,4,'h13));
            end
            resume_word = p;
            emit(enc_s('h28,3,1,2));
            done_pc = p * 4;
            emit(enc_i('h5a5,0,0,31,'h13));
            emit(enc_j(0,0));
            // Handler reads architectural cause/PC, records them, advances
            // MEPC over the fault and returns. No DUT hierarchy is inspected.
            p = 'h300/4;
            emit(enc_i('h342,0,2,12,'h73));
            emit(enc_i('h341,0,2,13,'h73));
            emit(enc_s('h30,12,1,2));
            emit(enc_s('h34,13,1,2));
            // Misaligned JAL targets the faulting instruction itself +2;
            // the resume PC is still fault PC+4.
            emit(enc_i(4,13,0,13,'h13));
            emit(enc_i('h341,13,1,0,'h73));
            emit(32'h3020_0073);
        end
    endtask

    task automatic build_waw;
        integer resume_word;
        begin
            emit(32'h8000_00b7); // x1 = SRAM base
            emit(enc_i('h300,0,0,2,'h13));
            emit(enc_i('h305,2,1,0,'h73)); // mtvec = 0x300
            emit(enc_i(11,0,0,3,'h13));
            emit(enc_i(22,0,0,3,'h13)); // same-group WAW: lane1 must win
            emit(enc_r(0,0,3,0,4)); // dependent on youngest x3 value
            emit(enc_i(5,0,0,5,'h13));
            emit(enc_s(0,3,1,2));
            emit(enc_b(8,0,0,1)); // not-taken branch realigns the exception pair
            emit(enc_i(33,0,0,3,'h13));
            emit(enc_i(1,1,2,3,3)); // misaligned LW lane1, same encoded rd=x3
            emit(enc_s(4,4,1,2)); // runs after handler skips the faulting load
            emit(enc_s(8,3,1,2));
            done_pc=p*4;
            emit(enc_i('h5a5,0,0,31,'h13)); emit(enc_j(0,0));
            resume_word=p;
            p='h300/4;
            emit(enc_i('h342,0,2,12,'h73));
            emit(enc_i('h341,0,2,13,'h73));
            emit(enc_s('h30,12,1,2));
            emit(enc_s('h34,13,1,2));
            emit(enc_i(4,13,0,13,'h13));
            emit(enc_i('h341,13,1,0,'h73));
            emit(32'h3020_0073);
        end
    endtask

    task automatic check_trace(input [63:0] order_id, input [31:0] pc,
        input [31:0] instr, input [4:0] rd, input [31:0] rd_data,
        input rd_we, input is_trap, input [31:0] cause);
        reg [31:0] inst, a, b, imm, value, next_pc, addr, word_value, csr_old, csr_new;
        reg [31:0] expected_cause, trap_value;
        reg [6:0] opcode;
        reg [2:0] f3;
        reg [4:0] dst, rs1, rs2;
        reg expected_we, expected_trap, taken;
        reg [3:0] strobe;
        integer byte_index, width, lane;
        begin
            if (order_id !== reference_order || pc !== reference_pc)
                $fatal(1, "FAIL: case%0d retirement order/PC expected order=%0d pc=%08x got order=%0d pc=%08x",
                       case_number, reference_order, reference_pc, order_id, pc);
            inst = program_words[reference_pc[9:2]];
            if (!(scenario == 5 && reference_pc == 'h40) && instr !== inst)
                $fatal(1, "FAIL: instruction mismatch pc=%08x expected=%08x actual=%08x", pc, inst, instr);
            opcode = inst[6:0]; f3 = inst[14:12]; dst = inst[11:7];
            rs1 = inst[19:15]; rs2 = inst[24:20];
            a = reference_regs[rs1]; b = reference_regs[rs2];
            imm = {{20{inst[31]}},inst[31:20]}; value = 0;
            next_pc = reference_pc + 4; expected_we = 0; expected_trap = 0;
            expected_cause = 0; trap_value = 0; taken = 0;
            if (scenario == 5 && reference_pc == 'h40) begin
                expected_trap = 1; expected_cause = 1; trap_value = reference_pc;
            end else case (opcode)
                'h37: begin value = {inst[31:12],12'd0}; expected_we = 1; end
                'h17: begin value = reference_pc + {inst[31:12],12'd0}; expected_we = 1; end
                'h13, 'h33: begin
                    expected_we = 1;
                    if (opcode == 'h13) b = imm;
                    if (opcode == 'h33 && inst[31:25] == 1) value = m_result(a,b,f3);
                    else case (f3)
                        0: value = (opcode == 'h33 && inst[30]) ? a-b : a+b;
                        1: value = a << b[4:0];
                        2: value = ($signed(a) < $signed(b));
                        3: value = (a < b);
                        4: value = a ^ b;
                        5: begin
                            if (inst[30]) value = $signed(a) >>> b[4:0];
                            else value = a >> b[4:0];
                        end
                        6: value = a | b;
                        7: value = a & b;
                    endcase
                end
                3, 'h23: begin
                    if (opcode == 'h23) imm = {{20{inst[31]}},inst[31:25],inst[11:7]};
                    addr = a + imm;
                    width = (f3[1:0] == 0) ? 1 : (f3[1:0] == 1) ? 2 : 4;
                    if ((width == 4 && addr[1:0] != 0) || (width == 2 && addr[0])) begin
                        expected_trap = 1; expected_cause = opcode == 3 ? 4 : 6; trap_value = addr;
                    end else if (scenario == 3 && addr == 32'h8000_0300) begin
                        expected_trap = 1; expected_cause = opcode == 3 ? 5 : 7; trap_value = addr;
                    end else if (opcode == 3) begin
                        byte_index = addr[9:0];
                        word_value = {reference_bytes[byte_index+3], reference_bytes[byte_index+2],
                                      reference_bytes[byte_index+1], reference_bytes[byte_index]};
                        case (f3)
                            0: value = {{24{word_value[7]}},word_value[7:0]};
                            1: value = {{16{word_value[15]}},word_value[15:0]};
                            2: value = word_value;
                            4: value = {24'd0,word_value[7:0]};
                            5: value = {16'd0,word_value[15:0]};
                            default: $fatal(1,"FAIL: reference unsupported LOAD");
                        endcase
                        expected_we = 1;
                    end else begin
                        strobe = ((1 << width)-1) << addr[1:0];
                        expected_store_addr[expected_stores] = {addr[31:2],2'b00};
                        expected_store_data[expected_stores] = b << (addr[1:0]*8);
                        expected_store_mask[expected_stores] = strobe;
                        expected_stores = expected_stores + 1;
                        for (lane = 0; lane < width; lane = lane + 1)
                            reference_bytes[addr[9:0]+lane] = b[lane*8 +: 8];
                    end
                end
                'h63: begin
                    imm = {{19{inst[31]}},inst[31],inst[7],inst[30:25],inst[11:8],1'b0};
                    case (f3)
                        0: taken = a == b; 1: taken = a != b;
                        4: taken = $signed(a) < $signed(b); 5: taken = $signed(a) >= $signed(b);
                        6: taken = a < b; 7: taken = a >= b;
                    endcase
                    if (taken) next_pc = reference_pc + imm;
                end
                'h6f: begin
                    imm = {{11{inst[31]}},inst[31],inst[19:12],inst[20],inst[30:21],1'b0};
                    value = reference_pc + 4; expected_we = 1; next_pc = reference_pc + imm;
                end
                'h67: begin value = reference_pc+4; expected_we = 1; next_pc = (a+imm) & 32'hffff_fffe; end
                'h73: begin
                    if (inst == 32'h3020_0073) begin
                        next_pc = reference_mepc;
                        reference_mstatus = (reference_mstatus & ~32'h88) |
                                            ((reference_mstatus & 32'h80) >> 4) | 32'h1880;
                    end
                    else if (inst == 32'h0000_0073 || inst == 32'h0010_0073) begin
                        expected_trap = 1; expected_cause = inst[20] ? 3 : 11;
                    end else begin
                        case (inst[31:20])
                            'h305: csr_old = reference_mtvec;
                            'h341: csr_old = reference_mepc;
                            'h342: csr_old = reference_mcause;
                            'h343: csr_old = reference_mtval;
                            'h300: csr_old = reference_mstatus;
                            'h304: csr_old = reference_mie;
                            default: $fatal(1,"FAIL: reference unsupported CSR %03x",inst[31:20]);
                        endcase
                        b = f3[2] ? {27'd0,rs1} : a;
                        case (f3[1:0])
                            1: csr_new = b; 2: csr_new = csr_old | b; 3: csr_new = csr_old & ~b;
                            default: $fatal(1,"FAIL: reference invalid CSR operation");
                        endcase
                        if (f3[1:0] == 1 || rs1 != 0) begin
                            case (inst[31:20])
                                'h305: reference_mtvec = csr_new & 32'hffff_fffc;
                                'h341: reference_mepc = csr_new & 32'hffff_fffc;
                                'h342: reference_mcause = csr_new;
                                'h343: reference_mtval = csr_new;
                                'h300: reference_mstatus = (csr_new & 32'h88) | 32'h1800;
                                'h304: reference_mie = csr_new & 32'h880;
                            endcase
                        end
                        value = csr_old; expected_we = 1;
                    end
                end
                default: begin expected_trap = 1; expected_cause = 2; trap_value = inst; end
            endcase
            if (!expected_trap && next_pc[1:0] != 0) begin
                expected_trap = 1; expected_cause = 0; trap_value = next_pc;
            end
            expected_we = expected_we && dst != 0 && !expected_trap;
            if (is_trap !== expected_trap || (expected_trap && cause !== expected_cause))
                $fatal(1,"FAIL: trap mismatch pc=%08x exp=%b/%08x got=%b/%08x",pc,expected_trap,expected_cause,is_trap,cause);
            if (rd_we !== expected_we || (expected_we && (rd !== dst || rd_data !== value)))
                $fatal(1,"FAIL: register result pc=%08x inst=%08x exp we=%b x%0d=%08x got we=%b x%0d=%08x",
                       pc,inst,expected_we,dst,value,rd_we,rd,rd_data);
            if (expected_trap) begin
                reference_mepc = reference_pc; reference_mcause = expected_cause;
                reference_mtval = trap_value; next_pc = reference_mtvec; checked_traps = checked_traps + 1;
                reference_mstatus = (reference_mstatus & ~32'h88) |
                                    ((reference_mstatus & 8) << 4) | 32'h1800;
            end else begin
                if (expected_we) reference_regs[dst] = value;
                checked_instructions = checked_instructions + 1;
                if (reference_pc == done_pc) done = 1;
            end
            reference_regs[0] = 0;
            reference_pc = next_pc; reference_order = reference_order + 1;
        end
    endtask

    task automatic check_event(input [63:0] order_id, input [31:0] pc,
        input [31:0] instr, input [4:0] rd, input [31:0] rd_data,
        input rd_we, input is_trap, input [31:0] cause);
        begin
            if ((scenario == 6 || scenario == 7) && is_trap && cause == 32'h8000_0007) begin
                if (irq_seen || !timer_irq || order_id !== reference_order || pc !== reference_pc || rd_we)
                    $fatal(1,"FAIL: IRQ event not at precise next-instruction boundary pc=%08x expected=%08x",pc,reference_pc);
                irq_seen = 1;
                if (scenario == 7 && scenario7_read_outstanding && pending &&
                    !scenario7_read_payload[36] && scenario7_read_payload[68:37] == 32'h8000_0000) begin
                    irq_with_read_pending = 1;
                    // Tag and poison only the exact pre-IRQ read transaction
                    // whose response is still pending; post-MRET replays differ.
                    stale_requests_tagged = stale_requests_tagged + 1;
                    stale_response_pending_q = 1;
                    response_error_q = 1;
                    response_data_q = 32'hdead_beef;
                end
                reference_order = reference_order + 1;
                reference_mepc = reference_pc; reference_mcause = cause; reference_mtval = 0;
                reference_pc = reference_mtvec;
                reference_mstatus = (reference_mstatus & ~32'h88) |
                                    ((reference_mstatus & 8) << 4) | 32'h1800;
                checked_traps = checked_traps + 1;
            end else check_trace(order_id,pc,instr,rd,rd_data,rd_we,is_trap,cause);
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            if (issue1 && !issue0) $fatal(1,"FAIL: second issue without first");
            if (trace1_valid && !trace0_valid) $fatal(1,"FAIL: second retirement without first");
            if (issue0 && issue1) dual_issues = dual_issues + 1;
            if (trace0_valid && trace1_valid) dual_retires = dual_retires + 1;
            if (scenario == 9 && issue0 && issue1 && dut.fq_pc[0] == waw_pair_pc && dut.fq_pc[1] == waw_pair_pc+4)
                waw_issue_seen = waw_issue_seen + 1;
            if (scenario == 9 && issue0 && issue1 && dut.fq_pc[0] == waw_exception_pair_pc)
                waw_exception_pair_seen = waw_exception_pair_seen + 1;
            if (scenario == 9 && trace0_valid && trace1_valid && trace0_pc == waw_pair_pc &&
                trace1_pc == waw_pair_pc+4 && trace0_rd == 3 && trace1_rd == 3 &&
                trace0_rd_we && trace1_rd_we && trace0_rd_data == 11 && trace1_rd_data == 22)
                waw_commit_seen = waw_commit_seen + 1;
            if (scenario == 7 && issue0 && issue1 && dut.fq_pc[0] == irq_waw_pair_pc && dut.fq_pc[1] == irq_waw_pair_pc+4)
                irq_waw_issue_seen = irq_waw_issue_seen + 1;
            if (scenario == 7 && trace0_valid && trace0_pc == irq_waw_pair_pc &&
                trace0_rd == 3 && trace0_rd_we && trace0_rd_data == 77)
                irq_waw_commit_seen = irq_waw_commit_seen + 1;
            if (scenario == 7 && trace1_valid && trace1_pc == irq_waw_pair_pc &&
                trace1_rd == 3 && trace1_rd_we && trace1_rd_data == 77)
                irq_waw_commit_seen = irq_waw_commit_seen + 1;
            if (scenario == 7 && trace0_valid && trace0_pc == irq_waw_pair_pc+4 &&
                trace0_rd == 3 && trace0_rd_we && trace0_rd_data == 17)
                irq_waw_commit_seen = irq_waw_commit_seen + 1;
            if (scenario == 7 && trace1_valid && trace1_pc == irq_waw_pair_pc+4 &&
                trace1_rd == 3 && trace1_rd_we && trace1_rd_data == 17)
                irq_waw_commit_seen = irq_waw_commit_seen + 1;
            if (scenario == 0) begin
                allocated = allocated + issue0 + issue1;
                outstanding = outstanding + issue0 + issue1 - trace0_valid - trace1_valid;
                if (outstanding > max_outstanding) max_outstanding = outstanding;
                if (outstanding < 0 || outstanding > 8)
                    $fatal(1,"FAIL: completion-buffer credit exceeded %0d",outstanding);
                if (issue0 && issue1 && trace0_valid && trace1_valid) dual_turnovers = dual_turnovers + 1;
            end
            if (trace0_valid) check_event(trace0_order,trace0_pc,trace0_instr,trace0_rd,trace0_rd_data,trace0_rd_we,trace0_trap,trace0_cause);
            if (trace1_valid) check_event(trace1_order,trace1_pc,trace1_instr,trace1_rd,trace1_rd_data,trace1_rd_we,trace1_trap,trace1_cause);
        end
    end

    task automatic run_case(input integer kind, input integer latency);
        integer n, timeout_cycles;
        reg [31:0] mask_bits;
        begin
            @(negedge clk); rst = 1;
            case_number = case_number + 1; scenario = kind; latency_mode = latency;
            accepted_stores = 0; expected_stores = 0; reference_pc = 0; reference_order = 0;
            reference_mtvec = 0; reference_mepc = 0; reference_mcause = 0; reference_mtval = 0;
            reference_mstatus = 32'h1800; reference_mie = 0; irq_arm = 0; irq_seen = 0;
            bp_started = 0; bp_finished = 0; irq_with_read_pending = 0; bp_remaining = 0; stale_injections = 0;
            stale_requests_tagged = 0; stale_response_pending_q = 0;
            scenario7_read_outstanding = 0; scenario7_read_payload = 0;
            allocated = 0; outstanding = 0; max_outstanding = 0; dual_turnovers = 0;
            dual_issues = 0; dual_retires = 0; checked_instructions = 0; checked_traps = 0; done = 0;
            waw_issue_seen = 0; waw_commit_seen = 0; waw_exception_pair_seen = 0;
            irq_waw_issue_seen = 0; irq_waw_commit_seen = 0;
            for (n = 0; n < 32; n = n + 1) reference_regs[n] = 0;
            for (n = 0; n < 1024; n = n + 1) begin memory_bytes[n] = 0; reference_bytes[n] = 0; end
            for (n = 0; n < 256; n = n + 1) program_words[n] = 32'h0000_0013;
            p = 0;
            if (kind == 0) build_normal();
            else if (kind == 6 || kind == 7) build_irq();
            else if (kind == 9) build_waw();
            else build_trap(kind);
            repeat (7) @(negedge clk);
            rst = 0; timeout_cycles = 0;
            while (!done && timeout_cycles < 10000) begin @(negedge clk); timeout_cycles = timeout_cycles + 1; end
            if (!done) $fatal(1,"FAIL: case%0d timeout reference_pc=%08x commits=%0d",case_number,reference_pc,checked_instructions);
            repeat (40) @(negedge clk);
            if (accepted_stores != expected_stores)
                $fatal(1,"FAIL: case%0d store count expected=%0d actual=%0d",case_number,expected_stores,accepted_stores);
            for (n = 0; n < expected_stores; n = n + 1) begin
                mask_bits = {{8{expected_store_mask[n][3]}},{8{expected_store_mask[n][2]}},
                             {8{expected_store_mask[n][1]}},{8{expected_store_mask[n][0]}}};
                if (actual_store_addr[n] !== expected_store_addr[n] || actual_store_mask[n] !== expected_store_mask[n] ||
                    (actual_store_data[n] & mask_bits) !== (expected_store_data[n] & mask_bits))
                    $fatal(1,"FAIL: case%0d store%0d mismatch addr %08x/%08x mask %x/%x data %08x/%08x",
                           case_number,n,expected_store_addr[n],actual_store_addr[n],expected_store_mask[n],actual_store_mask[n],
                           expected_store_data[n],actual_store_data[n]);
            end
            for (n = 0; n < 1024; n = n + 1)
                if (memory_bytes[n] !== reference_bytes[n]) $fatal(1,"FAIL: final memory byte %0d differs",n);
            if (kind == 0 && (dual_issues < 1 || dual_retires < 1 || checked_instructions < 100))
                $fatal(1,"FAIL: missing dual issue/retire/ring-wrap activity issues=%0d retires=%0d checked=%0d",dual_issues,dual_retires,checked_instructions);
            if (kind != 0 && checked_traps != 1) $fatal(1,"FAIL: expected one precise trap, got %0d",checked_traps);
            if (kind == 0 && latency == 3 && (max_outstanding != 8 || dual_turnovers == 0 || allocated < 32))
                $fatal(1,"FAIL: missing full-buffer/dual-turnover/wrap coverage max=%0d both=%0d allocated=%0d",max_outstanding,dual_turnovers,allocated);
            if (kind == 7 && (!irq_with_read_pending || stale_requests_tagged != 1 ||
                stale_injections != 1 || stale_response_pending_q))
                $fatal(1,"FAIL: missing stale pre-IRQ response coverage outstanding=%0d tagged=%0d drained=%0d pending=%0d",
                    irq_with_read_pending,stale_requests_tagged,stale_injections,stale_response_pending_q);
            if (kind == 7 && (irq_waw_issue_seen != 1 || irq_waw_commit_seen != 2))
                $fatal(1,"FAIL: IRQ case did not issue and dual-commit same-rd WAW before interruption issue=%0d commit=%0d",irq_waw_issue_seen,irq_waw_commit_seen);
            if (kind == 9) begin
                if (waw_issue_seen != 1) $fatal(1,"FAIL: same-rd WAW pair did not issue exactly once");
                if (waw_commit_seen != 1) $fatal(1,"FAIL: same-rd WAW pair did not dual-commit lane0=11 lane1=22");
                if (waw_exception_pair_seen != 1) $fatal(1,"FAIL: same-rd misaligned-load pair did not issue together");
            end
            if (bus_requests != bus_responses) $fatal(1,"FAIL: request/response mismatch req=%0d rsp=%0d",bus_requests,bus_responses);
            $display("BUS: req=%0d rsp=%0d turnover=%0d load-load=%0d store-load=%0d error-blocked=%0d",bus_requests,bus_responses,bus_turnovers,load_load,store_load,error_blocked);
            if (kind == 0 && latency == 1 && (load_load < 2 || store_load < 1)) $fatal(1,"FAIL: missing load-load/store-load turnover");
            if (kind == 3 && error_blocked < 1) $fatal(1,"FAIL: error response not observed");
            if (kind == 0 && latency == 3)
                $display("COVERAGE: reserved peak=%0d dual-in/out=%0d allocated=%0d",max_outstanding,dual_turnovers,allocated);
            if (kind == 7)
                $display("COVERAGE: IRQ with pre-IRQ read response pending=%0d tagged=%0d stale-error responses drained=%0d pending=%0d",
                    irq_with_read_pending,stale_requests_tagged,stale_injections,stale_response_pending_q);
            $display("PASS: five-stage case%0d kind=%0d latency=%0d commits=%0d traps=%0d stores=%0d dual=%0d/%0d",
                     case_number,kind,latency,checked_instructions,checked_traps,expected_stores,dual_issues,dual_retires);
        end
    endtask

    initial begin
        if ($test$plusargs("WAW_ONLY")) run_case(9,2);
        else begin
            run_case(0,0);
            run_case(0,1);
            run_case(0,2);
            run_case(0,3);
            run_case(1,2);
            run_case(2,2);
            run_case(3,2);
            run_case(4,1);
            run_case(5,2);
            run_case(6,2);
            run_case(7,3);
            run_case(9,2);
        end
        $display("DUAL_5STAGE_CORE_RESULT: PASS");
        $display("ALL TESTS PASSED (dual five-stage architectural scoreboard)");
        $finish;
    end
endmodule
