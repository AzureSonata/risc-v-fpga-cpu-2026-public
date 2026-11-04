`timescale 1ns/1ps

module tb_pangu100proplus_dual_accel_mmio;
    reg clk = 1'b0;
    reg rstn = 1'b0;
    always #5 clk = ~clk;

    wire [7:0] led;
    wire [31:0] gpio_out;
    wire uart_tx;
    wire trace0_valid, trace1_valid, trace0_trap;
    wire [63:0] trace0_order, trace1_order;
    wire [31:0] trace0_pc, trace0_instr, trace0_rd_data, trace0_cause;
    wire [31:0] trace1_pc, trace1_instr, trace1_rd_data, trace1_cause;
    wire [4:0] trace0_rd, trace1_rd;
    wire trace0_rd_we, trace1_rd_we, trace1_trap;
    wire [31:0] pc_debug;

    wire accel_req_valid, accel_req_ready, accel_write;
    wire [31:0] accel_addr, accel_wdata;
    wire [3:0] accel_wstrb;
    reg accel_rsp_valid = 1'b0;
    wire accel_rsp_ready;
    reg [31:0] accel_rdata = 32'b0;
    reg accel_error = 1'b0;
    reg accel_irq = 1'b0;

    reg rsp_pending = 1'b0;
    reg [31:0] rsp_data_q = 32'b0;
    reg [31:0] accel_ctrl = 32'b0;
    reg [31:0] accel_buf = 32'b0;
    integer ctrl_writes = 0, ctrl_reads = 0, buf_writes = 0, buf_reads = 0;
    integer ctrl_read_retired = 0, buf_read_retired = 0, irq_traps = 0;
    integer fail = 0;

    assign accel_req_ready = !rsp_pending;

    always @(posedge clk) begin
        if (!rstn) begin
            rsp_pending <= 1'b0;
            accel_rsp_valid <= 1'b0;
            accel_irq <= 1'b0;
        end else begin
            if (accel_rsp_valid && accel_rsp_ready) begin
                accel_rsp_valid <= 1'b0;
                rsp_pending <= 1'b0;
                if (buf_reads != 0) accel_irq <= 1'b1;
            end
            if (accel_req_valid && accel_req_ready) begin
                rsp_pending <= 1'b1;
                accel_rsp_valid <= 1'b1;
                accel_error <= 1'b0;
                if (accel_write) begin
                    if (accel_addr == 32'h4000_0000) begin
                        accel_ctrl <= accel_wdata;
                        ctrl_writes <= ctrl_writes + 1;
                        rsp_data_q <= 32'b0;
                    end else if (accel_addr == 32'h4000_1000) begin
                        accel_buf <= accel_wdata;
                        buf_writes <= buf_writes + 1;
                        rsp_data_q <= 32'b0;
                    end else begin
                        accel_error <= 1'b1;
                        rsp_data_q <= 32'b0;
                    end
                end else if (accel_addr == 32'h4000_0000) begin
                    ctrl_reads <= ctrl_reads + 1;
                    rsp_data_q <= accel_ctrl;
                end else if (accel_addr == 32'h4000_1000) begin
                    buf_reads <= buf_reads + 1;
                    rsp_data_q <= accel_buf;
                end else begin
                    accel_error <= 1'b1;
                    rsp_data_q <= 32'b0;
                end
            end
            if (trace0_valid && trace0_trap && trace0_cause == 32'h8000_000b) begin
                irq_traps <= irq_traps + 1;
                accel_irq <= 1'b0;
            end
            if (trace0_valid && trace0_pc == 32'h0000_0024 &&
                trace0_rd == 5'd3 && trace0_rd_we && trace0_rd_data == 32'h55)
                ctrl_read_retired <= ctrl_read_retired + 1;
            if (trace0_valid && trace0_pc == 32'h0000_0034 &&
                trace0_rd == 5'd6 && trace0_rd_we && trace0_rd_data == 32'h33)
                buf_read_retired <= buf_read_retired + 1;
        end
    end

    always @* accel_rdata = rsp_data_q;

    pangu100proplus_dual_full_top #(
        .ROM_INIT_FILE("verification/unit/dual_full_soc.hex"),
        .MEM_DEPTH(256), .MEM_AW(8), .UART_DIV(4),
        .ICACHE_ENABLE(1'b1), .DCACHE_ENABLE(1'b1),
        .ACCEL_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rstn(rstn), .gpio_in(32'b0), .uart_rx(1'b1),
        .accel_irq(accel_irq),
        .accel_req_valid(accel_req_valid), .accel_req_ready(accel_req_ready),
        .accel_addr(accel_addr), .accel_write(accel_write),
        .accel_wdata(accel_wdata), .accel_wstrb(accel_wstrb),
        .accel_rsp_valid(accel_rsp_valid), .accel_rsp_ready(accel_rsp_ready),
        .accel_rdata(accel_rdata), .accel_error(accel_error),
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
        .trace1_cause(trace1_cause), .pc_debug(pc_debug)
    );

    initial begin
        repeat (10) @(posedge clk);
        dut.u_mem.u_rom_i.mem[0] = 32'h1000_0513; // addi x10,x0,0x100
        dut.u_mem.u_rom_i.mem[1] = 32'h3055_1073; // csrw mtvec,x10
        dut.u_mem.u_rom_i.mem[2] = 32'h8000_0513; // addi x10,x0,0x800
        dut.u_mem.u_rom_i.mem[3] = 32'h3045_1073; // csrw mie,x10 (MEIE)
        dut.u_mem.u_rom_i.mem[4] = 32'h0080_0513; // addi x10,x0,8
        dut.u_mem.u_rom_i.mem[5] = 32'h3005_1073; // csrw mstatus,x10 (MIE)
        dut.u_mem.u_rom_i.mem[6] = 32'h4000_00b7; // lui x1,0x40000
        dut.u_mem.u_rom_i.mem[7] = 32'h0550_0113; // addi x2,x0,0x55
        dut.u_mem.u_rom_i.mem[8] = 32'h0020_a023; // sw x2,0(x1)
        dut.u_mem.u_rom_i.mem[9] = 32'h0000_a183; // lw x3,0(x1)
        dut.u_mem.u_rom_i.mem[10] = 32'h4000_1237; // lui x4,0x40001
        dut.u_mem.u_rom_i.mem[11] = 32'h0330_0293; // addi x5,x0,0x33
        dut.u_mem.u_rom_i.mem[12] = 32'h0052_2023; // sw x5,0(x4)
        dut.u_mem.u_rom_i.mem[13] = 32'h0002_2303; // lw x6,0(x4)
        dut.u_mem.u_rom_i.mem[14] = 32'h0000_006f; // jal x0,0
        dut.u_mem.u_rom_i.mem[64] = 32'h0010_0393; // handler: addi x7,x0,1
        dut.u_mem.u_rom_i.mem[65] = 32'h0000_006f; // jal x0,0
        rstn = 1'b1;
        repeat (20000) @(posedge clk);
        #1;

        if (ctrl_writes != 1 || ctrl_reads != 1 || buf_writes != 1 || buf_reads != 1)
            begin $display("FAIL accelerator transactions ctrl=%0d/%0d buf=%0d/%0d",
                           ctrl_writes, ctrl_reads, buf_writes, buf_reads); fail = fail + 1; end
        if (accel_ctrl !== 32'h55 || accel_buf !== 32'h33)
            begin $display("FAIL accelerator stores ctrl=%08x buf=%08x", accel_ctrl, accel_buf); fail = fail + 1; end
        if (ctrl_read_retired != 1 || buf_read_retired != 1)
            begin $display("FAIL CPU MMIO load retire ctrl=%0d buf=%0d", ctrl_read_retired, buf_read_retired); fail = fail + 1; end
        if (irq_traps != 1)
            begin $display("FAIL accelerator external IRQ traps=%0d", irq_traps); fail = fail + 1; end
        if (fail == 0)
            $display("ALL TESTS PASSED (pangu100proplus_dual_accel_mmio; DUAL_FIVE_STAGE)");
        else
            $display("ACCEL_MMIO_RESULT: FAIL failures=%0d", fail);
        $finish;
    end

    initial begin
        #300000;
        $display("ACCEL_MMIO_RESULT: TIMEOUT pc=%08x", pc_debug);
        $finish;
    end
endmodule
