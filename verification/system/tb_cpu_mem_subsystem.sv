// ============================================================================
//  CPU + 存储子系统 接入测试
//
//  被测：cpu_core_stage1 + rtl/soc/cpu_mem_subsystem.sv（含 mem_map_adapter + ROM + SRAM）
//  目的：证明 CPU 能**通过真实地址图**取指与访存 —— 此前 adapter/ROM/SRAM 只做过
//        独立定向验证，从未与 CPU 连在一起跑过程序。
//
//  程序（ROM 0x0000_0000 起）：
//    0x00 addi x1,x0,1        x1 = 1
//    0x04 lui  x2,0x80000     x2 = 0x8000_0000（SRAM 基址）
//    0x08 addi x3,x0,42       x3 = 42
//    0x0c sw   x3,0(x2)       **经 adapter 写入 SRAM**
//    0x10 lw   x4,0(x2)       **经 adapter 从 SRAM 读回**
//    0x14 addi x5,x4,1        x5 = 43
//    0x18 lui  x6,0x10000     x6 = 0x1000_0000
//    0x1c addi x6,x6,0x10     x6 = 0x1000_0010（GPIO 输出）
//    0x20 addi x7,x0,0x55     x7 = 0x55
//    0x24 sw   x7,0(x6)       **MMIO 写 GPIO → 点灯**
//    0x28 lw   x8,0x10(x6)    **MMIO 读定时器计数 0x1000_0020**
//    0x2c lui  x6,0x10000     x6 = 0x1000_0000（UART 数据）
//    0x30 sw   x7,0(x6)       **MMIO 写 UART 数据寄存器 → 发送 0x55**
//    0x34 beq  x0,x0,0        停机死循环（程序结束；TB 在等待 UART 帧期间 CPU 停在此处）
//
//  断言：
//    T1  retire 序列精确 N_EXP 条（pc/rd/we/data 全字段）
//    T2  D 侧 SRAM 的字 0 被写入 42（证明 store 经 adapter 正确路由到 SRAM 而非 ROM）
//    T3  寄存器堆终值 x1=1、x2=0x8000_0000、x3=42、x4=42、x5=43、x0=0
//      （x4=42 证明"写后读"经同一份 SRAM 实例成立，即地址图与 adapter 数据通路正确）
//    T4  N_EXP 条之后不得再有"写寄存器"的 retire（程序末尾的自旋循环不写寄存器）
//    T5  I 侧取指不产生 error（由 trace 全字段正确间接保证；此处直接检查 trace_trap=0）
//    T6  MMIO 写 GPIO 后输出引脚出现 0x55（点灯闭环）
//    T7  MMIO 读定时器计数非零
//    T8  **MMIO 写 UART 数据寄存器后，TX 引脚上解出完整 10 位帧**：
//        起始位=0、8 位数据（LSB 先）=0x55、停止位=1 —— 由 TB 按 DIV 中点采样解码
// ----------------------------------------------------------------------------
//  备注（步骤 27 的失败定位结论，勿重复摸索）：
//    uart.sv 的发送器在写入后**先等一个整位周期（DIV 拍）才把起始位拉低**
//    （`if (tx_cnt == 0) tx_line <= tx_sr[0];`，写入时 tx_cnt 装载 DIV-1）。
//    DIV=434 时起始位出现在写入后约 434 拍，而步骤 26 的断言只在 retire 结束后
//    60 拍就检查，故恒为 tx_low=0 —— 属**观察窗口太短**，不是接入缺陷。
//    本版因此：① 参数化 UART_DIV 并由 TB 传入；② 等一个完整帧再判定；
//    ③ 断言从"线曾拉低"升级为"帧内容等于写入字节"。
// ============================================================================
`timescale 1ns/1ps
`include "defines.sv"

module tb_cpu_mem_subsystem;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // CPU 单字 I/D 端口（与子系统直连）
    wire        i_req_valid, i_req_ready, i_rsp_ready;
    wire [31:0] i_req_addr;
    wire        i_write;
    wire [31:0] i_wdata;
    wire [3:0]  i_wstrb;
    wire        i_rsp_valid, i_error;
    wire [31:0] i_rdata;

    wire        d_req_valid, d_req_ready, d_rsp_ready;
    wire [31:0] d_req_addr;
    wire        d_write;
    wire [31:0] d_wdata;
    wire [3:0]  d_wstrb;
    wire        d_rsp_valid, d_error;
    wire [31:0] d_rdata;

    // 提交 trace
    wire        trace_valid, trace_rd_we, trace_trap;
    wire [63:0] trace_order;
    wire [31:0] trace_pc, trace_instr, trace_rd_data;
    wire [4:0]  trace_rd;

    integer checks = 0, errors = 0;
    wire [31:0] gpio_out_w;          // 子系统 D 侧的 GPIO 输出引脚
    wire        timer_irq_w;         // 子系统引出的机器定时器中断（批 (c) 起真实引回 CPU）
    wire        uart_tx_w;           // 子系统 D 侧 UART 的 TX 引脚
    reg  [31:0] gpio_in_w = 32'h0;
    integer seen = 0;
    integer seq_err = 0;
    integer extra_after = 0;
    integer trap_count = 0;

    // UART 分频数：唯一来源，既传给子系统也用于 TB 端解码
    localparam integer UART_DIV_SIM = 434;   // 50 MHz / 115200

    localparam integer N_EXP = 13;   // 7 条 SRAM 写后读 + 3 条 GPIO MMIO + 1 条定时器读 + 2 条 UART

    task chk(input [255:0] name, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                $display("FAIL [%0s] got=%08h want=%08h", name, got, want);
            end else begin
                $display("PASS [%0s] = %08h", name, got);
            end
        end
    endtask

    // ---------------- DUT ----------------
    cpu_core_stage1 u_cpu (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready), .i_rsp_data(i_rdata),
        .i_rsp_error(i_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_req_write(d_write), .d_req_wdata(d_wdata), .d_req_wstrb(d_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready), .d_rsp_rdata(d_rdata),
        .d_rsp_error(d_error),
        .trace_valid(trace_valid), .trace_order(trace_order), .trace_pc(trace_pc),
        .trace_instr(trace_instr), .trace_rd(trace_rd), .trace_rd_data(trace_rd_data),
        .trace_rd_we(trace_rd_we), .trace_trap(trace_trap),
        // 批 (c)：定时器中断由子系统真实引回（u_sub.timer_irq → u_cpu.timer_irq_i）；
        // 程序未使能 mie/mstatus.MIE，故 pending 恒 0、不改变既有行为。
        // ext_irq 接 0：SoC 无外部中断源（D14，MEIP 路径"已接线、未验证"）。
        .timer_irq_i(timer_irq_w), .ext_irq_i(1'b0)
    );

    cpu_mem_subsystem #(.MEM_DEPTH(256), .MEM_AW(8), .UART_DIV(UART_DIV_SIM)) u_sub (
        .clk(clk), .rst(rst),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_write(i_write), .i_wdata(i_wdata), .i_wstrb(i_wstrb),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rdata(i_rdata), .i_error(i_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_addr(d_req_addr),
        .d_write(d_write), .d_wdata(d_wdata), .d_wstrb(d_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rdata(d_rdata), .d_error(d_error),
        .gpio_out(gpio_out_w), .gpio_in(gpio_in_w),
        .timer_irq(timer_irq_w),
        .uart_tx(uart_tx_w), .uart_rx(1'b1)     // RX 固定空闲高电平，本测试只验证发送
    );

    // I 端口在本设计中不应出现写（CPU 只取指）；给出常量使端口完整
    assign i_write = 1'b0;
    assign i_wdata = 32'h0;
    assign i_wstrb = 4'h0;

    // ---------------- 预置 ROM 程序 ----------------
    initial begin
        #1;   // 等 rom 自身 initial 的 NOP 填充完成
        u_sub.u_rom_i.mem[0] = 32'h00100093;   // addi x1,x0,1
        u_sub.u_rom_i.mem[1] = 32'h80000137;   // lui  x2,0x80000  -> 0x8000_0000
        u_sub.u_rom_i.mem[2] = 32'h02A00193;   // addi x3,x0,42
        u_sub.u_rom_i.mem[3] = 32'h00312023;   // sw   x3,0(x2)
        u_sub.u_rom_i.mem[4] = 32'h00012203;   // lw   x4,0(x2)
        u_sub.u_rom_i.mem[5] = 32'h00120293;   // addi x5,x4,1
        u_sub.u_rom_i.mem[6] = 32'h10000337;   // lui  x6,0x10000    -> 0x1000_0000
        u_sub.u_rom_i.mem[7] = 32'h01030313;   // addi x6,x6,0x10    -> 0x1000_0010 (GPIO out)
        u_sub.u_rom_i.mem[8] = 32'h05500393;   // addi x7,x0,0x55
        u_sub.u_rom_i.mem[9] = 32'h00732023;   // sw   x7,0(x6)      **MMIO 写 GPIO -> 点灯**
        u_sub.u_rom_i.mem[10]= 32'h01032403;   // lw   x8,0x10(x6)   -> 0x1000_0020 定时器计数
        u_sub.u_rom_i.mem[11]= 32'h10000337;   // lui  x6,0x10000    -> 0x1000_0000 (UART 数据)
        u_sub.u_rom_i.mem[12]= 32'h00732023;   // sw   x7,0(x6)      **MMIO 写 UART 数据寄存器 0x55**
        // 停机死循环（自跳到自身）：程序结束在此处自旋。
        // 必要性：UART 整帧需 ~4300 拍，TB 在等待期间 CPU 仍在取指；若不设停机循环，
        // PC 会越过程序末端继续向前，而 ROM 只实例化 1 KiB（AW=8 截取 addr[9:2]），
        // 于是 0x400 被映回字 0 —— 程序被重复执行，并再次写正在忙的 UART
        // （uart.sv 的"忙→error"契约会使其成为 store 访问故障），污染 T4/T5。
        u_sub.u_rom_i.mem[13]= 32'h00000063;   // beq  x0,x0,0       -> 死循环（不写寄存器）
        u_sub.u_rom_i.mem[14]= 32'h00000063;   // 兜底：万一跳转未生效也仍在自旋
    end

    // T12 用的 I 端口握手计数（批 (d-1)：接入后必须仍是"一次请求一次响应"）
    integer i_fire_count = 0;
    integer i_rsp_count  = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (i_req_valid && i_req_ready) i_fire_count <= i_fire_count + 1;
            if (i_rsp_valid && i_rsp_ready) i_rsp_count  <= i_rsp_count  + 1;
        end
    end

    // ---------------- 提交 scoreboard ----------------
    // 记录前 N_EXP 条 retire 的全字段，供逐条比对
    reg [31:0] got_pc   [0:N_EXP-1];
    reg [31:0] got_data [0:N_EXP-1];
    reg [4:0]  got_rd   [0:N_EXP-1];
    reg        got_we   [0:N_EXP-1];

    always @(negedge clk) begin
        if (!rst && trace_valid) begin
            if (seen < N_EXP) begin
                if (trace_order !== seen) begin
                    seq_err = seq_err + 1;
                    $display("FAIL trace_order=%0d 期望 %0d", trace_order, seen);
                end
                got_pc[seen]   = trace_pc;
                got_rd[seen]   = trace_rd;
                got_data[seen] = trace_rd_data;
                got_we[seen]   = trace_rd_we;
                $display("RETIRE %0d pc=%08h rd=x%0d data=%08h we=%b trap=%b",
                         seen, trace_pc, trace_rd, trace_rd_data, trace_rd_we, trace_trap);
                seen = seen + 1;
            end else if (trace_rd_we) begin
                // 程序结束后 ROM 余下位置是 NOP（addi x0,x0,0，不写寄存器）；
                // 出现"额外且写寄存器"的 retire 才说明跑飞了。
                extra_after = extra_after + 1;
                $display("FAIL 额外且写寄存器的 retire: pc=%08h rd=x%0d order=%0d",
                         trace_pc, trace_rd, trace_order);
            end
            if (trace_trap) trap_count = trap_count + 1;
        end
    end

    // ---------------- UART TX 线路级解码器 ----------------
    // 检测 TX 线下降沿（起始位起点）→ 半位对齐到起始位中点 → 之后每整位周期采样一次，
    // 共 10 位：起始 + 8 数据（LSB 先）+ 停止。同步仿真下无需过采样，中点采样即可。
    localparam integer UART_BITS = 10;
    reg        tx_prev    = 1'b1;
    reg        dec_busy   = 1'b0;
    integer    dec_cnt    = 0;
    integer    dec_bit    = 0;
    reg [9:0]  frame      = 10'h3FF;      // frame[i] = 第 i 个采样位（0 为起始位）
    reg        frame_done = 1'b0;
    integer    frame_cnt  = 0;

    always @(posedge clk) begin
        if (!rst) begin
            tx_prev <= uart_tx_w;
            if (!dec_busy) begin
                if (tx_prev === 1'b1 && uart_tx_w === 1'b0 && !frame_done) begin
                    dec_busy <= 1'b1;
                    dec_cnt  <= (UART_DIV_SIM / 2) - 1;   // 半位后 = 起始位中点
                    dec_bit  <= 0;
                end
            end else begin
                if (dec_cnt == 0) begin
                    frame[dec_bit] <= uart_tx_w;
                    if (dec_bit == UART_BITS - 1) begin
                        dec_busy   <= 1'b0;
                        frame_done <= 1'b1;
                        frame_cnt  <= frame_cnt + 1;
                    end else begin
                        dec_bit <= dec_bit + 1;
                        dec_cnt <= UART_DIV_SIM - 1;      // 其后每位间隔一个整位周期
                    end
                end else begin
                    dec_cnt <= dec_cnt - 1;
                end
            end
        end
    end

    // 由 10 位帧还原字节：frame[1..8] 为 LSB 先的数据位
    wire [7:0] frame_byte = {frame[8], frame[7], frame[6], frame[5],
                             frame[4], frame[3], frame[2], frame[1]};

    // 看门狗
    // 注：门限由 3000 放宽到 20000 —— 本测试在 retire 结束后还要等一个完整 UART 帧
    //     （10 位 × 434 拍 ≈ 4340 拍），原门限会在帧中途触发 $finish；
    //     放宽后仍足以捕获真正的挂死（正常执行仅约 60 拍 + 一帧）。
    integer wd = 0;
    always @(posedge clk) begin
        if (!rst) begin
            wd = wd + 1;
            if (wd > 20000) begin
                $display("WATCHDOG: 卡住 ireq_v=%b ireq_r=%b iaddr=%h irsp_v=%b dreq_v=%b dreq_r=%b",
                         i_req_valid, i_req_ready, i_req_addr, i_rsp_valid,
                         d_req_valid, d_req_ready);
                $finish;
            end
        end
    end

    // 预期 retire 序列
    reg [31:0] exp_pc   [0:N_EXP-1];
    reg [31:0] exp_data [0:N_EXP-1];
    reg [4:0]  exp_rd   [0:N_EXP-1];
    reg        exp_we   [0:N_EXP-1];
    reg        exp_ignore_data [0:N_EXP-1];
    integer    i, bad;
    integer    timeout = 0;

    initial begin
        $display("==================================================");
        $display("  CPU + 存储子系统 接入测试（CPU -> adapter -> ROM/SRAM）");
        $display("==================================================");

        for (i = 0; i < N_EXP; i = i + 1) exp_ignore_data[i] = 1'b0;
        exp_pc[0]=32'h00; exp_rd[0]=5'd1; exp_data[0]=32'h0000_0001; exp_we[0]=1'b1;
        exp_pc[1]=32'h04; exp_rd[1]=5'd2; exp_data[1]=32'h8000_0000; exp_we[1]=1'b1;
        exp_pc[2]=32'h08; exp_rd[2]=5'd3; exp_data[2]=32'd42;         exp_we[2]=1'b1;
        exp_pc[3]=32'h0c; exp_rd[3]=5'd0; exp_data[3]=32'd0;          exp_we[3]=1'b0;
        exp_pc[4]=32'h10; exp_rd[4]=5'd4; exp_data[4]=32'd42;         exp_we[4]=1'b1;
        exp_pc[5]=32'h14; exp_rd[5]=5'd5; exp_data[5]=32'd43;         exp_we[5]=1'b1;
        exp_pc[6]=32'h18; exp_rd[6]=5'd6; exp_data[6]=32'h1000_0000; exp_we[6]=1'b1;
        exp_pc[7]=32'h1c; exp_rd[7]=5'd6; exp_data[7]=32'h1000_0010; exp_we[7]=1'b1;
        exp_pc[8]=32'h20; exp_rd[8]=5'd7; exp_data[8]=32'd85;         exp_we[8]=1'b1;
        exp_pc[9]=32'h24; exp_rd[9]=5'd0; exp_data[9]=32'd0;          exp_we[9]=1'b0;
        exp_pc[10]=32'h28; exp_rd[10]=5'd8; exp_data[10]=32'd0;       exp_we[10]=1'b1;
        exp_ignore_data[10]=1'b1;   // 定时器计数自由运行，只比对 pc/rd/we
        exp_pc[11]=32'h2c; exp_rd[11]=5'd6; exp_data[11]=32'h1000_0000; exp_we[11]=1'b1;
        exp_pc[12]=32'h30; exp_rd[12]=5'd0; exp_data[12]=32'd0;       exp_we[12]=1'b0;

        repeat (3) @(posedge clk);
        rst = 1'b0;

        while (seen < N_EXP && wd < 1500) @(posedge clk);

        // 程序结束后等 TX 线上解出完整一帧：
        // uart.sv 在写入后先等一个整位周期（DIV 拍）才把起始位拉低，整帧约 10×DIV 拍。
        // 步骤 26 的"retire 后 60 拍"窗口正是因此恒为 tx_low=0（观察窗口过短）。
        timeout = 0;
        while (!frame_done && timeout < 20 * UART_DIV_SIM) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        chk("T1 retire count == N_EXP", seen, N_EXP);
        chk("T1b trace order errors", seq_err, 0);
        chk("T4 no extra register-writing retire after 7th", extra_after, 0);
        chk("T5 no trap during correct run", trap_count, 0);
        // T6：CPU 程序经 MMIO 写 GPIO，输出引脚必须出现该值（点灯闭环）
        chk("T6 GPIO out written via MMIO", gpio_out_w, 32'h0000_0055);
        // T7：CPU 经 MMIO 读定时器计数，自由运行的计数必须非零
        checks = checks + 1;
        if (u_cpu.u_regfile.regs[8] == 32'd0) begin
            errors = errors + 1;
            $display("FAIL [T7 timer count read via MMIO is nonzero] x8=0");
        end else begin
            $display("PASS [T7 timer count read via MMIO is nonzero] x8=%0d",
                     u_cpu.u_regfile.regs[8]);
        end

        // T8：CPU 经 MMIO 写 UART 数据寄存器 0x55 后，TX 线路上必须出现完整一帧：
        //     起始位低、8 位数据 LSB 先 = 0x55、停止位高。
        //     （线路级解码，不依赖 UART 内部信号；数据位顺序错误会解出 0xAA 而被捕获）
        checks = checks + 1;
        if (!frame_done) begin
            errors = errors + 1;
            $display("FAIL [T8 UART TX frame after MMIO write] 未解出完整帧 frame_done=0 timeout=%0d", timeout);
        end else if (frame[0] !== 1'b0 || frame[9] !== 1'b1 || frame_byte !== 8'h55) begin
            errors = errors + 1;
            $display("FAIL [T8 UART TX frame after MMIO write] start=%b data=%02h stop=%b（期望 start=0 data=55 stop=1）",
                     frame[0], frame_byte, frame[9]);
        end else begin
            $display("PASS [T8 UART TX frame after MMIO write] start=0 data=%02h stop=1（帧数=%0d, %0d 拍/位中点采样）",
                     frame_byte, frame_cnt, UART_DIV_SIM);
        end

        // T1c：逐条比对前 7 条 retire 的 pc/rd/we/data 全字段
        bad = 0;
        for (i = 0; i < N_EXP; i = i + 1) begin
            if (i < seen) begin
                if (got_pc[i] !== exp_pc[i] || got_rd[i] !== exp_rd[i] ||
                    got_we[i] !== exp_we[i] ||
                    (!exp_ignore_data[i] && got_data[i] !== exp_data[i])) begin
                    bad = bad + 1;
                    $display("FAIL retire[%0d] 实际 pc=%08h rd=x%0d data=%08h we=%b / 期望 pc=%08h rd=x%0d data=%08h we=%b",
                             i, got_pc[i], got_rd[i], got_data[i], got_we[i],
                             exp_pc[i], exp_rd[i], exp_data[i], exp_we[i]);
                end
            end
        end
        chk("T1c retire fields match expected", bad, 0);

        // T2：经 adapter 写入的 SRAM 内容
        chk("T2 D-side SRAM[0] == 42", {u_sub.u_sram_d.mem3[0], u_sub.u_sram_d.mem2[0], u_sub.u_sram_d.mem1[0], u_sub.u_sram_d.mem0[0]}, 32'd42);

        // ------------------------------------------------------------------
        // T9～T12：I-Cache 接入后的行为（批 (d-1)，ADR-CACHE-INTEGRATION）
        // ------------------------------------------------------------------
        // T9：I-Cache 必须真的**被用到**（命中数 > 0）。
        //     程序从 ROM 取指，地址 0x00..0x38 全落在同一条 16 B 行内 ⇒ 首次缺失填充后
        //     后续取指应全部命中。若 T9 为 0，说明 I 侧走了 bypass（ROM 未被判为可缓存），
        //     接入就成了纯摆设 —— 这正是 ADR D-C3 把 I 侧 ROM 纳入可缓存的原因。
        checks = checks + 1;
        if (u_sub.u_icache.stat_hit == 32'd0) begin
            errors = errors + 1;
            $display("FAIL [T9 I-Cache hits > 0] 命中数为 0（接入未生效）");
        end else begin
            $display("PASS [T9 I-Cache hits > 0] hit=%0d miss=%0d",
                     u_sub.u_icache.stat_hit, u_sub.u_icache.stat_miss);
        end
        // T10：缺失次数必须有限且非零 —— 非零证明走过填充路径，有限证明没有反复重填
        //      （反复重填意味着行没被分配，例如整行不分配的裁决被破坏）。
        checks = checks + 1;
        if (u_sub.u_icache.stat_miss == 32'd0 || u_sub.u_icache.stat_miss > 32'd8) begin
            errors = errors + 1;
            $display("FAIL [T10 I-Cache miss 次数合理] miss=%0d（期望 1..8）", u_sub.u_icache.stat_miss);
        end else begin
            $display("PASS [T10 I-Cache miss 次数合理] miss=%0d", u_sub.u_icache.stat_miss);
        end
        // T11：MMIO 取指/访存必须**不进 Cache**。本程序全部指令取自 ROM，而 D 侧的 MMIO
        //      store/load 走 bypass，故 I-Cache 的 miss 数应等于"被取指的不同 16 B 行数"（此处为 1）；
        //      同时 D-Cache 侧（batch (d-2)）尚未接入，这里只断言 MMIO 未污染 I-Cache 命中率。
        checks = checks + 1;
        if (u_sub.u_icache.stat_miss > 32'd4) begin
            errors = errors + 1;
            $display("FAIL [T11 MMIO 未污染 I-Cache] miss=%0d 偏大", u_sub.u_icache.stat_miss);
        end else begin
            $display("PASS [T11 MMIO 未污染 I-Cache] miss=%0d hit=%0d",
                     u_sub.u_icache.stat_miss, u_sub.u_icache.stat_hit);
        end
        // T12：**一次请求一次响应，且至多一笔在途**（接入后时序变长的路径最容易破坏这条契约）。
        //      程序末尾是自旋循环，CPU 一直在取指，故检查时刻存在**恰好一笔**在途请求是正常的；
        //      用"fire - rsp ∈ {0,1}"表达该不变式，并把"响应多于请求"（重复响应）判为硬失败。
        //      （首版写成 fire==rsp 严格相等 → 因这一笔在途而误报；正确判据见下。）
        checks = checks + 1;
        if (i_rsp_count > i_fire_count) begin
            errors = errors + 1;
            $display("FAIL [T12 I 端口 响应多于请求（重复响应）] fire=%0d rsp=%0d",
                     i_fire_count, i_rsp_count);
        end else if ((i_fire_count - i_rsp_count) > 1) begin
            errors = errors + 1;
            $display("FAIL [T12 I 端口 在途请求 > 1] fire=%0d rsp=%0d",
                     i_fire_count, i_rsp_count);
        end else if ((i_rsp_count + (i_fire_count - i_rsp_count)) !==
                     (u_sub.u_icache.stat_hit + u_sub.u_icache.stat_miss)) begin
            errors = errors + 1;
            $display("FAIL [T12 I-Cache 计数与端口握手不符] fire=%0d hit+miss=%0d",
                     i_fire_count, u_sub.u_icache.stat_hit + u_sub.u_icache.stat_miss);
        end else begin
            $display("PASS [T12 I 端口 一次请求一次响应/至多一笔在途] fire=%0d rsp=%0d (hit=%0d miss=%0d)",
                     i_fire_count, i_rsp_count, u_sub.u_icache.stat_hit, u_sub.u_icache.stat_miss);
        end

        // T13～T15：D 侧 Cache 接入后的行为（批 (d-2) + 出口租约修订）。
        //   程序顺序：SRAM store(0x0c) → SRAM load(0x10) → MMIO load/store。
        //   · 两笔 SRAM 访问均可缓存，必须走 D-Cache：
        //       store 先到 → 一次 store miss（写穿、不分配），stat_store += 1；
        //       load  后到 → 因未分配，再发生一次 fill miss，stat_miss += 1。
        //   · ROM/MMIO 不可缓存，必须走 bypass，不得进入 D-Cache 标签比较。
        //   ⇒ 本程序稳定预期：hit=0, miss=2, store=1。
        checks = checks + 1;
        if (u_sub.u_dcache.stat_hit !== 32'd0 ||
            u_sub.u_dcache.stat_miss !== 32'd2 ||
            u_sub.u_dcache.stat_store !== 32'd1) begin
            errors = errors + 1;
            $display("FAIL [T13 D-Cache 使用/计数] hit=%0d miss=%0d store=%0d（期望 0/2/1）",
                     u_sub.u_dcache.stat_hit, u_sub.u_dcache.stat_miss, u_sub.u_dcache.stat_store);
        end else begin
            $display("PASS [T13 D-Cache 使用/计数] hit=0 miss=2 store=1");
        end

        // T14：填充回来的数据必须正确 —— 这条是回归 T3 的**语义锚点**：
        //      x4 必须仍是 42。若 D-Cache 把行内偏移/字节选择搞错，x4 会变成别的值，
        //      T3 会一起变红；这里给出更直接的定位信息（把两者显式并列）。
        checks = checks + 1;
        if (u_cpu.u_regfile.regs[4] !== 32'd42) begin
            errors = errors + 1;
            $display("FAIL [T14 D-Cache 回读数据正确] x4=%0d（期望 42）dcache hit=%0d miss=%0d",
                     u_cpu.u_regfile.regs[4], u_sub.u_dcache.stat_hit, u_sub.u_dcache.stat_miss);
        end else begin
            $display("PASS [T14 D-Cache 回读数据正确] x4=42（经 D-Cache miss 填充后正确）");
        end

        // T15：只有唯一一笔 cacheable SRAM store 允许进入 D-Cache 计数。
        //     本程序共有 3 笔 store：SRAM + GPIO + UART；后两笔 MMIO 必须 bypass。
        //     stat_store 必须恰好 1：为 0 表示 cacheable store 仍被错误 bypass，
        //     >1 表示 MMIO store 误入 D-Cache（写 ROM 静默成功的前兆）。
        checks = checks + 1;
        if (u_sub.u_dcache.stat_store !== 32'd1) begin
            errors = errors + 1;
            $display("FAIL [T15 cacheable store 唯一进 D-Cache] stat_store=%0d（期望 1）",
                     u_sub.u_dcache.stat_store);
        end else begin
            $display("PASS [T15 cacheable store 唯一进 D-Cache] stat_store=1");
        end

        chk("T3 x0", u_cpu.u_regfile.regs[0], 32'd0);
        chk("T3 x1", u_cpu.u_regfile.regs[1], 32'd1);
        chk("T3 x2", u_cpu.u_regfile.regs[2], 32'h8000_0000);
        chk("T3 x3", u_cpu.u_regfile.regs[3], 32'd42);
        chk("T3 x4", u_cpu.u_regfile.regs[4], 32'd42);
        chk("T3 x5", u_cpu.u_regfile.regs[5], 32'd43);

        // 逐条比对 retire 全字段
        bad = 0;
        for (i = 0; i < N_EXP; i = i + 1) begin
            // 已在 scoreboard 里打印，这里只统计（顺序已由 trace_order 校验）
        end

        $display("==================================================");
        $display("  检查项: %0d", checks);
        if (errors == 0)
            $display("  ALL TESTS PASSED (0 errors)");
        else
            $display("  %0d FAILED", errors);
        $display("==================================================");
        $finish;
    end

endmodule
