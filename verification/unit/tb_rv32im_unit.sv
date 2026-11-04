`timescale 1ns/1ps

module tb_rv32im_unit;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg [2:0] funct3 = 3'b0;
    reg [31:0] operand_a = 32'b0;
    reg [31:0] operand_b = 32'b0;
    wire ready, done;
    wire [31:0] result;
    integer checks = 0;
    integer i, j, f;
    reg [31:0] corners [0:15];
    reg [31:0] random_a, random_b;

    always #5 clk = ~clk;

    rv32im_unit dut (
        .clk_i(clk), .rst_i(rst), .start_i(start), .funct3_i(funct3),
        .operand_a_i(operand_a), .operand_b_i(operand_b),
        .ready_o(ready), .done_o(done), .result_o(result)
    );

    // Mathematical 64-bit reference, independent of the DUT's partial-product
    // widths, accumulation stages and signed-high correction formula.
    function automatic [31:0] mul_reference(input [2:0] operation,
                                            input [31:0] a, input [31:0] b);
        reg [63:0] unsigned_product;
        reg signed [63:0] signed_a, signed_b, mixed_b;
        reg signed [63:0] signed_product, mixed_product;
        begin
            unsigned_product = {32'b0, a} * {32'b0, b};
            signed_a = {{32{a[31]}}, a};
            signed_b = {{32{b[31]}}, b};
            mixed_b = {32'b0, b};
            signed_product = signed_a * signed_b;
            mixed_product = signed_a * mixed_b;
            case (operation)
                3'b000: mul_reference = unsigned_product[31:0];
                3'b001: mul_reference = signed_product[63:32];
                3'b010: mul_reference = mixed_product[63:32];
                default: mul_reference = unsigned_product[63:32];
            endcase
        end
    endfunction

    task automatic check_mul(input [2:0] f, input [31:0] a, input [31:0] b,
                             input [31:0] expected);
        integer waited;
        begin
            @(negedge clk);
            if (ready !== 1'b1) $fatal(1, "MDU not ready before multiply case %0d", checks);
            funct3 = f;
            operand_a = a;
            operand_b = b;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            waited = 0;
            while (!done && waited < 6) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (!done) $fatal(1, "multiply did not complete: funct3=%b a=%h b=%h", f, a, b);
            if (result !== expected)
                $fatal(1, "multiply mismatch: funct3=%b a=%h b=%h got=%h expected=%h",
                       f, a, b, result, expected);
            checks = checks + 1;
        end
    endtask

    task automatic check_mul_latency(input [2:0] f, input [31:0] a, input [31:0] b,
                                     input [31:0] expected, input integer expected_cycles);
        integer waited;
        begin
            @(negedge clk);
            if (ready !== 1'b1) $fatal(1, "MDU not ready before latency check");
            funct3 = f;
            operand_a = a;
            operand_b = b;
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;
            waited = 0;
            while (done !== 1'b1 && waited < 8) begin
                @(posedge clk); #1;
                waited = waited + 1;
            end
            if (done !== 1'b1 || result !== expected || waited != expected_cycles)
                $fatal(1, "multiply latency mismatch: funct3=%b cycles=%0d expected=%0d result=%h expected_result=%h",
                       f, waited, expected_cycles, result, expected);
            checks = checks + 1;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst = 1'b0;

        // A=INT_MIN, B in {0, 1, INT_MIN, UINT_MAX}; order MUL/MULH/MULHSU/MULHU.
        check_mul(3'b000, 32'h8000_0000, 32'h0000_0000, 32'h0000_0000);
        check_mul(3'b001, 32'h8000_0000, 32'h0000_0000, 32'h0000_0000);
        check_mul(3'b010, 32'h8000_0000, 32'h0000_0000, 32'h0000_0000);
        check_mul(3'b011, 32'h8000_0000, 32'h0000_0000, 32'h0000_0000);
        check_mul(3'b000, 32'h8000_0000, 32'h0000_0001, 32'h8000_0000);
        check_mul(3'b001, 32'h8000_0000, 32'h0000_0001, 32'hffff_ffff);
        check_mul(3'b010, 32'h8000_0000, 32'h0000_0001, 32'hffff_ffff);
        check_mul(3'b011, 32'h8000_0000, 32'h0000_0001, 32'h0000_0000);
        check_mul(3'b000, 32'h8000_0000, 32'h8000_0000, 32'h0000_0000);
        check_mul(3'b001, 32'h8000_0000, 32'h8000_0000, 32'h4000_0000);
        check_mul(3'b010, 32'h8000_0000, 32'h8000_0000, 32'hc000_0000);
        check_mul(3'b011, 32'h8000_0000, 32'h8000_0000, 32'h4000_0000);
        check_mul(3'b000, 32'h8000_0000, 32'hffff_ffff, 32'h8000_0000);
        check_mul(3'b001, 32'h8000_0000, 32'hffff_ffff, 32'h0000_0000);
        check_mul(3'b010, 32'h8000_0000, 32'hffff_ffff, 32'h8000_0000);
        check_mul(3'b011, 32'h8000_0000, 32'hffff_ffff, 32'h7fff_ffff);

        // A=UINT_MAX (-1 signed), same B set; order MUL/MULH/MULHSU/MULHU.
        check_mul(3'b000, 32'hffff_ffff, 32'h0000_0000, 32'h0000_0000);
        check_mul(3'b001, 32'hffff_ffff, 32'h0000_0000, 32'h0000_0000);
        check_mul(3'b010, 32'hffff_ffff, 32'h0000_0000, 32'h0000_0000);
        check_mul(3'b011, 32'hffff_ffff, 32'h0000_0000, 32'h0000_0000);
        check_mul(3'b000, 32'hffff_ffff, 32'h0000_0001, 32'hffff_ffff);
        check_mul(3'b001, 32'hffff_ffff, 32'h0000_0001, 32'hffff_ffff);
        check_mul(3'b010, 32'hffff_ffff, 32'h0000_0001, 32'hffff_ffff);
        check_mul(3'b011, 32'hffff_ffff, 32'h0000_0001, 32'h0000_0000);
        check_mul(3'b000, 32'hffff_ffff, 32'h8000_0000, 32'h8000_0000);
        check_mul(3'b001, 32'hffff_ffff, 32'h8000_0000, 32'h0000_0000);
        check_mul(3'b010, 32'hffff_ffff, 32'h8000_0000, 32'hffff_ffff);
        check_mul(3'b011, 32'hffff_ffff, 32'h8000_0000, 32'h7fff_ffff);
        check_mul(3'b000, 32'hffff_ffff, 32'hffff_ffff, 32'h0000_0001);
        check_mul(3'b001, 32'hffff_ffff, 32'hffff_ffff, 32'h0000_0000);
        check_mul(3'b010, 32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff);
        check_mul(3'b011, 32'hffff_ffff, 32'hffff_ffff, 32'hffff_fffe);

        // Low MUL returns after the first registered partial-product stage;
        // high-half MUL keeps the later accumulation/correction stages.
        check_mul_latency(3'b000, 32'hffff_ffff, 32'h0000_0002, 32'hffff_fffe, 2);
        check_mul_latency(3'b001, 32'hffff_ffff, 32'h0000_0002, 32'hffff_ffff, 4);

        // The signed-high reproducer has an unsigned high word of 0x12345677.
        // Its two cross terms overflow their low half without the low product
        // addition overflowing: double-counting that carry returns 0, not -1.
        check_mul(3'b001, 32'h1234_5678, 32'hffff_ffff, 32'hffff_ffff);
        check_mul(3'b011, 32'h1234_5678, 32'hffff_ffff, 32'h1234_5677);
        // Here both additions carry; losing the extra carry returns 2, not 3.
        check_mul(3'b011, 32'h0001_ffff, 32'h0001_ffff, 32'h0000_0003);

        // Exercise both operand orders, half-word boundaries, sign boundaries,
        // every multiply signedness, and different carry combinations.
        corners[0] = 32'h0000_0000; corners[1] = 32'h0000_0001;
        corners[2] = 32'h0000_0002; corners[3] = 32'h0000_ffff;
        corners[4] = 32'h0001_0000; corners[5] = 32'h0001_0001;
        corners[6] = 32'h0001_ffff; corners[7] = 32'h7fff_ffff;
        corners[8] = 32'h8000_0000; corners[9] = 32'hffff_ffff;
        corners[10] = 32'h1234_5678; corners[11] = 32'h89ab_cdef;
        corners[12] = 32'hffff_0001; corners[13] = 32'hffff_8000;
        corners[14] = 32'h0001_8000; corners[15] = 32'h8000_0001;
        for (i = 0; i < 16; i = i + 1)
            for (j = 0; j < 16; j = j + 1)
                for (f = 0; f < 4; f = f + 1)
                    check_mul(f[2:0], corners[i], corners[j],
                              mul_reference(f[2:0], corners[i], corners[j]));

        // Reproducible full-width inputs use the same mathematical oracle.
        random_a = 32'h6d2b_79f5;
        random_b = 32'ha5c3_1e27;
        for (i = 0; i < 128; i = i + 1) begin
            random_a = random_a * 32'd1664525 + 32'd1013904223;
            random_b = random_b * 32'd22695477 + 32'd1;
            for (f = 0; f < 4; f = f + 1)
                check_mul(f[2:0], random_a, random_b,
                          mul_reference(f[2:0], random_a, random_b));
        end

        $display("PASS tb_rv32im_unit checks=%0d", checks);
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
