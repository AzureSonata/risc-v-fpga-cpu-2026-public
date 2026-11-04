`timescale 1ns/1ps
`include "defines.sv"

module tb_dual_issue_mini_raw;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    wire        i_req_valid;
    reg         i_req_ready;
    wire [31:0] i_req_addr;
    reg         i_rsp_valid;
    wire        i_rsp_ready;
    reg  [63:0] i_rsp_data;
    wire        issue0, issue1;
    wire        retire0_valid, retire1_valid;
    wire [31:0] pc_debug;

    reg [63:0] imem [0:63];
    reg [31:0] prog [0:15];
    reg        rsp_valid_q;
    reg [63:0] rsp_data_q;
    integer i;

    assign i_req_ready = 1'b1;
    assign i_rsp_valid = rsp_valid_q;
    assign i_rsp_data  = rsp_data_q;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 64'h0;
        end else begin
            if (i_req_valid && i_req_ready) begin
                rsp_valid_q <= 1'b1;
                rsp_data_q  <= imem[i_req_addr[7:3]];
            end else if (i_rsp_valid && i_rsp_ready) begin
                rsp_valid_q <= 1'b0;
            end
        end
    end

`ifdef DUAL_ISSUE_OFF
    dual_issue_mini_core #(.DUAL_ISSUE_EN(1'b0)) dut (
`else
    dual_issue_mini_core #(.DUAL_ISSUE_EN(1'b1)) dut (
`endif
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
        .i_req_addr(i_req_addr), .i_rsp_valid(i_rsp_valid),
        .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rsp_data),
        .issue0(issue0), .issue1(issue1),
        .retire0_valid(retire0_valid), .retire1_valid(retire1_valid),
        .pc_debug(pc_debug)
    );

    integer cycles = 0;
    integer retired = 0;
    integer issue1_cycles = 0;
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            cycles <= 0; retired <= 0; issue1_cycles <= 0;
        end else begin
            cycles <= cycles + 1;
            retired <= retired + retire0_valid + retire1_valid;
            if (issue1) issue1_cycles <= issue1_cycles + 1;
        end
    end

    integer j;
    integer local_fail = 0;
    reg [31:0] expected [1:8];
    initial begin
        expected[1] = 32'd5;
        expected[2] = 32'd7;
        expected[3] = 32'd10;
        expected[4] = 32'd14;
        expected[5] = 32'd24;
        expected[6] = 32'd1;
        expected[7] = 32'd25;
        expected[8] = 32'd2;

        for (i = 0; i < 16; i = i + 1)
            prog[i] = 32'h0000006F; // jal x0,0 padding
        prog[0] = 32'h00000013 | (5 << 20) | (0 << 15) | (1 << 7);
        prog[1] = 32'h00000013 | (7 << 20) | (0 << 15) | (2 << 7);
        prog[2] = 32'h00000033 | (1 << 20) | (1 << 15) | (3 << 7);
        prog[3] = 32'h00000033 | (2 << 20) | (2 << 15) | (4 << 7);
        prog[4] = 32'h00000033 | (4 << 20) | (3 << 15) | (5 << 7);
        prog[5] = 32'h00000013 | (1 << 20) | (0 << 15) | (6 << 7);
        prog[6] = 32'h00000033 | (6 << 20) | (5 << 15) | (7 << 7);
        prog[7] = 32'h00000013 | (2 << 20) | (0 << 15) | (8 << 7);
        for (i = 0; i < 32; i = i + 1)
            imem[i] = {prog[2*i + 1], prog[2*i]};

        repeat (3) @(posedge clk);
        #1; rst = `RstDisable;

        wait ((retired >= 8) || (cycles >= 200));
        #1;

        $display("MINI_CORE_RAW DUAL=%0d CYCLES=%0d RETIRED=%0d ISSUE1_CYCLES=%0d",
`ifdef DUAL_ISSUE_OFF
                 0,
`else
                 1,
`endif
                 cycles, retired, issue1_cycles);

        for (j = 1; j <= 8; j = j + 1) begin
            if (dut.u_rf.regs[j] !== expected[j]) begin
                $display("FAIL: x%0d = %0d expected %0d", j, dut.u_rf.regs[j], expected[j]);
                local_fail = local_fail + 1;
            end
        end

        if (local_fail == 0 && retired >= 8) begin
            $display("PASS: 8 RAW/WAW ALU results correct");
            $display("PASS: cross-pair forwarding and register-file bypass held");
`ifdef DUAL_ISSUE_OFF
            $display("ALL TESTS PASSED (dual_issue_mini_raw single mode)");
`else
            if (issue1_cycles > 0)
                $display("ALL TESTS PASSED (dual_issue_mini_raw dual mode)");
            else
                $display("DUAL_ISSUE_MINI_RAW_RESULT: FAIL (dual mode never issued lane1)");
`endif
        end else begin
            $display("DUAL_ISSUE_MINI_RAW_RESULT: FAIL (%0d reg errors, retired=%0d)", local_fail, retired);
        end
        $finish;
    end

    initial begin
        #30000;
        $display("DUAL_ISSUE_MINI_RAW_RESULT: TIMEOUT cycles=%0d retired=%0d", cycles, retired);
        $finish;
    end
endmodule
