`timescale 1ns/1ps

module tb_hazard_detection;
    reg  [4:0] id_rs1;
    reg  [4:0] id_rs2;
    reg        id_uses_rs1;
    reg        id_uses_rs2;
    reg        ex_valid;
    reg        ex_is_load;
    reg        ex_writes_rd;
    reg  [4:0] ex_rd;
    wire       load_use_stall;

    integer checks;
    integer rd_index;
    integer rs_index;

    hazard_detection dut (
        .id_rs1(id_rs1),
        .id_rs2(id_rs2),
        .id_uses_rs1(id_uses_rs1),
        .id_uses_rs2(id_uses_rs2),
        .ex_valid(ex_valid),
        .ex_is_load(ex_is_load),
        .ex_writes_rd(ex_writes_rd),
        .ex_rd(ex_rd),
        .load_use_stall(load_use_stall)
    );

    task expect_stall;
        input expected;
        begin
            #1;
            checks = checks + 1;
            if ((load_use_stall !== 1'b0) && (load_use_stall !== 1'b1)) begin
                $display("FAIL check %0d: load_use_stall is X/Z", checks);
                $finish;
            end
            if (load_use_stall !== expected) begin
                $display("FAIL check %0d: expected stall=%b, got=%b", checks,
                         expected, load_use_stall);
                $finish;
            end
        end
    endtask

    initial begin
        #10000;
        $display("FAIL: timeout");
        $finish;
    end

    initial begin
        checks       = 0;
        id_rs1       = 5'd0;
        id_rs2       = 5'd0;
        id_uses_rs1  = 1'b0;
        id_uses_rs2  = 1'b0;
        ex_valid     = 1'b1;
        ex_is_load   = 1'b1;
        ex_writes_rd = 1'b1;
        ex_rd        = 5'd1;

        // Either actually-used source may trigger the hazard.
        id_uses_rs1 = 1'b1;
        id_rs1 = 5'd1;
        expect_stall(1'b1);
        id_uses_rs1 = 1'b0;
        id_uses_rs2 = 1'b1;
        id_rs2 = 5'd1;
        expect_stall(1'b1);

        // Matching source fields that the decoder marks unused must not stall.
        id_uses_rs1 = 1'b0;
        id_uses_rs2 = 1'b0;
        id_rs1 = 5'd1;
        id_rs2 = 5'd1;
        expect_stall(1'b0);

        // x0 is never a dependency, even if both source fields name x0.
        id_uses_rs1 = 1'b1;
        id_uses_rs2 = 1'b1;
        id_rs1 = 5'd0;
        id_rs2 = 5'd0;
        ex_rd = 5'd0;
        expect_stall(1'b0);

        // The producer must be a valid load that architecturally writes rd.
        ex_rd = 5'd7;
        id_rs1 = 5'd7;
        id_rs2 = 5'd7;
        ex_valid = 1'b0;
        expect_stall(1'b0);
        ex_valid = 1'b1;
        ex_is_load = 1'b0;
        expect_stall(1'b0);
        ex_is_load = 1'b1;
        ex_writes_rd = 1'b0;
        expect_stall(1'b0);

        // Both sources matching still produce one asserted stall result.
        ex_writes_rd = 1'b1;
        expect_stall(1'b1);

        // Exhaustively cover all architectural rd/rs1 pairs.
        id_uses_rs1 = 1'b1;
        id_uses_rs2 = 1'b0;
        id_rs2 = 5'd0;
        for (rd_index = 0; rd_index < 32; rd_index = rd_index + 1) begin
            ex_rd = rd_index[4:0];
            for (rs_index = 0; rs_index < 32; rs_index = rs_index + 1) begin
                id_rs1 = rs_index[4:0];
                expect_stall((rd_index != 0) && (rs_index == rd_index));
            end
        end

        // Repeat exhaustively for rs2 with rs1 disabled.
        id_uses_rs1 = 1'b0;
        id_uses_rs2 = 1'b1;
        id_rs1 = 5'd0;
        for (rd_index = 0; rd_index < 32; rd_index = rd_index + 1) begin
            ex_rd = rd_index[4:0];
            for (rs_index = 0; rs_index < 32; rs_index = rs_index + 1) begin
                id_rs2 = rs_index[4:0];
                expect_stall((rd_index != 0) && (rs_index == rd_index));
            end
        end

        $display("PASS: hazard_detection %0d checks", checks);
        $finish;
    end
endmodule
