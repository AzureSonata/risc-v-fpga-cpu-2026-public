// ============================================================================
//        GPIO 控制器
//        地址图（TECHNICAL_BASELINE.md 第 43 行，冻结）：
//          0x1000_0010  输出   读写；按 wstrb 做字节使能更新
//          0x1000_0014  输入   只读（写 → error）
//          强制 bypass（不得缓存）
//
//        总线接口形状遵循 TECHNICAL_BASELINE.md 第 36 行冻结契约。
//
//        设计说明
//        - 本模块保持 32 位纯输出/纯输入两寄存器，**严格按冻结地址图**实现，
//          不擅自增加方向寄存器（地址图未定义；如需方向控制须走接口变更流程）。
//        - 板级方向由顶层按「输出位恒驱动、输入位恒高阻读」处理，
//          对外提供 gpio_out（含使能语义由顶层决定）与 gpio_in 两组线。
//        - 对应板卡 demo：`2_7_key_led_test`（KEY 作输入、LED 作输出）。
// ============================================================================

`include "defines.sv"

module gpio (
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

    // ---------------- 物理 GPIO ----------------
    output reg  [31:0] gpio_out,
    input  wire [31:0] gpio_in
);

    localparam OFF_OUT = 2'b00;   // 0x1000_0010
    localparam OFF_IN  = 2'b01;   // 0x1000_0014

    reg [31:0] rdata_q;
    reg        rsp_valid_q;
    reg        error_q;

    wire [1:0] off = addr[3:2];

    assign req_ready = !rsp_valid_q;
    assign rsp_valid = rsp_valid_q;
    assign rdata     = rdata_q;
    assign error     = error_q;

    // 字节使能展开：wstrb[i] 选择 wdata 的第 i 个字节
    wire [31:0] wmask = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};

    integer i;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            gpio_out    <= 32'h0;
            rdata_q     <= 32'h0;
            rsp_valid_q <= 1'b0;
            error_q     <= 1'b0;
        end else begin
            if (rsp_valid_q && rsp_ready) rsp_valid_q <= 1'b0;

            if (req_valid && req_ready) begin
                rsp_valid_q <= 1'b1;
                error_q     <= 1'b0;
                rdata_q     <= 32'h0;
                case (off)
                    OFF_OUT: begin
                        if (write) begin
                            gpio_out <= (gpio_out & ~wmask) | (wdata & wmask);
                        end else begin
                            rdata_q <= gpio_out;
                        end
                    end
                    OFF_IN: begin
                        if (write) begin
                            error_q <= 1'b1;      // 输入寄存器只读
                        end else begin
                            rdata_q <= gpio_in;
                        end
                    end
                    default: error_q <= 1'b1;
                endcase
            end
        end
    end

endmodule
