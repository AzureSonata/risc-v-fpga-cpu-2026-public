// =============================================================================
//  kws_mmio.sv  —  KWS 加速器 MMIO 包装层（K-02 / K6 的 SoC 侧缺件）
//
//  ★ 性质：**候选实现（PROPOSED）**，不是已签核的 SoC RTL。
//    作者：覃峥榕（固件/复核侧）；SoC integration owner 为康文。
//    本文件的用途是让 K6 的 S4（寄存器语义）与 S5（真实 MMIO 驱动）**先能跑**，
//    而不是替代 owner 的设计裁决。凡与 `docs/architecture/RFC-KWS-MMIO-ABI.md`
//    冲突之处，以 RFC 为准并改本文件。
//
//  依据（逐条可核）：
//    · 寄存器/地址：docs/architecture/KWS_SOC_TOP_INTERFACE_DRAFT.md §3、§5
//    · 语义来源：   RFC-KWS-MMIO-ABI.md §2（寄存器）、§3（错误码）、§11（裁决）
//    · 核的端口：   rtl/accel/openeye_top.sv（start/busy/done/error/error_code，
//                   四组同步读存储口，res_we/res_addr[15:0]/res_data[7:0]）
//
//  本层**必须**替核做的事（核没有这些能力，逐条有 RTL 证据）：
//    1. STATUS.DONE 锁存：核的 done 是单拍脉冲（openeye_top.sv:260 清、:313 置），
//       直接给 CPU 读会漏采。
//    2. dirty 位与「1,960 字节全 1」：核根本不接触输入 buffer（只有 in_q 读口）。
//    3. job 期结果不可读：核的 res_we = rq2_valid 是组合直连（:241），无 read-gate。
//    4. CYCLE_COUNT：核无 cycle_count 端口。
//    5. 超时 ERROR_CODE=3：核只出 0/1/2/4（E_NONE/E_OP/E_BUFFER/E_ARITH）。
//    6. FC 阶段判定：核不输出"现在在 FC"，只能由 DW 已写结果数推断（见 §PHASE）。
//
//  ---- 三个已知的接口缺口（写给 owner，不是本文件的 bug）----
//  G1 核不输出 layer phase ⇒ 本层用 `wr_cnt >= oh*ow*cout` 推断 FC 起点。
//     若将来 DW 最后一笔写与 FC 第一笔读同拍，需要核补 `o_fc_phase` 或 `o_layer`。
//  G2 核的 res_addr 是**字节地址**、res_data 是 int8 ⇒ FC 的 4 个 logit 占 4 字节，
//     `0x800` 一次读出的就是一个 word（4 个 int8）。若将来 logits 要 int32，
//     本层的 0x800 映射需要改（D2 未定案）。
//  G3 描述符（层参数）在 V1 由**端口**输入，不占 MMIO。真实 SoC 里描述符从哪取
//     （buffer 内 128 B？单独寄存器组？）属 K-02，未定；本层不擅自发明地址。
// =============================================================================
`default_nettype none

module kws_mmio #(
    parameter integer INPUT_BYTES      = 1960,
    parameter integer RES_BYTES        = 4096,     // 结果/激活 RAM 字节数（≥ 4004）
    parameter integer LOGIT_OFF        = 4000,     // FC logits 在 RAM 内的字节偏移（D2）
    parameter [31:0]  TIMEOUT_DEFAULT  = 32'd704040, // D1 提案：2 × 352,020
    parameter [31:0]  ESTOP_WINDOW_DEFAULT = 32'd1350000, // 50 ms @27 MHz
    parameter [31:0]  ID_VALUE         = 32'h3153_574B, // 'K' 'W' 'S' '1'（LE）
    // Default to the hash-locked micro_speech parameter/descriptor ROM. External
    // parameter ports remain available only for explicit alternate-model builds.
    parameter         MODEL_ROM_ENABLE = 1'b1,
    // A10（硬件 JOB_SEQ）**候选**实现开关：
    //   0 = V1 默认行为：0x020 未分配，读写均返回 bus error（与 V1 接口逐位一致）；
    //   1 = 启用 32-bit RO JOB_SEQ@0x020：每次**被接受**的 START 自动 +1，
    //       固件读结果时同时读它，即可判断"这份结果是不是我这次 job 的"。
    //   ⚠️ RFC §11 的 A10 建议仍是"V1 不加"；采纳与否由 PR 一次审查决定，
    //      所以默认值必须是 0 —— 默认构建等于单方面改 ABI。
    parameter integer JOB_SEQ_EN       = 0
)(
    input  wire         clk,
    input  wire         rst,

    // ---- Tier-2 急停（ICR v1.0 / R4-B）----
    input  wire         estop_arm,     // 专用板级 strap，默认低=撤防
    input  wire         estop_por,     // 配置/上电复位：唯一清 trip 的路径
    output wire         estop_trip,    // 高=急停

    // ---------------- 上游总线（与 mem_map_adapter 的 accel_* 端口同形） ----------------
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [31:0]  addr,          // 绝对地址：0x4000_0xxx 控制窗 / 0x4000_1xxx buffer 窗
    input  wire         write,
    input  wire [31:0]  wdata,
    input  wire [3:0]   wstrb,
    output wire         rsp_valid,
    input  wire         rsp_ready,
    output wire [31:0]  rdata,
    output wire         error,

    // ---------------- 层描述符（G3：V1 由端口给，不占 MMIO） ----------------
    input  wire [15:0]  dw_ih,
    input  wire [15:0]  dw_iw,
    // ⚠️ oh/ow 必须由描述符给：真实模型是 SAME 非对称 pad（49/2/10/pt=4 ⇒ 25，
    //    而 (49+4-10)/2+1 = 22）。用对称公式推会算错 DW 输出元素数，
    //    进而让 FC 阶段判定（G1）提前翻转、读错激活。
    input  wire [15:0]  dw_oh,
    input  wire [15:0]  dw_ow,
    input  wire [15:0]  dw_kh,
    input  wire [15:0]  dw_kw,
    input  wire [15:0]  dw_sh,
    input  wire [15:0]  dw_sw,
    input  wire [15:0]  dw_pt,
    input  wire [15:0]  dw_pl,
    input  wire [15:0]  dw_cout,
    input  wire signed [31:0] in_zp,
    input  wire signed [31:0] dw_out_zp,
    input  wire [15:0]  fc_nin,
    input  wire [15:0]  fc_nout,
    input  wire signed [31:0] fc_out_zp,
    input  wire signed [31:0] act_min,
    input  wire signed [31:0] act_max,

    // ---------------- 四组存储口（同步读：地址本拍给、数据次拍到；由上层 BRAM 提供） ----------------
    output wire [15:0]  dw_w_idx,
    output wire [31:0]  fc_w_idx,
    output wire [15:0]  bias_idx,
    output wire [15:0]  quant_idx,
    input  wire signed [7:0]  w_q,
    input  wire signed [31:0] bias_q,
    input  wire signed [31:0] quant_mult,
    input  wire signed [31:0] quant_shift,

    // ---------------- 状态/中断（给顶层与 TB） ----------------
    output wire         irq,
    output wire         o_job_active,   // 与 STATUS.busy 同义
    output wire         o_done_sticky,
    output wire         o_error_sticky,
    output wire [7:0]   o_error_code,
    output wire [31:0]  o_cycle_count,
    output wire         o_timeout_hit,
    output wire         o_fc_phase,
    output wire [31:0]  o_start_count,
    output wire [31:0]  o_reject_count,

    // ---------------- 结果 RAM 只读调试镜像（**非功能接口**，H6） ----------------
    //   H6 裁决：结果 RAM 留在本层内部，`res_we/res_addr/res_data` 不作为
    //   `kws_soc_top` 的功能接口引出（避免"两处重复存结果"）。
    //   需要波形/ILA 时看这三根：写使能取**超时门控 + 越界门控之后**真正落盘的信号，
    //   所以它的次数与 `wr_cnt` / RAM 内容严格一一对应（不把被丢弃的写算进来）。
    output wire         dbg_res_we,
    output wire [15:0]  dbg_res_addr,
    output wire signed [7:0] dbg_res_data
);
    // ------------------------------------------------------------------
    // 存储：两块 RAM 已抽成**独立模块**（2026-10-25 第三步改造）
    // ------------------------------------------------------------------
    // 为什么必须抽出去（而不是留在本文件里）：ADS 只在"一个 RAM 一个 always_ff、
    // 读写都在里面、地址/数据/使能都是端口或纯切片"的形态下才会打印
    //      `I: Sdm-0001: Found Ram <name>, depth=..., width=...`
    // 并据此推成 DRM；留在本文件里（读口分散、写数据/使能是这里算出来的表达式、
    // 读地址被钳过位）时，compile 日志里**一条 `Found Ram` 都没有** ⇒ 按普通触发器
    // 处理 ⇒ `DFF-inference` 30+ 分钟不收敛（内存恒定 ~500 MB 是它的指纹）。
    // 证据与坑位见 `rtl/soc/kws_in_w_ram.sv` 头注、`docs/specs/K5_BUFFER_RAM_STYLE.md`。
    //
    // 深度：`in_w` 补到 **512 字**（2^9，有效仍是 490 字）⇒ 三路读地址都是纯位切片
    // `addr[10:2]`，不再需要 `cond ? 切片 : 0` 的钳位 mux；`res_w` 恰好 1024 字（2^10）。
    localparam integer IN_WORDS   = 512;
    localparam integer RES_WORDS  = 1024;
    localparam integer IN_AW      = 9;
    localparam integer RES_AW     = 10;
`ifdef NEGCTL_MAP_ZERO
    // 负控 3：0x800 错映射到 RAM 偏移 0（D2 判据必须变红）。
    //   ⚠️ 只改**传给 RAM 模块的地址**，不进模块内部（模块要保持与探针同形）。
    localparam integer LOGIT_WIDX = 0;
`else
    localparam integer LOGIT_WIDX = LOGIT_OFF / 4;
`endif

    logic [INPUT_BYTES-1:0] dirty;

    // ------------------------------------------------------------------
    // 寄存器
    // ------------------------------------------------------------------
    logic        job_active;
    logic        done_q, err_q, irq_q;
    logic [7:0]  code_q;
    logic [31:0] cycle_cnt, tmo_cnt, tmo_reg;
    logic        cyc_ovf, timeout_hit;
    logic [31:0] wr_cnt;
    logic [31:0] start_cnt, reject_cnt;
    // A10 候选：硬件 JOB_SEQ（JOB_SEQ_EN=1 时才对 0x020 可见）
    logic [31:0] job_seq_q;
    logic        irq_en;

    // Tier-2 急停寄存器/影子
    logic [31:0] estop_window_shadow;
    logic [31:0] estop_window_eff;
    logic        estop_arm_q;
    wire         estop_trip_i;
    wire [31:0]  estop_elapsed;
    wire         estop_hb;
    wire [31:0]  estop_cnt;

    // 核的握手与写口
    logic        core_start, core_busy, core_done, core_error;
    logic [7:0]  core_code;
    wire         core_res_we;
    wire [15:0]  core_res_addr;
    wire signed [7:0] core_res_data;

    // in_w/res_w 是本层内部存储 ⇒ 它们的 1 拍读延迟由本层提供（见 §CORE_READ）；
    // 四组外部存储口（w/bias/quant）的 1 拍由外部 BRAM 提供，本层直通。
    wire signed [7:0]   in_q_r;     // reg → wire：那 1 拍由"字/sel 同沿寄存"承担
    wire [15:0] in_y, in_x, vec_idx;

    wire [15:0] dw_w_idx_w;
    wire [31:0] fc_w_idx_w;
    wire [15:0] bias_idx_w;
    wire [15:0] quant_idx_w;
    assign dw_w_idx  = dw_w_idx_w;
    assign fc_w_idx  = fc_w_idx_w;
    assign bias_idx  = bias_idx_w;
    assign quant_idx = quant_idx_w;

    wire signed [7:0] model_dw_w_q, model_fc_w_q;
    wire signed [31:0] model_bias_q, model_quant_mult, model_quant_shift;
    wire [15:0] model_dw_ih, model_dw_iw, model_dw_oh, model_dw_ow;
    wire [15:0] model_dw_kh, model_dw_kw, model_dw_sh, model_dw_sw;
    wire [15:0] model_dw_pt, model_dw_pl, model_dw_cout, model_fc_nin, model_fc_nout;
    wire signed [31:0] model_in_zp, model_dw_out_zp, model_fc_out_zp;
    wire signed [31:0] model_act_min, model_act_max;
    wire [15:0] cfg_dw_ih = MODEL_ROM_ENABLE ? model_dw_ih : dw_ih;
    wire [15:0] cfg_dw_iw = MODEL_ROM_ENABLE ? model_dw_iw : dw_iw;
    wire [15:0] cfg_dw_oh = MODEL_ROM_ENABLE ? model_dw_oh : dw_oh;
    wire [15:0] cfg_dw_ow = MODEL_ROM_ENABLE ? model_dw_ow : dw_ow;
    wire [15:0] cfg_dw_kh = MODEL_ROM_ENABLE ? model_dw_kh : dw_kh;
    wire [15:0] cfg_dw_kw = MODEL_ROM_ENABLE ? model_dw_kw : dw_kw;
    wire [15:0] cfg_dw_sh = MODEL_ROM_ENABLE ? model_dw_sh : dw_sh;
    wire [15:0] cfg_dw_sw = MODEL_ROM_ENABLE ? model_dw_sw : dw_sw;
    wire [15:0] cfg_dw_pt = MODEL_ROM_ENABLE ? model_dw_pt : dw_pt;
    wire [15:0] cfg_dw_pl = MODEL_ROM_ENABLE ? model_dw_pl : dw_pl;
    wire [15:0] cfg_dw_cout = MODEL_ROM_ENABLE ? model_dw_cout : dw_cout;
    wire [15:0] cfg_fc_nin = MODEL_ROM_ENABLE ? model_fc_nin : fc_nin;
    wire [15:0] cfg_fc_nout = MODEL_ROM_ENABLE ? model_fc_nout : fc_nout;
    wire signed [31:0] cfg_in_zp = MODEL_ROM_ENABLE ? model_in_zp : in_zp;
    wire signed [31:0] cfg_dw_out_zp = MODEL_ROM_ENABLE ? model_dw_out_zp : dw_out_zp;
    wire signed [31:0] cfg_fc_out_zp = MODEL_ROM_ENABLE ? model_fc_out_zp : fc_out_zp;
    wire signed [31:0] cfg_act_min = MODEL_ROM_ENABLE ? model_act_min : act_min;
    wire signed [31:0] cfg_act_max = MODEL_ROM_ENABLE ? model_act_max : act_max;
    wire signed [7:0] cfg_dw_w_q = MODEL_ROM_ENABLE ? model_dw_w_q : w_q;
    wire signed [7:0] cfg_fc_w_q = MODEL_ROM_ENABLE ? model_fc_w_q : w_q;
    wire signed [31:0] cfg_bias_q = MODEL_ROM_ENABLE ? model_bias_q : bias_q;
    wire signed [31:0] cfg_quant_mult = MODEL_ROM_ENABLE ? model_quant_mult : quant_mult;
    wire signed [31:0] cfg_quant_shift = MODEL_ROM_ENABLE ? model_quant_shift : quant_shift;

    kws_model_rom u_model_rom (
        .clk(clk), .dw_w_idx(dw_w_idx_w), .fc_w_idx(fc_w_idx_w),
        .bias_idx(bias_idx_w), .quant_idx(quant_idx_w),
        .dw_w_q(model_dw_w_q), .fc_w_q(model_fc_w_q),
        .bias_q(model_bias_q), .quant_mult(model_quant_mult), .quant_shift(model_quant_shift),
        .dw_ih(model_dw_ih), .dw_iw(model_dw_iw), .dw_oh(model_dw_oh), .dw_ow(model_dw_ow),
        .dw_kh(model_dw_kh), .dw_kw(model_dw_kw), .dw_sh(model_dw_sh), .dw_sw(model_dw_sw),
        .dw_pt(model_dw_pt), .dw_pl(model_dw_pl), .dw_cout(model_dw_cout),
        .in_zp(model_in_zp), .dw_out_zp(model_dw_out_zp),
        .fc_nin(model_fc_nin), .fc_nout(model_fc_nout),
        .fc_out_zp(model_fc_out_zp), .act_min(model_act_min), .act_max(model_act_max)
    );

    // ------------------------------------------------------------------
    // §PHASE  核不输出 layer phase（缺口 G1）⇒ 用 DW 写次数推断
    // ------------------------------------------------------------------
`ifdef NEGCTL_DWOH_SYM
    wire [15:0] dw_oh_x = (cfg_dw_ih + cfg_dw_pt - cfg_dw_kh) / cfg_dw_sh + 16'd1;
    wire [15:0] dw_ow_x = (cfg_dw_iw + cfg_dw_pl - cfg_dw_kw) / cfg_dw_sw + 16'd1;
`else
    wire [15:0] dw_oh_x = cfg_dw_oh;
    wire [15:0] dw_ow_x = cfg_dw_ow;
`endif
    wire [31:0] dw_out_elems = {16'd0, dw_oh_x} * {16'd0, dw_ow_x} * {16'd0, cfg_dw_cout};
    localparam [11:0] LOGIT_OFF12 = LOGIT_OFF;

    assign o_job_active    = job_active;
    assign o_done_sticky   = done_q;
    assign o_error_sticky  = err_q;
    assign o_error_code    = code_q;
    assign o_cycle_count   = cycle_cnt;
    assign o_timeout_hit   = timeout_hit;
    assign o_start_count   = start_cnt;
    assign o_reject_count  = reject_cnt;
    assign irq             = irq_q & irq_en;

    // FC 阶段：DW 结果写满 oh*ow*cout 之后
    wire fc_phase = (wr_cnt >= dw_out_elems);
    assign o_fc_phase = fc_phase;

    // ------------------------------------------------------------------
    // §CORE_READ：核输入读口的**说明**
    //   注意：FC 的输入是上层的 requant 输出，必须从 res_w 读（1R+1W，D3）。
    //   ★ 1 拍约束：RAM 模块内部把"字"与"字节选择位"在**同一沿**寄存，字节 mux 在
    //     寄存器之后**组合**完成 ⇒ 地址 t 拍给、in_q 在 t+1 拍有效（与改造前等价）。
    //     这里只做"寄存后的 ok 标志"选择，**不再多打一拍**。
    // ------------------------------------------------------------------

    // ⚠️ 四组存储口**不在这里寄存**（D3：「直连同步 BRAM，固定 1 拍读延迟，
    //    不插仲裁或额外寄存级」）。1 拍延迟由**外部 BRAM**负责。
    //    本层若再寄存一次，核看到的就是 2 拍 ⇒ 权重错位。

    // ------------------------------------------------------------------
    // 加速器核
    // ------------------------------------------------------------------
    openeye_top u_core (
        .clk(clk), .rst(rst),
        .start(core_start), .busy(core_busy), .done(core_done),
        .error(core_error), .error_code(core_code),
        .dw_ih(cfg_dw_ih), .dw_iw(cfg_dw_iw), .dw_oh(dw_oh_x), .dw_ow(dw_ow_x),
        .dw_kh(cfg_dw_kh[7:0]), .dw_kw(cfg_dw_kw[7:0]),
        .dw_sh(cfg_dw_sh[7:0]), .dw_sw(cfg_dw_sw[7:0]),
        .dw_pt(cfg_dw_pt[7:0]), .dw_pl(cfg_dw_pl[7:0]),
        .dw_cout(cfg_dw_cout[7:0]),
        .in_zp(cfg_in_zp), .dw_out_zp(cfg_dw_out_zp),
        .fc_nin(cfg_fc_nin), .fc_nout(cfg_fc_nout), .fc_out_zp(cfg_fc_out_zp),
        .act_min(cfg_act_min), .act_max(cfg_act_max),
        .in_y(in_y), .in_x(in_x), .vec_idx(vec_idx), .in_q(in_q_r),
        .dw_w_idx(dw_w_idx_w), .fc_w_idx(fc_w_idx_w),
        .w_q(fc_phase ? cfg_fc_w_q : cfg_dw_w_q),
        .bias_idx(bias_idx_w), .bias_q(cfg_bias_q),
        .quant_idx(quant_idx_w), .quant_mult(cfg_quant_mult), .quant_shift(cfg_quant_shift),
        .res_we(core_res_we), .res_addr(core_res_addr), .res_data(core_res_data)
    );

`ifdef NEGCTL_GATE_OFF
    // 负控 2：不门控 res_we ⇒ 超时后结果 RAM 仍被改写，判据必须变红
    wire res_wr_en = core_res_we;
`else
    wire res_wr_en = core_res_we & ~timeout_hit;
`endif

    // 核的结果写是**单字节**（res_addr 是字节地址、res_data 是 int8）⇒ 转成
    // "同一 word 地址 + 4 个字节使能"，与 E1 探针同形态（单写口，可推 BRAM）。
    wire [RES_AW-1:0] core_res_widx = core_res_addr[RES_AW+1:2];
    wire [1:0]        core_res_lane = core_res_addr[1:0];

    // ------------------------------------------------------------------
    // CRC32（ISO-HDLC，反射 poly 0xEDB88320）——**时序引擎**（2026-10-25 落库）
    // ------------------------------------------------------------------
    // 历史写法：`function crc32_buf()` 把 1,960 字节 × 8 位**组合展开**
    //   ⇒ 15,680 级串行异或链。仿真能跑，综合不可接受（2026-10-24 实测：
    //   yosys 解析本文件 > 6 分钟无进展；PDS 侧面积与编译内存同样爆）。
    //   当时只能靠 `-DSYNTH_NO_CRC` 把该寄存器读成常数绕过 —— 那是面积估算，
    //   不代表功能正确。
    //
    // 现在改成**后台一遍扫描**（改法源自 2026-10-24 的 kws-mdu-port 工作树草案，
    //   ｜本轮回落到本分支并补 TB 验证）：
    //   · `crc_byte_step()` 每拍只展开 8 级（≈16 门深），1,961 拍收敛；
    //   · 任何一次 buffer 写都把 `crc_valid` 清 0、从字节 0 重走一遍
    //     ⇒ **与写顺序无关**（`tb_kws_mmio_min` 的 `push_pat_reverse` 仍然成立）；
    //   · 正常流程（写满 1,960 B → START → 352,020 拍 job → DONE → 读 0x040）：
    //     CRC 在 START 后 1,961 拍即收敛 ⇒ **读 0x040 仍然 1 拍返回**，
    //     与旧实现同一条接口时序（不新增等待）；
    //   · 唯一新增的接口行为是**兜底反压**：写完 buffer 后"立刻"读 0x040 时
    //     若引擎尚未收敛，`req_ready=0` 挂起该次读，收敛后一次性给出真值，
    //     绝不返回半成品（宁可多等 1,961 拍，不可静默错数）；
    //   · 代价：`in_ram` 多一个同步读口（1R1W → 2R1W，1960×8 ≈ 2 KB ⇒ +1 DRAM），
    //     远低于"不可综合"的代价。
    function automatic [31:0] crc_byte_step(input [31:0] c, input [7:0] b);
        integer k;
        reg [31:0] x;
        begin
            x = c ^ {24'd0, b};
            for (k = 0; k < 8; k = k + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB8_8320) : (x >> 1);
            crc_byte_step = x;
        end
    endfunction

    wire dirty_full = &dirty;
    wire idle       = ~job_active;

    // 地址解码
    wire        is_buf   = addr[12];
    wire [11:0] off      = addr[11:0];
    wire        is_reg   = ~is_buf;
    // 窗口偏移 0x800 ↔ RAM 字节偏移 LOGIT_OFF(4000)：**两者不是同一个数**
    //   ⚠️ 坑位：这里曾把 LOGIT_OFF 直接当窗口偏移比较，导致 0x800 被当成 4000
    //   而判越界 ⇒ 读 logits 恒 error。D2 的判据就是"0x800 必须落到 RAM 偏移 4000"，
    //   写错时不会崩，只会静默返回一次 bus error（见 K6-M S5 的负控）。
    localparam [11:0] WIN_LOGIT_OFF = 12'h800;
    wire        rd_logit = is_buf && !write && (off >= WIN_LOGIT_OFF) &&
                           (off < WIN_LOGIT_OFF + 12'd4);
    wire        logit_ok = done_q & ~err_q & ~job_active;

    // ------------------------------------------------------------------
    // Tier-2 急停：HB 脉冲 + WINDOW 影子/上升沿锁存 + watchdog
    // ------------------------------------------------------------------
    assign estop_trip = estop_trip_i;
    assign estop_cnt  = estop_trip_i ? 32'd0 :
                        (!estop_arm ? estop_window_eff :
                         ((estop_elapsed >= estop_window_eff) ? 32'd0
                          : (estop_window_eff - estop_elapsed)));
    // HB 只在 armed、未 trip 且 32-bit 写时产生 1 拍脉冲；watchdog 内部再判 arm/trip
`ifdef NEGCTL_ESTOP_HB_OFFBYTE
    wire estop_hb_hit = (off == 12'h04D);   // 负控：地址错一位，喂狗必须失效
`else
    wire estop_hb_hit = (off == 12'h04C);
`endif
    assign estop_hb = req_valid && req_ready && is_reg && write &&
                      estop_hb_hit && (wstrb == 4'hF) &&
                      estop_arm && !estop_trip_i;

    kws_estop_watchdog #(
        .WINDOW_CYC_DEFAULT(ESTOP_WINDOW_DEFAULT)
    ) u_estop (
        .clk        (clk),
        .rst        (rst),
        .por        (estop_por),
        .heartbeat  (estop_hb),
        .arm        (estop_arm),
        .window_cfg (estop_window_eff),
        .trip       (estop_trip_i),
        .trip_code  (),
        .trip_cnt   (),
        .hb_cnt     (),
        .elapsed    (estop_elapsed)
    );

    // WINDOW 影子：仅 por 初始化；仅 arm=0 && trip=0 且 32-bit 写时更新；
    // arm 上升沿锁存为有效窗口（0 → 默认 1,350,000）。
    always_ff @(posedge clk) begin
        if (estop_por) begin
            estop_window_shadow <= 32'd0;
            estop_window_eff    <= ESTOP_WINDOW_DEFAULT;
            estop_arm_q         <= 1'b0;
        end else begin
            estop_arm_q <= estop_arm;
            if (estop_arm && !estop_arm_q)
                estop_window_eff <= (estop_window_shadow == 32'd0)
                                    ? ESTOP_WINDOW_DEFAULT : estop_window_shadow;
            if (req_valid && req_ready && is_reg && write &&
                (off == 12'h050) && (wstrb == 4'hF) &&
                !estop_arm && !estop_trip_i)
                estop_window_shadow <= wdata;
        end
    end

    // ------------------------------------------------------------------
    // CRC 后台引擎（见上 §CRC32 的改法说明）
    //   crc_idx 是**送给 RAM 的地址**，crc_rd_q 是它 1 拍后的数据；
    //   于是"消费第 crc_idx-1 字节"与"地址推进"同拍，全程 1 字节/拍。
    //   ⚠️ 判据/引擎变量一律声明在使用之前（隐式 net 会让比较恒假且不报错）。
    // ------------------------------------------------------------------
    // crc_idx 至少要比"字索引"宽 2 位，否则小几何下 crc_idx[IN_AW+1:2] 越界
    localparam integer CRC_IDX_W = ($clog2(INPUT_BYTES + 1) > (IN_AW + 2))
                                   ? $clog2(INPUT_BYTES + 1) : (IN_AW + 2);
    logic [CRC_IDX_W-1:0] crc_idx;
    logic [31:0]          crc_acc;
    wire  [7:0]           crc_rd_q;
    logic                 crc_run;
    logic                 crc_valid;
    logic [31:0]          crc_hold;

    // in_w 的第二个读口（专用；不占用核的 in_q 通路）
    //   时序与旧实现**逐位一致**：crc_rd_q(t+1) 对应 crc_idx(t)。
    //   ⇒ 字、字节选择、在界标志三者同沿寄存，crc_rd_q 由它们组合选出。
    //   ⚠️ 读口已在独立 RAM 模块里（见 §RAM_READ）；本层只声明地址切片与 ok 标志。


    // ------------------------------------------------------------------
    // buffer 写通路：字节使能 + 跨字 fail-closed（**全部组合，无额外时序**）
    // ------------------------------------------------------------------
    // wr_be  = 真正会被写的字节（wstrb ∩ 在界内）；
    // wr_oob = 有字节使能但越界 ⇒ 总线 error（越界字节不写，其余照旧写，保持原语义）；
    // wr_xword = 使能字节**跨了两个 word**（off 的字节内偏移 + 最高使能位 > 3）
    //   ⇒ fail-closed：整笔拒绝、error、存储与 dirty 都不动。
    // ⚠️ 声明顺序：wr_be/wr_span 必须在 wr_xword **之前**（AGENTS §7.19：先用后声明
    //   会造出隐式 1 位网，比较恒假且不报错）。
    wire [31:0] off32  = {20'd0, off};
    wire [3:0]  wr_be  = { wstrb[3] & ((off32 + 32'd3) < INPUT_BYTES),
                           wstrb[2] & ((off32 + 32'd2) < INPUT_BYTES),
                           wstrb[1] & ((off32 + 32'd1) < INPUT_BYTES),
                           wstrb[0] & ((off32 + 32'd0) < INPUT_BYTES) };
    wire        wr_oob = ((wstrb & ~wr_be) != 4'd0);
    wire [1:0]  wr_hi  = wr_be[3] ? 2'd3 : wr_be[2] ? 2'd2 : wr_be[1] ? 2'd1 : 2'd0;
    wire [3:0]  wr_span = {2'b00, off[1:0]} + {2'b00, wr_hi};
    wire [IN_AW-1:0] wr_widx = off[IN_AW+1:2];

    // 字节 lane 对齐（**字存储的关键一步**）：
    //   wstrb[j] 对应字节地址 `off+j`，而字内 lane 是 `off[1:0]+j`（不是 j！）。
    //   所以先把"使能"和"数据"整体左移 off[1:0] 个字节，再按**固定 lane** 写。
    //   ⚠️ 坑位：直接写 `in_w[wr_widx][8*j +: 8] <= wdata[8*j +: 8]` 会把字节写到
    //   错误的 lane 上（off=2 的 sh 会落到字节 0/1 而不是 2/3）；C17b 就是抓这个的。
    //   移位必须是**常量 lane 的条件写**（而不是变量 part-select），否则 ADS 认不出
    //   字节使能、又会退回触发器。
    wire [31:0] wr_data_lane = wdata << (8 * off[1:0]);
    wire [3:0]  wr_be_word   = wr_be << off[1:0];
`ifdef NEGCTL_XWORD_ACCEPT
    // 负控 5：接受跨字写（按"低 2 位截断进本 word"静默处理）⇒ C17 必须变红。
    //   这条突变证明 C17 的跨字判据**确实在起作用**，不是恒真。
    wire wr_xword = 1'b0;
`else
    wire wr_xword = (wr_be != 4'd0) && (wr_span > 4'd3);
`endif

    // ------------------------------------------------------------------
    // §RAM_WRITE  两块 RAM 的写口**信号**（RAM 本体在独立模块里，见 §RAM_READ）
    // ------------------------------------------------------------------
    // 本层只负责算出"写哪个 word、写哪几个字节、写什么数据"，写动作在模块内的
    // 唯一 `always_ff` 里完成（与 rambe_probe 同形）。
    //   · in_w：地址 `wr_widx`、使能 `wr_be_word`、数据 `wr_data_lane`；
    //   · res_w：地址 `res_wr_addr`、使能 `res_be`（单字节地址 → 4 位 one-hot）、数据 = `core_res_data`。
    wire in_wr_en = req_valid && req_ready && is_buf && write && !wr_xword;

    wire [RES_AW-1:0] res_wr_addr = core_res_widx;
    wire [3:0]        res_be      = 4'b0001 << core_res_lane;
    wire              res_wr_fire = res_wr_en && (core_res_addr < RES_BYTES);

    // H6 调试镜像（声明必须在 res_wr_fire/res_wr_en 之后 —— AGENTS §7.19）：
    //   观察点 = 真正写进 RAM 的那一拍（含超时门控），与 RAM 内容同源。
    assign dbg_res_we   = res_wr_fire;
    assign dbg_res_addr = core_res_addr;
    assign dbg_res_data = core_res_data;

    // `crc_rd_q` 的 assign 在 §RAM_READ（要用到那里的 in_b_crc 与 crc_ok_q）。

    wire buf_wr_fire   = req_valid && req_ready && is_buf && write;
    wire crc_read_fire = req_valid && req_ready && ~is_buf && ~write && (off == 12'h040);
    wire crc_block     = crc_read_fire && ~crc_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            crc_idx   <= {CRC_IDX_W{1'b0}};
            crc_acc   <= 32'hFFFF_FFFF;
            crc_run   <= 1'b1;
            crc_valid <= 1'b0;
            crc_hold  <= 32'hFFFF_FFFF;
        end else if (buf_wr_fire) begin
            // 写了一次就作废重来：与写顺序无关，倒序写同样正确
            crc_idx   <= {CRC_IDX_W{1'b0}};
            crc_acc   <= 32'hFFFF_FFFF;
            crc_run   <= 1'b1;
            crc_valid <= 1'b0;
        end else if (crc_run) begin
            if (crc_idx >= INPUT_BYTES) begin
                // 最后一个字节（crc_rd_q = in_ram[INPUT_BYTES-1]）已消费
                crc_hold  <= ~crc_byte_step(crc_acc, crc_rd_q);
                crc_valid <= 1'b1;
                crc_run   <= 1'b0;
            end else if (crc_idx != {CRC_IDX_W{1'b0}}) begin
                crc_acc <= crc_byte_step(crc_acc, crc_rd_q);
            end
            if (crc_idx < INPUT_BYTES) crc_idx <= crc_idx + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // §RAM_READ  两块 RAM 的读口接线（**RAM 本体在独立模块里**，这里只给地址和 ok 标志）
    // ------------------------------------------------------------------
    // ★ 为什么抽成模块：ADS 的 RAM 推断只在"一个 RAM 一个 always_ff、读写都在里面、
    //   地址/数据/使能都是端口或纯切片"的形态下成立（`I: Sdm-0001: Found Ram ...`）。
    //   留在本文件里（读口分散、写数据/使能是本层算出来的表达式、读地址被钳过位）时
    //   compile 日志里**一条 `Found Ram` 都没有** ⇒ 按普通触发器处理 ⇒
    //   `DFF-inference` 30+ 分钟不收敛。证据见 rtl/soc/kws_in_w_ram.sv 头注。
    //
    // 地址：`in_w` 补到 512 字（2^9）⇒ 三路读地址都是**纯位切片**，不再需要钳位 mux；
    //       `res_w` 恰好 1024 字（2^10）。越界读的"给 0 / 给 in_zp"由下面**寄存后的**
    //       `*_ok_q` 选择，不进入 RAM 模块。
    wire [31:0] in_flat = in_y * cfg_dw_iw + in_x;
    wire        dw_ok   = (in_flat < INPUT_BYTES);
    wire        fc_ok   = (vec_idx < RES_BYTES);
    wire        crc_ok  = (crc_idx < INPUT_BYTES);

    wire [IN_AW-1:0]  dw_widx    = in_flat[IN_AW+1:2];
    wire [RES_AW-1:0] fc_widx    = vec_idx[RES_AW+1:2];
    wire [IN_AW-1:0]  bus_in_widx = off[IN_AW+1:2];
    wire [IN_AW-1:0]  crc_widx    = crc_idx[IN_AW+1:2];

    // 只有"越界/相位"这类**非存储**信息需要在本层寄存
    logic        dw_ok_q, fc_ok_q, fc_phase_q, crc_ok_q;
    logic signed [7:0] in_zp_q;
    always_ff @(posedge clk) begin
        dw_ok_q    <= dw_ok;
        fc_ok_q    <= fc_ok;
        fc_phase_q <= fc_phase;
        crc_ok_q   <= crc_ok;
        in_zp_q    <= $signed(cfg_in_zp[7:0]);
    end

    // (1) in_w：1 写 3 读（核像素 / CRC / 总线 buffer）。读口传**字节地址**。
    wire [7:0] in_b_dw, in_b_crc, in_b_bus;
    kws_in_w_ram #(.WORDS(IN_WORDS), .AW(IN_AW)) u_in_w (
        .clk(clk),
        .we(in_wr_en), .waddr(wr_widx), .wbe(wr_be_word), .wdata(wr_data_lane),
        .ra0(in_flat[IN_AW+1:0]), .ra1(crc_idx[IN_AW+1:0]), .ra2(off[IN_AW+1:0]),
        .b0(in_b_dw), .b1(in_b_crc), .b2(in_b_bus)
    );
    wire [7:0] bus_in_byte = in_b_bus;
    assign crc_rd_q = crc_ok_q ? in_b_crc : 8'd0;

    // (2) res_w：1 写 2 读（FC 激活字节 / 总线 logit 整字）。读口传**字节地址**。
    //     logit 的地址 = `LOGIT_OFF`（4000，4 的倍数）⇒ 模块内取字 1000、整字输出。
    // ⚠️ 负控 3（NEGCTL_MAP_ZERO）必须继续生效：它把 LOGIT_WIDX 置 0 ⇒ 这里算出的
    //    字节地址也是 0，于是 0x800 读到的是 RAM 偏移 0 的内容（C11 必红）。
    localparam [RES_AW+1:0] LOGIT_BADDR = LOGIT_WIDX * 4;
    wire [7:0]  res_b_fc;
    wire [31:0] logit_word_q;
    kws_res_w_ram #(.WORDS(RES_WORDS), .AW(RES_AW)) u_res_w (
        .clk(clk),
        .we(res_wr_fire), .waddr(res_wr_addr), .wbe(res_be), .wdata(core_res_data),
        .ra0(vec_idx[RES_AW+1:0]), .ra1(LOGIT_BADDR),
        .b0(res_b_fc), .q1(logit_word_q)
    );

    // 核的 in_q：地址 t 拍给、t+1 拍有效（1 拍由 RAM 模块内部"字/sel 同沿寄存"承担）
    assign in_q_r = fc_phase_q ? (fc_ok_q ? $signed(res_b_fc) : 8'sd0)
                              : (dw_ok_q ? $signed(in_b_dw) : in_zp_q);
    // ------------------------------------------------------------------
    // 读写主逻辑（单拍请求 → 次拍响应）
    // ------------------------------------------------------------------
    logic       rsp_valid_q;
    logic [31:0] rsp_data_q;
    logic       rsp_err_q;
    // 这两拍标志表示"本次响应的数据不走 rsp_data_q，而由上面两个读口的组合输出给出"
    //   —— 因为 RAM 读延迟已经是 1 拍，再经 rsp_data_q 就变 2 拍（A5/A8 的 1 拍契约）。
    logic       rsp_is_logit_q, rsp_is_bufbyte_q;
    // CRC 未收敛时挂起该次读：期间 req_ready=0（不放行新请求），也不给半成品。
    // 正常流程下恒为 0 ⇒ req_ready 恒 1，与旧实现逐位一致。
    logic       crc_wait;
    assign req_ready = ~crc_wait;
    assign rsp_valid = rsp_valid_q;
    assign rdata     = rsp_is_logit_q   ? logit_word_q
                     : rsp_is_bufbyte_q ? {24'd0, bus_in_byte}
                     :                    rsp_data_q;
    assign error     = rsp_err_q;
    integer j;
    always_ff @(posedge clk) begin
        if (rst) begin
            job_active  <= 1'b0;
            done_q      <= 1'b0;
            err_q       <= 1'b0;
            irq_q       <= 1'b0;
            irq_en      <= 1'b0;
            code_q      <= 8'd0;
            cycle_cnt   <= 32'd0;
            tmo_cnt     <= 32'd0;
            tmo_reg     <= TIMEOUT_DEFAULT;
            cyc_ovf     <= 1'b0;
            timeout_hit <= 1'b0;
            wr_cnt      <= 32'd0;
            core_start  <= 1'b0;
            start_cnt   <= 32'd0;
            reject_cnt  <= 32'd0;
            job_seq_q   <= 32'd0;
            dirty       <= {INPUT_BYTES{1'b0}};
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 32'd0;
            rsp_err_q   <= 1'b0;
            rsp_is_logit_q   <= 1'b0;
            rsp_is_bufbyte_q <= 1'b0;
            crc_wait    <= 1'b0;
            // RAM 的零初值不在这里：见 §RAM_WRITE 的 `initial`。
            //   （曾经的写法是 `if (rst) for(...) in_w[j] <= 0`，那会把复位条件折进
            //    每条字节写的地址、让 ADS 判多写口 —— 坑位说明见 §RAM_WRITE。）
        end else begin
            core_start  <= 1'b0;       // 默认：只发 1 拍
            rsp_valid_q <= 1'b0;
            rsp_err_q   <= 1'b0;
            rsp_data_q  <= 32'd0;
            rsp_is_logit_q   <= 1'b0;
            rsp_is_bufbyte_q <= 1'b0;

            // ---- 结果写口的**计数**（实际写入在 §RAM_WRITE 的独立 always_ff）----
            if (res_wr_en && (core_res_addr < RES_BYTES)) begin
                if (!timeout_hit) wr_cnt <= wr_cnt + 32'd1;
            end

            // ---- 终态收集 ----
`ifdef NEGCTL_NO_DONE_LATCH
            // 负控 1：不锁存 done ⇒ CPU 读不到 DONE（A3 的判据必须变红）
            if (1'b0 && core_done && !err_q) begin
`else
            if (core_done && !err_q) begin
`endif
                done_q <= 1'b1;
                irq_q  <= 1'b1;
            end
            if (core_error && !err_q) begin
                err_q  <= 1'b1;
                code_q <= core_code;
                irq_q  <= 1'b1;
            end

            // ---- 计时 / 超时 ----
            if (job_active) begin
                if (cycle_cnt != 32'hFFFF_FFFF) cycle_cnt <= cycle_cnt + 32'd1;
                else                            cyc_ovf  <= 1'b1;

                if (!timeout_hit) begin
                    if (tmo_cnt + 32'd1 >= tmo_reg) begin
                        timeout_hit <= 1'b1;
                        err_q       <= 1'b1;
                        code_q      <= 8'd3;      // WATCHDOG / TIMEOUT（值 3 唯一）
                        irq_q       <= 1'b1;
                    end else begin
                        tmo_cnt <= tmo_cnt + 32'd1;
                    end
                end
            end

            // ---- job 结束：核已回 idle 且已终态 ----
            //  ⚠️ 必须把 core_done/core_error 也算进来：核在 L_DONE/L_ERR 是
            //     `busy<=0` 与 `done<=1` **同拍**（openeye_top.sv L_DONE 分支），
            //     若只看寄存后的 done_q，busy 会比 done 晚 2 拍才落 0 ⇒
            //     上层在 done=1 后立刻 START 会被"忙"拒掉一次。真实几何台 R1 抓到过。
            if (job_active && !core_busy &&
                (done_q || err_q || core_done || core_error)) job_active <= 1'b0;

            // ---- 总线事务 ----
            // CRC 未收敛的读：先握手再挂起（crc_wait=1 ⇒ req_ready=0），
            //   收敛那拍由下面的"完成分支"补出响应；不吞请求、不给半成品。
            if (crc_block) begin
                crc_wait <= 1'b1;
            end else if (req_valid && req_ready) begin
                rsp_valid_q <= 1'b1;

                if (is_buf) begin
                    // ---------------- buffer / 结果窗 ----------------
                    if (!write) begin
                        if (rd_logit) begin
                            if (logit_ok) begin
                                // 数据由 res_w 的常量地址读口在**次拍**组合给出（1 拍）
                                rsp_is_logit_q <= 1'b1;
                            end else
                                rsp_err_q <= 1'b1;   // A7：运行中/出错后不可读
                        end else if (off < INPUT_BYTES) begin
                            // 数据由 in_w 的 buffer 读口在**次拍**组合给出（1 拍）
                            rsp_is_bufbyte_q <= 1'b1;
                        end else begin
                            rsp_err_q <= 1'b1;
                        end
                    end else begin
                        // ---- 字节使能写：**数据面在 §RAM_WRITE 的独立 always_ff** ----
                        // 这里只做总线语义（error）与 dirty 记账。
                        // 跨字写：fail-closed ⇒ 总线 error，且**存储与 dirty 都不动**
                        //   （软件只会发对齐 sw / 单 bit sb / 对齐 sh；这条把"不支持
                        //    跨字"从隐含假设变成可审计事实，负控 NEGCTL_XWORD_ACCEPT 反证）
                        if (wr_xword) begin
                            rsp_err_q <= 1'b1;
                        end else begin
                            if (wr_oob) rsp_err_q <= 1'b1;   // 越界字节不写，其余照写
                            for (j = 0; j < 4; j = j + 1) begin
                                if (wr_be[j]) dirty[off+j] <= 1'b1;
                            end
                        end
                    end
                end else begin
                    // ---------------- 控制窗 ----------------
                    case (off)
                        12'h000: rsp_data_q <= ID_VALUE;
                        12'h004: begin
                            if (write && wdata[0]) begin
                                if (idle && dirty_full) begin
                                    // 接受：清终态、清 dirty、发 1 拍 start
                                    done_q      <= 1'b0;
                                    err_q       <= 1'b0;
                                    irq_q       <= 1'b0;
                                    code_q      <= 8'd0;
                                    cycle_cnt   <= 32'd0;
                                    tmo_cnt     <= 32'd0;
                                    cyc_ovf     <= 1'b0;
                                    timeout_hit <= 1'b0;
                                    wr_cnt      <= 32'd0;
                                    dirty       <= {INPUT_BYTES{1'b0}};
                                    core_start  <= 1'b1;
                                    job_active  <= 1'b1;
                                    start_cnt   <= start_cnt + 32'd1;
                                    // A10 候选：只在该 START **被接受**时递增；
                                    //   busy/未写全被拒的那次不得改动序号（否则固件比对必错）。
                                    //   JOB_SEQ_EN=0 时整段被常量折叠掉，不产生任何逻辑。
                                    if (JOB_SEQ_EN != 0) job_seq_q <= job_seq_q + 32'd1;
                                end else begin
                                    rsp_err_q  <= 1'b1;   // A2：忙/未写全 → 总线 error，无副作用
                                    reject_cnt <= reject_cnt + 32'd1;
`ifdef NEGCTL_JOBSEQ_BUMP_ON_REJECT
                                    // 负控（只用于验证 C6d 有鉴别力）：被拒的 START 也 +1
                                    if (JOB_SEQ_EN != 0) job_seq_q <= job_seq_q + 32'd1;
`endif
                                end
                            end
                        end
                        12'h008: rsp_data_q <= {23'd0, estop_arm, code_q[3:0], cyc_ovf, err_q, done_q, job_active};
                        12'h00C: begin
                            if (write) begin
                                if (|wdata[31:1]) rsp_err_q <= 1'b1;
                                else              irq_en    <= wdata[0];
                            end else begin
                                rsp_data_q <= {31'd0, irq_en};
                            end
                        end
                        12'h010: begin
                            if (write && wdata[0]) irq_q <= 1'b0;  // 只清 pending
                        end
                        12'h014: rsp_data_q <= {24'd0, code_q};
                        12'h018: rsp_data_q <= INPUT_BYTES;
                        12'h01C: rsp_data_q <= cycle_cnt;
                        // A10 候选：JOB_SEQ@0x020（RO）。未启用时该地址保持"未分配"语义
                        //   = 读/写都返回 bus error，与 V1 逐位一致。
                        12'h020: begin
                            if (JOB_SEQ_EN != 0 && !write) rsp_data_q <= job_seq_q;
                            else                          rsp_err_q  <= 1'b1;
                        end
                        12'h040: rsp_data_q <= crc_hold;   // 后台引擎的保持寄存器（读时不再组合展开）
                        12'h044: rsp_data_q <= {31'd0, irq_q};
                        12'h048: begin
                            if (write) begin
                                if (job_active || (wdata == 32'd0)) rsp_err_q <= 1'b1;
                                else                                tmo_reg   <= wdata;
                            end else begin
                                rsp_data_q <= tmo_reg;
                            end
                        end
                        // ---- Tier-2 急停（ICR v1.0）----
                        12'h04C: begin
                            if (!write) rsp_data_q <= 32'd0;
                            else if (wstrb != 4'hF) rsp_err_q <= 1'b1;
                            // 32-bit 写即喂狗，由 estop_hb 组合脉冲完成；无寄存器副作用
                        end
                        12'h050: begin
                            if (write) begin
                                if ((wstrb != 4'hF) || estop_arm || estop_trip_i)
                                    rsp_err_q <= 1'b1;
                                // 合法写由上面的 shadow always_ff 落盘
                            end else begin
                                rsp_data_q <= estop_window_shadow;
                            end
                        end
                        12'h054: begin
                            if (write) rsp_err_q <= 1'b1;
                            else       rsp_data_q <= {31'd0, estop_trip_i};
                        end
                        12'h058: begin
                            if (write) rsp_err_q <= 1'b1;
                            else       rsp_data_q <= estop_cnt;
                        end
                        default: rsp_err_q <= 1'b1;
                    endcase
                end
            end

            // ---- CRC 挂起读的完成：引擎收敛的那一拍补出响应 ----
            if (crc_wait && crc_valid) begin
                crc_wait    <= 1'b0;
                rsp_valid_q <= 1'b1;
                rsp_data_q  <= crc_hold;
            end
        end
    end

endmodule

`default_nettype wire
