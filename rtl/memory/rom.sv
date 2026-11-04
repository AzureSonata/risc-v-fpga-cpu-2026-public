// ============================================================================
//        启动 ROM（只读、不可缓存）
//
//        依据：docs/architecture/TECHNICAL_BASELINE.md §「接口和地址图」
//        「启动 ROM 0x0000_0000 起 —— 只读、不可缓存」
//
//        契约（与 CPU 单字 I/D 端口一致）：
//        - 握手发生在上升沿；valid && !ready 时载荷保持；
//        - 一次请求接受只对应一次响应（req_ready = !rsp_valid_q）；
//        - 同步读，接受后**下一拍**给出响应（可直接推断 BRAM）；
//        - 本模块**不实现写**：写请求由 mem_map_adapter 判为 error，不会到达这里。
//          若因接线错误真的收到 write，本模块忽略之（不产生副作用）并在
//          仿真中报出断言，避免静默写坏 ROM。
// ============================================================================

`include "defines.sv"

module rom #(
    parameter [31:0] BASE      = 32'h0000_0000,
    parameter integer DEPTH    = 16384,          // 字数（= ROM_SIZE/4），默认 64 KiB
    parameter integer AW       = 14,             // 字地址位宽 = log2(DEPTH)
    parameter [1023:0] INIT_FILE = 1024'd0       // 可选 $readmemh 初始化文件（0 = 不用）
)(
    input  wire         clk,
    input  wire         rst,

    input  wire         req_valid,
    output wire         req_ready,
    input  wire [31:0]  addr,
    input  wire         write,                   // 必须为 0；非 0 触发仿真断言
    input  wire [31:0]  wdata,
    input  wire [3:0]   wstrb,

    output reg          rsp_valid,
    input  wire         rsp_ready,
    output reg  [31:0]  rdata,
    output wire         error
);

    reg [31:0] mem [0:DEPTH-1];
    reg [31:0] rdata_q;

    wire accept = req_valid && req_ready;
    assign req_ready = ~rsp_valid;               // 单笔未完成
    assign error     = 1'b0;                     // 只读存储器自身不产生 error

    // 字地址：addr[1:0] 由 adapter 保证为 0；此处按 AW 位截取
    wire [AW-1:0] widx = addr[AW+1:2];

    integer i;
`ifdef COREMARK_PDS_INIT
    initial begin
        // ⚠️ 坑位：Yosys 0.66 把 procedural loop 写入覆盖在同块 $readmemh 之上 ⇒ 综合 ROM 全 NOP ⇒ PDS 分支只读完整 16K 字字面镜像（见 LESSON-001 / 日志 2026-10-12-100mhz-coremark依赖审计）。
        $readmemh("coremark.hex", mem);
    end
`else
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'h0000_0013;   // 默认全 NOP
        if (INIT_FILE != 1024'd0) $readmemh(INIT_FILE, mem);
    end
`endif

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            rsp_valid <= 1'b0;
            rdata     <= `ZeroWord;
            rdata_q   <= `ZeroWord;
        end else begin
            if (accept) begin
                rsp_valid <= 1'b1;
                rdata     <= mem[widx];
            end else if (rsp_valid && rsp_ready) begin
                rsp_valid <= 1'b0;
            end
        end
    end

`ifdef SIMULATION
    always @(posedge clk) begin
        if (!rst && accept && write)
            $display("ASSERT-FAIL rom: 收到写请求（ROM 只读，addr=%08h）", addr);
    end
`endif

endmodule
