`timescale 1ns/1ps

module tb_forwarding_unit;
    reg [4:0] ex_rs1 = 0;
    reg [4:0] ex_rs2 = 0;
    reg ex_uses_rs1 = 0;
    reg ex_uses_rs2 = 0;
    reg ex_mem_valid = 0;
    reg ex_mem_writes_rd = 0;
    reg [4:0] ex_mem_rd = 0;
    reg mem_wb_valid = 0;
    reg mem_wb_writes_rd = 0;
    reg [4:0] mem_wb_rd = 0;

    wire [1:0] forward_rs1;
    wire [1:0] forward_rs2;
    integer checks = 0;
    integer rs;

    forwarding_unit dut (.*);

    task check_select;
        input [1:0] expected_rs1;
        input [1:0] expected_rs2;
        input [8*72-1:0] label;
        begin
            #1;
            checks = checks + 1;
            if ((forward_rs1 !== expected_rs1) ||
                (forward_rs2 !== expected_rs2)) begin
                $display("FAIL check %0d: %0s (rs1=%b expected=%b, rs2=%b expected=%b)",
                         checks, label, forward_rs1, expected_rs1,
                         forward_rs2, expected_rs2);
                $fatal(1);
            end
            if ((^forward_rs1 === 1'bx) || (^forward_rs2 === 1'bx)) begin
                $display("FAIL check %0d: unknown output: %0s", checks, label);
                $fatal(1);
            end
        end
    endtask

    task clear_inputs;
        begin
            ex_rs1 = 0;
            ex_rs2 = 0;
            ex_uses_rs1 = 0;
            ex_uses_rs2 = 0;
            ex_mem_valid = 0;
            ex_mem_writes_rd = 0;
            ex_mem_rd = 0;
            mem_wb_valid = 0;
            mem_wb_writes_rd = 0;
            mem_wb_rd = 0;
        end
    endtask

    initial begin
        #10000;
        $display("FAIL timeout");
        $fatal(1);
    end

    initial begin
        // Force an input transition before the first assertion.  This keeps
        // the testbench deterministic on simulators that initialize the test
        // inputs before scheduling an always @* block at time zero.
        ex_uses_rs1 = 1'b1;
        #1;
        clear_inputs();
        check_select(2'b00, 2'b00, "no producers and unused operands");

        ex_uses_rs1 = 1;
        ex_rs1 = 5'd7;
        mem_wb_valid = 1;
        mem_wb_writes_rd = 1;
        mem_wb_rd = 5'd7;
        check_select(2'b01, 2'b00, "rs1 forwards from MEM/WB");

        ex_mem_valid = 1;
        ex_mem_writes_rd = 1;
        ex_mem_rd = 5'd7;
        check_select(2'b10, 2'b00, "EX/MEM wins when both stages write rs1");

        ex_uses_rs2 = 1;
        ex_rs2 = 5'd9;
        ex_mem_rd = 5'd9;
        mem_wb_rd = 5'd7;
        check_select(2'b01, 2'b10, "two operands select different producer stages");

        ex_mem_rd = 5'd11;
        mem_wb_rd = 5'd11;
        ex_rs1 = 5'd11;
        ex_rs2 = 5'd11;
        check_select(2'b10, 2'b10, "both operands prefer newest matching writer");

        ex_uses_rs1 = 0;
        check_select(2'b00, 2'b10, "unused rs1 never forwards");
        ex_uses_rs1 = 1;
        ex_uses_rs2 = 0;
        check_select(2'b10, 2'b00, "unused rs2 never forwards");

        ex_uses_rs2 = 1;
        ex_rs1 = 0;
        ex_rs2 = 0;
        ex_mem_rd = 0;
        mem_wb_rd = 0;
        check_select(2'b00, 2'b00, "x0 consumers and producers never forward");

        ex_rs1 = 5'd4;
        ex_rs2 = 5'd4;
        ex_mem_rd = 5'd4;
        mem_wb_rd = 5'd4;
        ex_mem_valid = 0;
        check_select(2'b01, 2'b01, "invalid EX/MEM writer is ignored");
        ex_mem_valid = 1;
        ex_mem_writes_rd = 0;
        check_select(2'b01, 2'b01, "EX/MEM without write intent is ignored");
        ex_mem_valid = 0;
        mem_wb_valid = 0;
        check_select(2'b00, 2'b00, "invalid writers are both ignored");
        mem_wb_valid = 1;
        mem_wb_writes_rd = 0;
        check_select(2'b00, 2'b00, "MEM/WB without write intent is ignored");

        // Sweep all architectural registers to catch truncation/comparison
        // mistakes.  x0 must never forward; x1..x31 must forward from each
        // stage, with EX/MEM taking priority when both match.
        ex_uses_rs1 = 1;
        ex_uses_rs2 = 1;
        ex_mem_writes_rd = 1;
        mem_wb_writes_rd = 1;
        for (rs = 0; rs < 32; rs = rs + 1) begin
            ex_rs1 = rs[4:0];
            ex_rs2 = rs[4:0];
            ex_mem_rd = rs[4:0];
            mem_wb_rd = rs[4:0];

            ex_mem_valid = 1;
            mem_wb_valid = 0;
            if (rs == 0)
                check_select(2'b00, 2'b00, "register sweep EX/MEM x0");
            else
                check_select(2'b10, 2'b10, "register sweep EX/MEM");

            ex_mem_valid = 0;
            mem_wb_valid = 1;
            if (rs == 0)
                check_select(2'b00, 2'b00, "register sweep MEM/WB x0");
            else
                check_select(2'b01, 2'b01, "register sweep MEM/WB");

            ex_mem_valid = 1;
            mem_wb_valid = 1;
            if (rs == 0)
                check_select(2'b00, 2'b00, "register sweep priority x0");
            else
                check_select(2'b10, 2'b10, "register sweep EX/MEM priority");
        end

        // Exhaustively exercise all valid/write-enable combinations.  This
        // also checks that every fully known input vector produces no X bits.
        ex_rs1 = 5'd3;
        ex_rs2 = 5'd5;
        ex_mem_rd = 5'd3;
        mem_wb_rd = 5'd5;
        for (integer controls = 0; controls < 64; controls = controls + 1) begin
            ex_uses_rs1 = controls[5];
            ex_uses_rs2 = controls[4];
            ex_mem_valid = controls[3];
            ex_mem_writes_rd = controls[2];
            mem_wb_valid = controls[1];
            mem_wb_writes_rd = controls[0];
            check_select((controls[5] && controls[3] && controls[2]) ? 2'b10 : 2'b00,
                         (controls[4] && controls[1] && controls[0]) ? 2'b01 : 2'b00,
                         "control combination and known outputs");
        end

        $display("PASS tb_forwarding_unit (%0d checks)", checks);
        $finish;
    end
endmodule
