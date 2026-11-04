`timescale 1ns/1ps

module tb_pangu100proplus_top;
    reg clk = 1'b0;
    reg rstn = 1'b0;
    wire [7:0] led;
    integer seen = 0;
    always #18.5185 clk = ~clk;

    pangu100proplus_top dut (.clk(clk), .rstn(rstn), .led(led));

    always @(negedge clk) begin
        if (rstn && dut.trace_valid && seen < 10) begin
            case (seen)
                0: if (dut.trace_pc !== 32'h00 || dut.trace_rd !== 1 || dut.trace_rd_data !== 1 || !dut.trace_rd_we) $fatal(1, "retire 0 mismatch");
                1: if (dut.trace_pc !== 32'h04 || dut.trace_rd_we) $fatal(1, "branch retire mismatch");
                2: if (dut.trace_pc !== 32'h0c || dut.trace_rd !== 2 || dut.trace_rd_data !== 2 || !dut.trace_rd_we) $fatal(1, "branch target mismatch");
                3: if (dut.trace_pc !== 32'h10 || dut.trace_rd !== 3 || dut.trace_rd_data !== 3 || !dut.trace_rd_we) $fatal(1, "add mismatch");
                4: if (dut.trace_pc !== 32'h14 || dut.trace_rd !== 4 || dut.trace_rd_data !== 7 || !dut.trace_rd_we) $fatal(1, "first load mismatch");
                5: if (dut.trace_pc !== 32'h18 || dut.trace_rd !== 5 || dut.trace_rd_data !== 8 || !dut.trace_rd_we) $fatal(1, "first load-use mismatch");
                6: if (dut.trace_pc !== 32'h1c || dut.trace_rd_we) $fatal(1, "store mismatch");
                7: if (dut.trace_pc !== 32'h20 || dut.trace_rd !== 6 || dut.trace_rd_data !== 8 || !dut.trace_rd_we) $fatal(1, "load-after-store mismatch");
                8: if (dut.trace_pc !== 32'h24 || dut.trace_rd !== 7 || dut.trace_rd_data !== 9 || !dut.trace_rd_we) $fatal(1, "second load-use mismatch");
                9: if (dut.trace_pc !== 32'h28 || dut.trace_rd !== 0 || dut.trace_rd_we) $fatal(1, "x0 mismatch");
                default: $fatal(1, "unexpected retirement pc=%h", dut.trace_pc);
            endcase
            if (dut.trace_order !== seen) $fatal(1, "trace order mismatch");
            $display("RETIRE %0d pc=%08h rd=x%0d data=%08h we=%b", dut.trace_order, dut.trace_pc, dut.trace_rd, dut.trace_rd_data, dut.trace_rd_we);
            seen = seen + 1;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rstn = 1'b1;
        repeat (800) @(posedge clk);
        if (seen < 10) $fatal(1, "expected at least 10 retirements, got %0d", seen);
        if (dut.u_cpu.u_regfile.regs[0] !== 32'b0 ||
            dut.u_cpu.u_regfile.regs[1] !== 32'd1 ||
            dut.u_cpu.u_regfile.regs[2] !== 32'd2 ||
            dut.u_cpu.u_regfile.regs[3] !== 32'd3 ||
            dut.u_cpu.u_regfile.regs[4] !== 32'd7 ||
            dut.u_cpu.u_regfile.regs[5] !== 32'd8 ||
            dut.u_cpu.u_regfile.regs[6] !== 32'd8 ||
            dut.u_cpu.u_regfile.regs[7] !== 32'd9)
            $fatal(1, "architectural register state mismatch");
        if (dut.dmem[1] !== 32'd8) $fatal(1, "data RAM store mismatch");
        if (led !== 8'd9) $fatal(1, "LED result mismatch: %h", led);
        $display("PASS tb_pangu100proplus_top: integrated board top retired program; x1=1 x2=2 x3=3 x0=0 LED=9");
        $finish;
    end
endmodule
