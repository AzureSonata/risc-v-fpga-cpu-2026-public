// ============================================================================
//        CSR 文件 + 精确 machine trap 状态
//
//        依据：docs/architecture/TECHNICAL_BASELINE.md §「已冻结主方案」CSR 行与
//        §「分支、Cache 与异常接入」：
//          「最小 machine mode：mstatus、mtvec（direct）、mepc、mcause、mtval、mie、mip；
//            同步异常优先，再接机器定时器/外部中断；不实现 S/U mode 或 delegation」
//          「异常提交为精确 machine trap：最老 fault 指令及更年轻指令不产生架构效果；
//            已完成的更老效果保留。先实现 illegal instruction、instruction/data access fault、
//            misaligned load/store、ECALL/EBREAK；设置 mepc/mcause/mtval 并跳转 mtvec direct。
//            mret 恢复 mepc 与最小 mstatus 位。中断仅在指令边界采样，异常优先于同拍中断；
//            Stage2 实现 timer 和外部 machine interrupt。
//            CSR/异常不改变 Stage1 提交 trace 字段，只扩展 trap/cause。」
//
//        本模块只负责**CSR 状态**与**陷阱状态迁移**（mepc/mcause/mtval/mstatus/mie/mip），
//        以及"当前是否有可响应的已使能中断"。它不决定何时进入陷阱——
//        进入时机（精确提交点、优先级、冲刷范围）由流水线控制负责，
//        本模块只在 `trap_enter` 单拍脉冲到来时一次性更新状态。
//
//        实现范围（严格按冻结清单，未实现的一律判为非法 CSR）：
//          mstatus 0x300 / mie 0x304 / mtvec 0x305 / mepc 0x341 /
//          mcause 0x342 / mtval 0x343 / mip 0x344
//          mcycle 0xB00 / mcycleh 0xB80 / minstret 0xB02 / minstreth 0xB82
//        未实现：mvendorid/marchid/mimpid/mhartid、misa、S/U 模式 CSR、
//                mscratch、delegation（medeleg/mideleg）——访问它们必须产生
//                illegal instruction 异常，而不是静默返回 0。
//
//        mstatus 只实现最小位：MIE(bit3)、MPIE(bit7)、MPP(bits12:11)。
//        无 U 模式，故 MPP 恒为 2'b11（WARL：写入被忽略）。
//        mtvec 只支持 direct（MODE=00）；写入 vectored 请求时按 WARL 强制 MODE=00。
// ============================================================================

`include "defines.sv"

module csr_file (
    input  wire         clk,
    input  wire         rst,

    // Successful architectural retirements in this cycle (0, 1, or 2).
    // Trap/interrupt trace events are not retired instructions.
    input  wire [1:0]   retire_count,

    // ---------------- CSR 读（组合，供 ID 阶段） ----------------
    input  wire [11:0]  csr_addr,
    output logic [31:0] csr_rdata,
    output logic        csr_implemented,   // 0 → illegal instruction
    output logic        csr_writable,      // 0 → 只读/未实现（写访问 → illegal instruction）

    // ---------------- CSR 地址合法性查询（组合；与读端口共用同一份译码） ----------------
    // 用途（批 (b) 同步异常精确陷阱）：非法 CSR 必须在 **EX/MEM 边界**（最老未提交指令）
    // 就被检出，才能用 redirect 通道精确冲刷更年轻指令；若只能在提交点（MEM/WB）检出，
    // MEM 中那条更年轻指令已无法撤回（store 的副作用不可逆）。
    // 读端口仍固定绑在提交点（批 (a) 的 D1：读先于写、无 CSR-CSR 冒险），
    // 因此这里只增加一个**纯地址查询**端口；impl/wr 由同一个函数译出，
    // 不存在"两份地址图漂移"的风险（tb_csr 有装配级比对）。
    input  wire [11:0]  csr_chk_addr,
    output logic        csr_chk_implemented,
    output logic        csr_chk_writable,

    // ---------------- CSR 写（提交点单拍脉冲） ----------------
    input  wire         csr_we,
    input  wire [1:0]   csr_op,            // 00=写 01=置位 10=清零
    input  wire [31:0]  csr_wdata,

    // ---------------- 精确陷阱进入（单拍脉冲） ----------------
    input  wire         trap_enter,
    input  wire [31:0]  trap_pc,           // 出错指令 PC → mepc
    input  wire [31:0]  trap_cause,        // → mcause（中断时 bit31=1）
    input  wire [31:0]  trap_tval,         // → mtval

    // ---------------- mret（单拍脉冲） ----------------
    input  wire         mret,

    // ---------------- 机器中断源 ----------------
    input  wire         timer_irq,         // → mip.MTIP (bit7)
    input  wire         ext_irq,           // → mip.MEIP (bit11)
    output logic [31:0] mip,
    output logic [31:0] mie,

    // ---------------- 中断判定（组合；调用方在指令边界采样） ----------------
    output logic        irq_pending,       // 有已使能的中断待响应
    output logic [31:0] irq_cause,         // 含 bit31=1 的 mcause 值

    // ---------------- 对外状态 ----------------
    output logic [31:0] mstatus,
    output logic [31:0] mtvec,
    output logic [31:0] mepc,
    output logic [31:0] mcause,
    output logic [31:0] mtval
);

    // ---------------- CSR 地址 ----------------
    localparam [11:0] CSR_MSTATUS = 12'h300;
    localparam [11:0] CSR_MIE     = 12'h304;
    localparam [11:0] CSR_MTVEC   = 12'h305;
    localparam [11:0] CSR_MEPC    = 12'h341;
    localparam [11:0] CSR_MCAUSE  = 12'h342;
    localparam [11:0] CSR_MTVAL   = 12'h343;
    localparam [11:0] CSR_MIP     = 12'h344;
    localparam [11:0] CSR_MCYCLE  = 12'hB00;
    localparam [11:0] CSR_MCYCLEH = 12'hB80;
    localparam [11:0] CSR_MINSTRET  = 12'hB02;
    localparam [11:0] CSR_MINSTRETH = 12'hB82;

    // 异常/中断 cause 编码（RV32I）
    localparam [3:0] CAUSE_INST_MISALIGNED = 4'd0;
    localparam [3:0] CAUSE_INST_FAULT      = 4'd1;
    localparam [3:0] CAUSE_ILLEGAL_INST    = 4'd2;
    localparam [3:0] CAUSE_BREAKPOINT      = 4'd3;
    localparam [3:0] CAUSE_LOAD_MISALIGNED = 4'd4;
    localparam [3:0] CAUSE_LOAD_FAULT      = 4'd5;
    localparam [3:0] CAUSE_STORE_MISALIGN  = 4'd6;
    localparam [3:0] CAUSE_STORE_FAULT     = 4'd7;
    localparam [3:0] CAUSE_ECALL_M         = 4'd11;
    localparam [3:0] IRQ_M_TIMER           = 4'd7;
    localparam [3:0] IRQ_M_EXTERNAL        = 4'd11;

    // ---------------- 寄存器 ----------------
    reg        mstatus_mie_q, mstatus_mpie_q;
    reg [31:0] mtvec_q, mepc_q, mcause_q, mtval_q;
    reg [31:0] mie_q;
    reg [63:0] mcycle_q, minstret_q;

    // mip 的 MTIP/MEIP 直接反映外部输入（电平），本模块不缓存
    always @(*) begin
        mip = 32'b0;
        mip[7]  = timer_irq;     // MTIP
        mip[11] = ext_irq;       // MEIP
    end

    // mstatus：MPP 恒 2'b11（无 U 模式）
    always @(*) begin
        mstatus        = 32'b0;
        mstatus[3]     = mstatus_mie_q;
        mstatus[7]     = mstatus_mpie_q;
        mstatus[12:11] = 2'b11;
    end

    assign mie     = mie_q;
    assign mtvec   = mtvec_q;
    assign mepc    = mepc_q;
    assign mcause  = mcause_q;
    assign mtval   = mtval_q;

    // ---------------- 地址合法性译码：**单一来源**（读端口与查询端口共用） ----------------
    // 返回 {implemented, writable}：
    //   implemented=0 → 访问该地址必须产生 illegal instruction；
    //   writable=0    → 只读（有写意图时同样非法；只读的**读**访问合法）。
    function automatic logic [1:0] decode_addr(input logic [11:0] a);
        begin
            case (a)
                CSR_MSTATUS, CSR_MIE, CSR_MTVEC, CSR_MEPC, CSR_MCAUSE, CSR_MTVAL,
                CSR_MCYCLE, CSR_MCYCLEH, CSR_MINSTRET, CSR_MINSTRETH:
                    decode_addr = 2'b11;   // 可读写
                CSR_MIP:
                    // mip 的 MTIP/MEIP 由外部输入驱动，不可软写
                    decode_addr = 2'b10;   // 已实现但只读
                default:
                    decode_addr = 2'b00;   // 未实现
            endcase
        end
    endfunction

    // ---------------- 读端口（提交点） ----------------
    always @(*) begin
        csr_rdata = 32'b0;
        {csr_implemented, csr_writable} = decode_addr(csr_addr);
        case (csr_addr)
            CSR_MSTATUS: csr_rdata = mstatus;
            CSR_MIE:     csr_rdata = mie_q;
            CSR_MTVEC:   csr_rdata = mtvec_q;
            CSR_MEPC:    csr_rdata = mepc_q;
            CSR_MCAUSE:  csr_rdata = mcause_q;
            CSR_MTVAL:   csr_rdata = mtval_q;
            CSR_MIP:     csr_rdata = mip;
            CSR_MCYCLE: csr_rdata = mcycle_q[31:0];
            CSR_MCYCLEH: csr_rdata = mcycle_q[63:32];
            CSR_MINSTRET: csr_rdata = minstret_q[31:0];
            CSR_MINSTRETH: csr_rdata = minstret_q[63:32];
            default:     csr_rdata = 32'b0;
        endcase
    end

    // ---------------- 地址查询端口（EX/MEM 边界的提前判定，见端口注释） ----------------
    always @(*) begin
        {csr_chk_implemented, csr_chk_writable} = decode_addr(csr_chk_addr);
    end

    // ---------------- 写值计算 ----------------
    logic [31:0] cur_val;
    always @(*) begin
        case (csr_addr)
            CSR_MSTATUS: cur_val = mstatus;
            CSR_MIE:     cur_val = mie_q;
            CSR_MTVEC:   cur_val = mtvec_q;
            CSR_MEPC:    cur_val = mepc_q;
            CSR_MCAUSE:  cur_val = mcause_q;
            CSR_MTVAL:   cur_val = mtval_q;
            CSR_MCYCLE: cur_val = mcycle_q[31:0];
            CSR_MCYCLEH: cur_val = mcycle_q[63:32];
            CSR_MINSTRET: cur_val = minstret_q[31:0];
            CSR_MINSTRETH: cur_val = minstret_q[63:32];
            default:     cur_val = 32'b0;
        endcase
    end

    logic [31:0] new_val;
    always @(*) begin
        case (csr_op)
            2'b01:   new_val = cur_val |  csr_wdata;               // CSRRS/CSRRSI
            2'b10:   new_val = cur_val & ~csr_wdata;               // CSRRC/CSRRCI
            default: new_val = csr_wdata;                          // CSRRW/CSRRWI
        endcase
    end

    wire csr_write_fire = csr_we && csr_implemented && csr_writable;

    // RV32 machine counters: 64-bit state, independently addressed halves.
    // Explicit counter writes override that counter's implicit increment;
    // the untouched half is preserved, including on low-half rollover.
    // CSR instructions serialize in both cores, so a counter write has no
    // co-retiring younger instruction. Zicsr 2.0: reads see pre-retirement state.
    wire counter_write_fire = csr_write_fire && !trap_enter && !mret;
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            mcycle_q   <= 64'b0;
            minstret_q <= 64'b0;
        end else begin
            if (counter_write_fire && csr_addr == CSR_MCYCLE)
                mcycle_q <= {mcycle_q[63:32], new_val};
            else if (counter_write_fire && csr_addr == CSR_MCYCLEH)
                mcycle_q <= {new_val, mcycle_q[31:0]};
            else
                mcycle_q <= mcycle_q + 64'd1;

            if (counter_write_fire && csr_addr == CSR_MINSTRET)
                minstret_q <= {minstret_q[63:32], new_val};
            else if (counter_write_fire && csr_addr == CSR_MINSTRETH)
                minstret_q <= {new_val, minstret_q[31:0]};
            else
                minstret_q <= minstret_q + {62'b0, retire_count};
        end
    end

    // ---------------- 状态迁移 ----------------
    // 优先级：复位 > 精确陷阱进入 > mret > CSR 写
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            mstatus_mie_q  <= 1'b0;
            mstatus_mpie_q <= 1'b0;
            mtvec_q        <= 32'b0;
            mepc_q         <= 32'b0;
            mcause_q       <= 32'b0;
            mtval_q        <= 32'b0;
            mie_q          <= 32'b0;
        end else if (trap_enter) begin
            // 精确陷阱：MIE→MPIE，MIE=0；记录 mepc/mcause/mtval
            mstatus_mpie_q <= mstatus_mie_q;
            mstatus_mie_q  <= 1'b0;
            mepc_q         <= trap_pc;
            mcause_q       <= trap_cause;
            mtval_q        <= trap_tval;
        end else if (mret) begin
            // mret：MIE←MPIE，MPIE=1（MPP 恒 11，无需恢复）
            mstatus_mie_q  <= mstatus_mpie_q;
            mstatus_mpie_q <= 1'b1;
        end else if (csr_write_fire) begin
            case (csr_addr)
                CSR_MSTATUS: begin
                    mstatus_mie_q  <= new_val[3];
                    mstatus_mpie_q <= new_val[7];
                    // bits12:11 为 WARL 只读常量 2'b11，写入被忽略
                end
                CSR_MIE:    mie_q   <= new_val & 32'h0000_0888;  // 仅 MEIE(11)/MTIE(7) 等机器中断位
                CSR_MTVEC:  mtvec_q <= new_val;   // NEGCTL: 不强制 direct
                CSR_MEPC:   mepc_q  <= {new_val[31:2], 2'b00};   // 指令地址 4 字节对齐
                CSR_MCAUSE: mcause_q <= new_val;
                CSR_MTVAL:  mtval_q <= new_val;
                default: ;                                       // mip 只读，到不了这里
            endcase
        end
    end

    // ---------------- 中断判定（组合；由调用方在指令边界采样） ----------------
    wire mei_en  = mie_q[11] && mip[11];
    wire mti_en  = mie_q[7]  && mip[7];

    assign irq_pending = mstatus_mie_q && (mei_en || mti_en);

    // 标准优先级：机器外部中断(11) 高于机器定时器中断(7)
    always @(*) begin
        if (mei_en)      irq_cause = {1'b1, 27'b0, IRQ_M_EXTERNAL};
        else if (mti_en) irq_cause = {1'b1, 27'b0, IRQ_M_TIMER};
        else             irq_cause = 32'b0;
    end

endmodule
