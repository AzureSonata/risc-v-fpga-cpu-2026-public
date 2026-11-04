`timescale 1ns/1ps

module regfile (
    input  wire        clk,
    input  wire        rst,

    input  wire [4:0]  rs1_addr,
    output wire [31:0] rs1_data,
    input  wire [4:0]  rs2_addr,
    output wire [31:0] rs2_data,

    input  wire        wb_valid,
    input  wire        wb_we,
    input  wire [4:0]  wb_rd,
    input  wire [31:0] wb_wdata
);

    reg [31:0] regs [0:31];
    integer i;

    wire wb_write = wb_valid && wb_we && (wb_rd != 5'd0);

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'b0;
        end else if (wb_write) begin
            regs[wb_rd] <= wb_wdata;
        end
    end

    // x0 has priority over bypass so it can never expose a non-zero value.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 :
                      ((wb_write && (wb_rd == rs1_addr)) ? wb_wdata :
                       regs[rs1_addr]);
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 :
                      ((wb_write && (wb_rd == rs2_addr)) ? wb_wdata :
                       regs[rs2_addr]);

endmodule
