`timescale 1ns/1ps

// Write-back side-effect gate.
//
// wb_valid describes the payload held in MEM/WB.  It may remain asserted for
// several cycles while the pipeline is held.  commit_fire must be a one-cycle
// consume pulse supplied by the integration top for that payload.  Gating the
// architectural write with commit_fire prevents a held payload from being
// written/committed repeatedly.
module wb_stage (
    input  wire        wb_valid,
    input  wire        commit_fire,
    input  wire        wb_writes_rd,
    input  wire [4:0]  wb_rd,
    input  wire [31:0] wb_data,
    input  wire        wb_trap,

    output wire        rd_we,
    output wire [4:0]  rd_addr,
    output wire [31:0] rd_data
);

    // NEGCTL：忽略 commit_fire ⇒ 保持中的 MEM/WB 载荷被**重复提交**（重复写寄存器）。
    // 预期被 tb_wb_trace 的 "multi-cycle hold does not repeat commit" 捕获。
    assign rd_we   = wb_valid && wb_writes_rd &&
                     (wb_rd != 5'd0) && !wb_trap;
    assign rd_addr = wb_rd;
    assign rd_data = wb_data;

endmodule
