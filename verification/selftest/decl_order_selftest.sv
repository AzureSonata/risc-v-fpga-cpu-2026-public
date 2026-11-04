// check_decl_order.py 自检用例（§7.15/§7.19：**检查脚本自己**也要有鉴别力，且不得假阳性）
//
// 用法：
//   python scripts/check_decl_order.py --roots verification/selftest
// 期望：报**用例 A、B 及其同类**（真实前向引用），**不报**用例 C、D（假阳性对照）
// 期望退出码：1（因为本目录**故意**含有违规，用于自证门禁有鉴别力）
//
// ⚠️ 为什么这个文件必须在仓库里（而不是随手写在 build/）：`build/` 被 .gitignore 忽略，
//    写在里面别人拿不到 ⇒ "自检"这条纪律在别人机器上等于不存在。
module decl_order_selftest (
    input wire clk
);
    // ---- 用例 A：网上下文先用后声明（等价 csr_mtvec/csr_mepc）----
    wire [31:0] y = sel ? late_wire : 32'h0;      // late_wire 声明在下面 ⇒ 应报
    wire        sel = 1'b1;
    wire [31:0] late_wire;                        // 后置声明

    // ---- 用例 B：procedural 先用后声明（等价 xm_is_mret / btb_ready_cnt）----
    always @(posedge clk) begin
        q <= late_reg;                             // late_reg 声明在下面 ⇒ 应报
    end
    reg q;
    reg late_reg;

    // ---- 用例 C（假阳性对照）：具名端口连接的形式名 .foo(...) 不是本地信号 ----
    sub u_sub (.late_formal(y), .clk(clk));

    // ---- 用例 D（假阳性对照）：数字字面量不是标识符 ----
    wire [3:0] lit = 4'b1010;

    // ---- 用例 E（假阳性对照）：非 ANSI 模块头不得把例化端口列表当成"声明区" ----
    sub u_sub2 (
        .late_formal(lit[0]),
        .clk(clk)
    );

endmodule

module sub (input wire late_formal, input wire clk);
endmodule
