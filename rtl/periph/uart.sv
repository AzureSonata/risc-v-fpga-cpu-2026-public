// ============================================================================
//        UART 控制器
//        地址图（TECHNICAL_BASELINE.md 第 42 行，冻结）：
//          0x1000_0000  数据   写 = 发送一字节；读 = 取接收到的字节
//          0x1000_0004  状态   只读
//             bit0 TX_READY  1 = 发送器空闲，可接受新字节
//             bit1 RX_VALID  1 = 接收缓冲有未读字节
//             bit2 RX_OVERRUN 1 = 上一字节尚未读走又收到新字节（读状态清除）
//          强制 bypass（不得缓存）
//
//        总线接口形状遵循 TECHNICAL_BASELINE.md 第 36 行的冻结契约：
//          req_valid/req_ready/addr/write/wdata/wstrb + rsp_valid/rsp_ready/rdata/error
//          握手在上升沿；valid && !ready 时载荷保持；一次接受对应一次响应；
//          error 不得产生成功写回。
//
//        实现要点
//        - 波特率由 DIV 参数直接给定时钟分频数（默认按 50 MHz / 115200 计算），
//          测试可用小 DIV 直接验证时序，无需等待真实波特率。
//        - 发送为「启动位 + 8 数据位（LSB 先）+ 停止位」，共 10 位。
//        - 接收用 16× 过采样中的中点采样策略：检测到起始位下降沿后，
//          在半位周期处确认，其后每整位周期在中点采样。
//        - 接收采用两级同步器，避免跨时钟域亚稳态（外部 uart_rx 为异步信号）。
// ============================================================================

`include "defines.sv"

module uart #(
    parameter integer DIV = 434        // 时钟分频数：50 MHz / 115200 ≈ 434
)(
    input  wire        clk,
    input  wire        rst,

    // ---------------- 从设备（总线）侧 ----------------
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] addr,           // 字节地址，低 2 位选择寄存器
    input  wire        write,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rdata,
    output wire        error,

    // ---------------- 物理串口 ----------------
    output wire        uart_tx,
    input  wire        uart_rx
);

    // ---- 寄存器偏移（相对外设基址，按当前事务地址取低 2 位）----
    localparam OFF_DATA = 2'b00;
    localparam OFF_STAT = 2'b01;

    // ---- 状态（只读寄存器）----
    reg        tx_ready;
    reg        rx_valid;
    reg        rx_overrun;

    reg [7:0]  rx_data;
    reg [31:0] rdata_q;
    reg        rsp_valid_q;
    reg        error_q;

    wire [1:0] off = addr[3:2];

    // ------------------------------------------------------------------
    // 总线事务：一次接受 → 一次响应
    // 仅当无在途响应时才接受新请求（单笔未完成，符合冻结契约）
    // ------------------------------------------------------------------
    assign req_ready  = !rsp_valid_q;

    assign rsp_valid  = rsp_valid_q;
    assign rdata      = rdata_q;
    assign error      = error_q;

    // ------------------------------------------------------------------
    // 发送器
    // ------------------------------------------------------------------
    reg [9:0]  tx_sr;          // 启动位 + 8 数据 + 停止位（LSB 先）
    reg [3:0]  tx_bit;         // 已发位数 0..9
    reg        tx_busy;
    reg [15:0] tx_cnt;
    reg        tx_line;

    // ------------------------------------------------------------------
    // 接收器（两级同步 + 中点采样）
    // ------------------------------------------------------------------
    reg        rx_sync0, rx_sync1;
    reg [1:0]  rx_state;       // 0=IDLE 1=START 2=DATA 3=STOP
    reg [15:0] rx_cnt;
    reg [2:0]  rx_bit;
    reg [7:0]  rx_shift;

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            tx_ready    <= 1'b1;
            tx_sr       <= 10'h3FF;
            tx_bit      <= 4'd0;
            tx_busy     <= 1'b0;
            tx_cnt      <= 16'd0;
            tx_line     <= 1'b1;
            rx_sync0    <= 1'b1;
            rx_sync1    <= 1'b1;
            rx_state    <= 2'd0;
            rx_cnt      <= 16'd0;
            rx_bit      <= 3'd0;
            rx_shift    <= 8'h00;
            rx_data     <= 8'h00;
            rx_valid    <= 1'b0;
            rx_overrun  <= 1'b0;
            rdata_q     <= 32'h0;
            rsp_valid_q <= 1'b0;
            error_q     <= 1'b0;
        end else begin
            // ---------- 接收同步与采样 ----------
            rx_sync0 <= uart_rx;
            rx_sync1 <= rx_sync0;

            case (rx_state)
                2'd0: begin   // IDLE：等待起始位下降沿
                    if (rx_sync1 == 1'b0) begin
                        rx_state <= 2'd1;
                        rx_cnt   <= DIV >> 1;      // 半位后确认起始位
                    end
                end
                2'd1: begin   // 半位处确认仍为低 → 真起始位
                    if (rx_cnt == 16'd0) begin
                        if (rx_sync1 == 1'b0) begin
                            rx_state <= 2'd2;
                            rx_cnt   <= DIV - 1;
                            rx_bit   <= 3'd0;
                        end else begin
                            rx_state <= 2'd0;      // 毛刺，放弃
                        end
                    end else begin
                        rx_cnt <= rx_cnt - 16'd1;
                    end
                end
                2'd2: begin   // 每位在中点采样
                    if (rx_cnt == 16'd0) begin
                        rx_shift <= {rx_sync1, rx_shift[7:1]};   // LSB 先
                        rx_cnt   <= DIV - 1;
                        if (rx_bit == 3'd7) begin
                            rx_state <= 2'd3;
                        end else begin
                            rx_bit <= rx_bit + 3'd1;
                        end
                    end else begin
                        rx_cnt <= rx_cnt - 16'd1;
                    end
                end
                default: begin  // STOP：等停止位结束
                    if (rx_cnt == 16'd0) begin
                        rx_state <= 2'd0;
                        if (rx_valid) rx_overrun <= 1'b1;   // 未读走即被覆盖
                        rx_data  <= rx_shift;
                        rx_valid <= 1'b1;
                    end else begin
                        rx_cnt <= rx_cnt - 16'd1;
                    end
                end
            endcase

            // ---------- 发送移位 ----------
            if (tx_busy) begin
                if (tx_cnt == 16'd0) begin
                    tx_line <= tx_sr[0];
                    tx_sr   <= {1'b1, tx_sr[9:1]};
                    tx_cnt  <= DIV - 1;
                    if (tx_bit == 4'd9) begin
                        tx_busy  <= 1'b0;
                        tx_ready <= 1'b1;
                        tx_line  <= 1'b1;      // 回到空闲高电平
                    end else begin
                        tx_bit <= tx_bit + 4'd1;
                    end
                end else begin
                    tx_cnt <= tx_cnt - 16'd1;
                end
            end

            // ---------- 总线事务处理 ----------
            if (rsp_valid_q && rsp_ready) rsp_valid_q <= 1'b0;

            if (req_valid && req_ready) begin
                rsp_valid_q <= 1'b1;
                error_q     <= 1'b0;
                rdata_q     <= 32'h0;
                case (off)
                    OFF_DATA: begin
                        if (write) begin
                            // 发送一字节；发送器忙时不接受（置 error，不得成功写回）
                            if (tx_ready) begin
                                tx_sr    <= {1'b1, wdata[7:0], 1'b0};  // 停止+数据+启动
                                tx_bit   <= 4'd0;
                                tx_cnt   <= DIV - 1;
                                tx_busy  <= 1'b1;
                                tx_ready <= 1'b0;
                            end else begin
                                error_q <= 1'b1;
                            end
                        end else begin
                            // 读数据：返回接收字节并清 RX_VALID
                            rdata_q  <= {24'h0, rx_data};
                            rx_valid <= 1'b0;
                        end
                    end
                    OFF_STAT: begin
                        if (write) begin
                            error_q <= 1'b1;            // 状态寄存器只读
                        end else begin
                            rdata_q <= {29'h0, rx_overrun, rx_valid, tx_ready};
                            // 读状态的同时清除 overrun（写 1 清除语义的简化）
                            if (rx_overrun) rx_overrun <= 1'b0;
                        end
                    end
                    default: begin
                        error_q <= 1'b1;               // 本外设未实现的偏移
                    end
                endcase
            end
        end
    end

    assign uart_tx = tx_line;

endmodule
