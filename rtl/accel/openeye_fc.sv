// =============================================================================
//  openeye_fc.sv  —  Fully Connected（TFLite version 4，weights_format=0）
//
//  对齐 tools/kws/compile_openeye.py 的 FC 路径：
//      acc[o] = bias_hw[o] + Σ_k in[k] * w[o][k]      // w 为 output-major（未转置）
//      out[o] = requant(acc[o], mult[o], shift[o], out_zp)
//
//  本模型：in = 4000 (25*20*8)，out = 4 ⇒ 16,000 次乘加。
//  最坏 |acc| 见 layers.json：FC signed_bits = 25 ⇒ 32 位累加器足够（但仍做溢出检测）。
//
//  ---- 2026-10-21 变更（K4-GAP-F8 / K4-GAP-03）----
//  1) 存储读口改为「1 拍延迟」语义：地址组合给出、数据寄存一拍后参与 MAC。
//     每个 logit = 2(取数) + nin(MAC) + 1(EMIT) 拍 ⇒ 本模型 4 x 4003 = **16,012 拍**
//     （组合读版本是 16,004）。
//  2) 累加溢出检测：33 位中间量，超 int32 即置 layer_err，停层且不产出结果。
//  3) bias 折入点从「k==0 那一拍」改为「第 1 个 MAC 那一拍（t==2）」，
//     与取数流水对齐；bias 在整段 (nin+3) 拍内稳定，同步读安全。
// =============================================================================
`default_nettype none

module openeye_fc (
    input  wire                clk,
    input  wire                rst,

    input  wire                start,
    input  wire [15:0]         nin,        // K
    input  wire [15:0]         nout,

    output logic [15:0]        in_idx,
    input  wire signed [7:0]   in_q,

    output logic [31:0]        w_idx,
    input  wire signed [7:0]   w_q,

    output logic [15:0]        bias_idx,
    input  wire signed [31:0]  bias_q,

    output logic               acc_valid,
    output logic [15:0]        acc_o,
    output logic signed [31:0] acc_q,
    output logic               layer_done,
    // 1 = 本层因累加溢出（ARITH）中止：layer_done 仍出一次，但不含结果
    output logic               layer_err
);
    localparam [2:0] S_IDLE = 3'd0,
                     S_FILL = 3'd1,   // 2 拍取数
                     S_MAC  = 3'd2,   // 每拍一次 MAC（用上一拍锁存的数据）
                     S_EMIT = 3'd3,
                     S_DONE = 3'd4;

    reg [2:0]  st;
    reg [15:0] o;
    reg [16:0] t;                 // 0..nin+1

    reg signed [31:0] acc;
    reg signed [7:0]  in_q_r, w_q_r;

    wire signed [32:0] prod33 = $signed({{25{in_q_r[7]}}, in_q_r})
                              * $signed({{25{w_q_r[7]}},  w_q_r});
    // 第一个 MAC（t==2）把 bias 折入，且只折一次
    wire signed [32:0] bias_term = (t == 17'd2) ? $signed({{1{bias_q[31]}}, bias_q}) : 33'sd0;
    wire signed [32:0] sum33 = $signed({{1{acc[31]}}, acc}) + prod33 + bias_term;
    wire               ovf   = (sum33[32] != sum33[31]);

    always @(*) begin
        in_idx   = t[15:0];
        w_idx    = o * nin + t[15:0];      // 32 位：o*nin + k（output-major 展平）
        bias_idx = o;
    end

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            o <= '0; t <= 17'd0;
            acc <= 32'sd0;
            in_q_r <= 8'sd0; w_q_r <= 8'sd0;
            acc_valid <= 1'b0; acc_o <= '0; acc_q <= 32'sd0;
            layer_done <= 1'b0;
            layer_err  <= 1'b0;
        end else begin
            acc_valid  <= 1'b0;
            layer_done <= 1'b0;
            layer_err  <= 1'b0;
            in_q_r <= in_q;
            w_q_r  <= w_q;
            case (st)
            S_IDLE: begin
                if (start) begin
                    o <= '0; t <= 17'd0; acc <= 32'sd0;
                    st <= S_FILL;
                end
            end
            S_FILL: begin
                if (t == 17'd1) begin
                    t  <= 17'd2;
                    st <= S_MAC;
                end else begin
                    t <= 17'd1;
                end
            end
            S_MAC: begin
                if (ovf) begin
                    layer_done <= 1'b1;
                    layer_err  <= 1'b1;
                    st         <= S_IDLE;
                end else begin
                    acc <= sum33[31:0];
                    if (t == {1'b0, nin} + 17'd1) begin
                        st <= S_EMIT;              // 已消耗最后一个输入
                    end else begin
                        t <= t + 17'd1;
                    end
                end
            end
            S_EMIT: begin
                acc_q     <= acc;
                acc_valid <= 1'b1;
                acc_o     <= o;
                if (o == nout - 16'd1) begin
                    st <= S_DONE;
                end else begin
                    o  <= o + 16'd1;
                    t  <= 17'd0;
                    acc<= 32'sd0;
                    st <= S_FILL;
                end
            end
            S_DONE: begin
                layer_done <= 1'b1;
                st         <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
