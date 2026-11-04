`timescale 1ns/1ps

module tb_regfile;
    reg         clk;
    reg         rst;
    reg  [4:0]  rs1_addr;
    wire [31:0] rs1_data;
    reg  [4:0]  rs2_addr;
    wire [31:0] rs2_data;
    reg         wb_valid;
    reg         wb_we;
    reg  [4:0]  wb_rd;
    reg  [31:0] wb_wdata;
    integer     checks;
    integer     idx;
    reg [31:0]  pattern;

    regfile dut (
        .clk(clk), .rst(rst),
        .rs1_addr(rs1_addr), .rs1_data(rs1_data),
        .rs2_addr(rs2_addr), .rs2_data(rs2_data),
        .wb_valid(wb_valid), .wb_we(wb_we),
        .wb_rd(wb_rd), .wb_wdata(wb_wdata)
    );

    always #5 clk = ~clk;

    task expect_reads;
        input [31:0] expected_rs1;
        input [31:0] expected_rs2;
        input [255:0] label;
        begin
            #1;
            checks = checks + 1;
            if ((rs1_data !== expected_rs1) || (rs2_data !== expected_rs2)) begin
                $display("FAIL %0s: rs1=%08x expected=%08x rs2=%08x expected=%08x",
                         label, rs1_data, expected_rs1, rs2_data, expected_rs2);
                $fatal(1);
            end
        end
    endtask

    task drive_write;
        input        valid;
        input        we;
        input [4:0]  rd;
        input [31:0] data;
        begin
            @(negedge clk);
            wb_valid = valid;
            wb_we = we;
            wb_rd = rd;
            wb_wdata = data;
        end
    endtask

    initial begin
        #2000;
        $display("FAIL timeout");
        $fatal(1);
    end

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        rs1_addr = 5'd0;
        rs2_addr = 5'd31;
        wb_valid = 1'b0;
        wb_we = 1'b0;
        wb_rd = 5'd0;
        wb_wdata = 32'b0;
        checks = 0;

        // Synchronous reset clears every architectural register.
        repeat (2) @(posedge clk);
        #1;
        rst = 1'b0;
        rs1_addr = 5'd1;
        rs2_addr = 5'd31;
        expect_reads(32'b0, 32'b0, "reset clears registers");

        // A normal write becomes visible after the active clock edge.
        drive_write(1'b1, 1'b1, 5'd5, 32'h1234_5678);
        @(posedge clk);
        #1;
        wb_valid = 1'b0;
        rs1_addr = 5'd5;
        rs2_addr = 5'd0;
        expect_reads(32'h1234_5678, 32'b0, "normal write and x0 read");

        // Writes to x0 are ignored even while the bypass inputs are active.
        drive_write(1'b1, 1'b1, 5'd0, 32'hffff_ffff);
        rs1_addr = 5'd0;
        rs2_addr = 5'd0;
        expect_reads(32'b0, 32'b0, "x0 bypass suppressed");
        @(posedge clk);
        expect_reads(32'b0, 32'b0, "x0 write suppressed");

        // Both read ports independently bypass the same in-flight WB value.
        drive_write(1'b1, 1'b1, 5'd7, 32'hdead_beef);
        rs1_addr = 5'd7;
        rs2_addr = 5'd7;
        expect_reads(32'hdead_beef, 32'hdead_beef, "dual-port WB bypass");
        @(posedge clk);
        #1;
        wb_valid = 1'b0;

        // Invalid and write-disabled WB inputs must not bypass or update state.
        drive_write(1'b0, 1'b1, 5'd7, 32'haaaa_aaaa);
        rs1_addr = 5'd7;
        rs2_addr = 5'd5;
        expect_reads(32'hdead_beef, 32'h1234_5678, "wb_valid gates bypass");
        @(posedge clk);
        drive_write(1'b1, 1'b0, 5'd5, 32'hbbbb_bbbb);
        expect_reads(32'hdead_beef, 32'h1234_5678, "wb_we gates bypass");
        @(posedge clk);

        // Consecutive writes overwrite the same destination without a bubble.
        drive_write(1'b1, 1'b1, 5'd9, 32'h0000_0001);
        rs1_addr = 5'd9;
        rs2_addr = 5'd7;
        expect_reads(32'h0000_0001, 32'hdead_beef, "first consecutive bypass");
        @(posedge clk);
        drive_write(1'b1, 1'b1, 5'd9, 32'h0000_0002);
        expect_reads(32'h0000_0002, 32'hdead_beef, "second consecutive bypass");
        @(posedge clk);
        drive_write(1'b1, 1'b1, 5'd10, 32'hcafe_f00d);
        rs1_addr = 5'd9;
        rs2_addr = 5'd10;
        expect_reads(32'h0000_0002, 32'hcafe_f00d, "independent dual reads");
        @(posedge clk);
        #1;
        wb_valid = 1'b0;
        expect_reads(32'h0000_0002, 32'hcafe_f00d, "committed consecutive writes");

        // Deterministic sweep across every non-zero architectural register.
        for (idx = 1; idx < 32; idx = idx + 1) begin
            pattern = 32'h5a00_0000 ^ (idx * 32'h0101_1021);
            drive_write(1'b1, 1'b1, idx[4:0], pattern);
            rs1_addr = idx[4:0];
            rs2_addr = (idx == 1) ? 5'd0 : (idx - 1);
            expect_reads(pattern,
                         (idx == 1) ? 32'b0 :
                                      (32'h5a00_0000 ^ ((idx-1) * 32'h0101_1021)),
                         "sweep write-through and neighbor read");
            @(posedge clk); #1;
        end
        wb_valid = 1'b0;
        for (idx = 1; idx < 32; idx = idx + 2) begin
            rs1_addr = idx[4:0];
            rs2_addr = (idx == 31) ? 5'd0 : (idx + 1);
            expect_reads(32'h5a00_0000 ^ (idx * 32'h0101_1021),
                         (idx == 31) ? 32'b0 :
                         (32'h5a00_0000 ^ ((idx+1) * 32'h0101_1021)),
                         "sweep committed dual read");
        end
        rs1_addr = 5'd0; rs2_addr = 5'd0;
        expect_reads(32'b0, 32'b0, "x0 remains zero after full sweep");

        $display("PASS tb_regfile: %0d checks", checks);
        $finish;
    end
endmodule
