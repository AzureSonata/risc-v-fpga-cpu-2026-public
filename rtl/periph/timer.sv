// ============================================================================
//        机器定时器（machine timer）
//        地址图（TECHNICAL_BASELINE.md 第 44 行，冻结）：
//          0x1000_0020  计数   读写（mtime）
//          0x1000_0024  比较   读写（mtimecmp）
//          强制 bypass；**产生 machine timer interrupt**
//
//        总线接口形状遵循 TECHNICAL_BASELINE.md 第 36 行冻结契约。
//
//        中断语义（TECHNICAL_BASELINE.md 第 55 行）
//        - 中断只在**指令边界**采样（由 CPU/CSR 侧负责），本模块只提供电平型请求。
//        - `timer_irq` 为**电平**输出：`mtime >= mtimecmp` 期间持续为高，
//          直到软件写入更大的 mtimecmp（或清零 mtime）才撤销。
//          电平语义保证中断不会被漏掉，符合 RISC-V mip.MTIP 的定义。
//        - 异常优先于同拍中断由 CSR 侧仲裁，本模块不参与。
//
//        位宽说明
//        - 冻结地址图每个寄存器为一个 32 位字，故本实现为 **32 位计数/比较**。
//          RISC-V 参考实现常用 64 位 mtime，但地址图未定义高 32 位字地址；
//          若需 64 位须走接口变更流程（新增地址），不得静默扩展。
// ============================================================================

`include "defines.sv"

module timer (
    input  wire        clk,
    input  wire        rst,

    // ---------------- 从设备（总线）侧 ----------------
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] addr,
    input  wire        write,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rdata,
    output wire        error,

    // ---------------- 中断 ----------------
    output wire        timer_irq
);

    localparam OFF_CNT = 2'b00;   // 0x1000_0020  mtime
    localparam OFF_CMP = 2'b01;   // 0x1000_0024  mtimecmp

    reg [31:0] mtime;
    reg [31:0] mtimecmp;

    reg [31:0] rdata_q;
    reg        rsp_valid_q;
    reg        error_q;

    wire [1:0]  off   = addr[3:2];
    wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};

    assign req_ready = !rsp_valid_q;
    assign rsp_valid = rsp_valid_q;
    assign rdata     = rdata_q;
    assign error     = error_q;

    // 电平型中断：计数值达到或超过比较值期间持续有效
    assign timer_irq = (mtime >= mtimecmp);

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            mtime       <= 32'h0;
            mtimecmp    <= 32'hFFFF_FFFF;   // 复位后不产生中断
            rdata_q     <= 32'h0;
            rsp_valid_q <= 1'b0;
            error_q     <= 1'b0;
        end else begin
            // 计数自由运行（每拍 +1）
            mtime <= mtime + 32'd1;

            if (rsp_valid_q && rsp_ready) rsp_valid_q <= 1'b0;

            if (req_valid && req_ready) begin
                rsp_valid_q <= 1'b1;
                error_q     <= 1'b0;
                rdata_q     <= 32'h0;
                case (off)
                    OFF_CNT: begin
                        if (write) mtime <= (mtime & ~wmask) | (wdata & wmask);
                        else       rdata_q <= mtime;
                    end
                    OFF_CMP: begin
                        if (write) mtimecmp <= (mtimecmp & ~wmask) | (wdata & wmask);
                        else       rdata_q  <= mtimecmp;
                    end
                    default: error_q <= 1'b1;
                endcase
            end
        end
    end

endmodule
