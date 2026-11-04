`timescale 1ns/1ps

module tb_cpu_rv32im #(parameter integer M_MODE = 2);
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
    reg [31:0] d_rsp_rdata_q = 32'b0;
    wire trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data, trace_cause;
    wire [4:0] trace_rd;
    reg timer_irq_i = 1'b0, ext_irq_i = 1'b0;

    function automatic [31:0] enc_r(input [6:0] funct7, input [4:0] rs2,
                                     input [4:0] rs1, input [2:0] funct3,
                                     input [4:0] rd);
        enc_r = {funct7, rs2, rs1, funct3, rd, 7'h33};
    endfunction
    function automatic [31:0] enc_i(input integer imm, input [4:0] rs1,
                                     input [2:0] funct3, input [4:0] rd,
                                     input [6:0] opcode);
        enc_i = {imm[11:0], rs1, funct3, rd, opcode};
    endfunction
    function automatic [31:0] enc_b(input integer imm, input [4:0] rs2,
                                     input [4:0] rs1, input [2:0] funct3);
        enc_b = {imm[12], imm[10:5], rs2, rs1, funct3,
                 imm[4:1], imm[11], 7'h63};
    endfunction
    function automatic [31:0] enc_s(input integer imm, input [4:0] rs2,
                                     input [4:0] rs1, input [2:0] funct3);
        enc_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'h23};
    endfunction
    function automatic [31:0] rom(input [31:0] addr);
        case (addr)
            32'h00: rom = enc_i(-7, 0, 3'b000, 1, 7'h13);                 // addi x1,x0,-7
            32'h04: rom = enc_i(9, 0, 3'b000, 2, 7'h13);                  // addi x2,x0,9
            32'h08: rom = enc_r(7'h01, 2, 1, 3'b000, 3);                 // mul x3,x1,x2
            32'h0c: rom = enc_i(1, 3, 3'b000, 21, 7'h13);                // RAW: addi x21,x3,1
            32'h10: rom = enc_r(7'h01, 2, 1, 3'b001, 4);                 // mulh
            32'h14: rom = enc_r(7'h01, 2, 1, 3'b010, 5);                 // mulhsu
            32'h18: rom = enc_r(7'h01, 2, 1, 3'b011, 6);                 // mulhu
            32'h1c: rom = 32'h800003b7;                                   // lui x7,0x80000
            32'h20: rom = enc_i(-1, 0, 3'b000, 8, 7'h13);                // addi x8,x0,-1
            32'h24: rom = enc_r(7'h01, 8, 7, 3'b001, 9);                 // mulh INT_MIN,-1
            32'h28: rom = enc_r(7'h01, 8, 7, 3'b010, 10);                // mulhsu INT_MIN,UINT_MAX
            32'h2c: rom = enc_r(7'h01, 8, 8, 3'b011, 11);                // mulhu UINT_MAX^2
            32'h30: rom = enc_r(7'h01, 2, 1, 3'b100, 12);                // div -7,9
            32'h34: rom = enc_r(7'h01, 2, 1, 3'b110, 13);                // rem -7,9
            32'h38: rom = enc_r(7'h01, 2, 8, 3'b101, 14);                // divu UINT_MAX,9
            32'h3c: rom = enc_r(7'h01, 2, 8, 3'b111, 15);                // remu UINT_MAX,9
            32'h40: rom = enc_r(7'h01, 0, 1, 3'b100, 16);                // div by zero
            32'h44: rom = enc_r(7'h01, 0, 1, 3'b110, 17);                // rem by zero
            32'h48: rom = enc_r(7'h01, 8, 7, 3'b100, 18);                // INT_MIN / -1
            32'h4c: rom = enc_r(7'h01, 8, 7, 3'b110, 19);                // INT_MIN % -1
            32'h50: rom = enc_r(7'h01, 2, 1, 3'b100, 20);                // div -> 0
            32'h54: rom = enc_b(12, 0, 20, 3'b000);                      // branch immediately after DIV
            32'h58: rom = enc_s(0, 3, 0, 3'b010);                        // wrong-path store, must be flushed
            32'h5c: rom = enc_i(99, 0, 3'b000, 22, 7'h13);               // wrong-path register write
            32'h60: rom = enc_s(0, 3, 0, 3'b010);                        // one real store
            32'h64: rom = enc_i(3, 0, 3'b000, 22, 7'h13);                // completion marker
            32'h68: rom = 32'h0000006f;                                   // jal x0,0
            default: rom = 32'h00000013;
        endcase
    endfunction

    assign i_req_ready = 1'b1;
    assign d_req_ready = 1'b1;
    assign d_rsp_rdata = d_rsp_rdata_q;

    always @(posedge clk) begin
        if (rst) begin
            i_rsp_valid <= 1'b0;
            i_rsp_data <= 32'h00000013;
            d_rsp_valid <= 1'b0;
            d_rsp_rdata_q <= 32'b0;
        end else begin
            i_rsp_valid <= i_req_valid && i_req_ready;
            if (i_req_valid && i_req_ready) i_rsp_data <= rom(i_req_addr);
            d_rsp_valid <= d_req_valid && d_req_ready;
            if (d_req_valid && d_req_ready) d_rsp_rdata_q <= 32'b0;
        end
    end

    integer cycles = 0;
    integer retired = 0;
    integer store_accepts = 0;
    integer traps = 0;
    integer pc_seen [0:26];
    integer i;
    reg [31:0] memory_word = 0;
    reg finished = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            store_accepts <= 0;
            memory_word <= 0;
        end else begin
            cycles <= cycles + 1;
            if (d_req_valid && d_req_ready && d_req_write) begin
                store_accepts <= store_accepts + 1;
                if (d_req_addr !== 32'b0 || d_req_wstrb !== 4'hf)
                    $fatal(1, "unexpected store request addr=%h strb=%h", d_req_addr, d_req_wstrb);
                memory_word <= d_req_wdata;
            end
        end
    end

    always @(negedge clk) begin
        if (!rst && dut.mdu_wait && !(dut.pc_hold && dut.if_id_hold && dut.id_ex_hold &&
                                      dut.ex_mem_hold && dut.mem_wb_hold && dut.retire_block))
            $fatal(1, "multi-cycle M operation did not freeze all pipeline stages/retire");
        if (!rst && trace_valid && !finished) begin
            if (trace_order !== retired)
                $fatal(1, "retire order skipped/duplicated: got=%0d expected=%0d", trace_order, retired);
            retired = retired + 1;
            if ((trace_pc[1:0] != 0) || (trace_pc > 32'h68))
                $fatal(1, "unexpected retire PC %h", trace_pc);
            pc_seen[trace_pc[7:2]] = pc_seen[trace_pc[7:2]] + 1;
            if (trace_pc == 32'h58 || trace_pc == 32'h5c)
                $fatal(1, "wrong-path instruction retired at %h", trace_pc);
            if (trace_trap) begin
                traps = traps + 1;
                if (trace_cause != 32'd2)
                    $fatal(1, "unexpected trap cause %h", trace_cause);
                if (M_MODE == 2)
                    $fatal(1, "full M mode trapped at pc=%h instr=%h", trace_pc, trace_instr);
                if (M_MODE == 0 && trace_pc != 32'h08)
                    $fatal(1, "no-M mode did not reject the first MUL: pc=%h", trace_pc);
                if (M_MODE == 1 && trace_pc != 32'h30)
                    $fatal(1, "Zmmul mode did not reject the first DIV: pc=%h", trace_pc);
                finished = 1'b1;
            end else if (trace_rd_we) begin
                case (trace_rd)
                    1: if (trace_rd_data !== 32'hffff_fff9) $fatal(1, "x1=%h", trace_rd_data);
                    2: if (trace_rd_data !== 32'd9) $fatal(1, "x2=%h", trace_rd_data);
                    3: if (trace_rd_data !== 32'hffff_ffc1) $fatal(1, "MUL x3=%h", trace_rd_data);
                    4: if (trace_rd_data !== 32'hffff_ffff) $fatal(1, "MULH x4=%h", trace_rd_data);
                    5: if (trace_rd_data !== 32'hffff_ffff) $fatal(1, "MULHSU x5=%h", trace_rd_data);
                    6: if (trace_rd_data !== 32'd8) $fatal(1, "MULHU x6=%h", trace_rd_data);
                    7: if (trace_rd_data !== 32'h8000_0000) $fatal(1, "LUI x7=%h", trace_rd_data);
                    8: if (trace_rd_data !== 32'hffff_ffff) $fatal(1, "x8=%h", trace_rd_data);
                    9: if (trace_rd_data !== 32'd0) $fatal(1, "MULH boundary x9=%h", trace_rd_data);
                    10: if (trace_rd_data !== 32'h8000_0000) $fatal(1, "MULHSU boundary x10=%h", trace_rd_data);
                    11: if (trace_rd_data !== 32'hffff_fffe) $fatal(1, "MULHU boundary x11=%h", trace_rd_data);
                    12: if (trace_rd_data !== 32'd0) $fatal(1, "DIV -7/9 x12=%h", trace_rd_data);
                    13: if (trace_rd_data !== 32'hffff_fff9) $fatal(1, "REM -7/9 x13=%h", trace_rd_data);
                    14: if (trace_rd_data !== 32'h1c71_c71c) $fatal(1, "DIVU x14=%h", trace_rd_data);
                    15: if (trace_rd_data !== 32'd3) $fatal(1, "REMU x15=%h", trace_rd_data);
                    16: if (trace_rd_data !== 32'hffff_ffff) $fatal(1, "DIV by zero x16=%h", trace_rd_data);
                    17: if (trace_rd_data !== 32'hffff_fff9) $fatal(1, "REM by zero x17=%h", trace_rd_data);
                    18: if (trace_rd_data !== 32'h8000_0000) $fatal(1, "INT_MIN/-1 x18=%h", trace_rd_data);
                    19: if (trace_rd_data !== 32'd0) $fatal(1, "INT_MIN%-1 x19=%h", trace_rd_data);
                    20: if (trace_rd_data !== 32'd0) $fatal(1, "DIV branch input x20=%h", trace_rd_data);
                    21: if (trace_rd_data !== 32'hffff_ffc2) $fatal(1, "RAW after MUL x21=%h", trace_rd_data);
                    22: begin
                        if (trace_rd_data !== 32'd3) $fatal(1, "completion x22=%h", trace_rd_data);
                        if (M_MODE != 2) $fatal(1, "extension mode reached full-M completion unexpectedly");
                        if (store_accepts != 1 || memory_word !== 32'hffff_ffc1)
                            $fatal(1, "store side effect count/data wrong: count=%0d data=%h", store_accepts, memory_word);
                        if (traps != 0 || retired != 24)
                            $fatal(1, "full-M retirement/trap count wrong: retired=%0d traps=%0d", retired, traps);
                        if (pc_seen[21] != 1 || pc_seen[22] != 0 || pc_seen[23] != 0 || pc_seen[24] != 1)
                            $fatal(1, "branch/store PC counts wrong: wrong store=%0d wrong addi=%0d right store=%0d", pc_seen[22], pc_seen[23], pc_seen[24]);
                        if (pc_seen[2] != 1 || pc_seen[12] != 1 || pc_seen[20] != 1)
                            $fatal(1, "M instruction retirement count wrong: mul=%0d div=%0d branch-div=%0d", pc_seen[2], pc_seen[12], pc_seen[20]);
                        finished = 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    cpu_core_stage1 #(.BTB_ENABLE(1'b0), .M_MODE(M_MODE)) dut (
        .clk(clk), .rst(rst), .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(1'b0), .d_req_valid(d_req_valid),
        .d_req_ready(d_req_ready), .d_req_addr(d_req_addr), .d_req_write(d_req_write),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rsp_rdata),
        .d_rsp_error(1'b0), .timer_irq_i(timer_irq_i), .ext_irq_i(ext_irq_i),
        .trace_valid(trace_valid), .trace_order(trace_order), .trace_pc(trace_pc),
        .trace_instr(trace_instr), .trace_rd(trace_rd), .trace_rd_data(trace_rd_data),
        .trace_rd_we(trace_rd_we), .trace_trap(trace_trap), .trace_cause(trace_cause)
    );

    initial begin
        for (i = 0; i <= 26; i = i + 1) pc_seen[i] = 0;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        for (i = 0; i < 800 && !finished; i = i + 1) @(negedge clk);
        if (!finished) $fatal(1, "timeout: mode=%0d cycles=%0d retired=%0d", M_MODE, cycles, retired);
        if (M_MODE == 0 && (traps != 1 || retired != 3 || store_accepts != 0))
            $fatal(1, "no-M illegal-instruction negative control failed");
        if (M_MODE == 1 && (traps != 1 || store_accepts != 0))
            $fatal(1, "Zmmul DIV-illegal negative control failed");
        $display("PASS: CPU RV32IM mode=%0d cycles=%0d retired=%0d CPI=%.3f traps=%0d stores=%0d",
                 M_MODE, cycles, retired, (1.0 * cycles) / retired, traps, store_accepts);
        $display("PASS tb_cpu_rv32im mode=%0d", M_MODE);
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
