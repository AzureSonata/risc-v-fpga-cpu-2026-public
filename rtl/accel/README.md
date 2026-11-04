# rtl/accel

高阶应用加速；先完成资源与模型可行性实验。

本目录当前只有 **OpenEye K4 计算核心**（Draft，PR #69），**不含 MMIO / 控制窗 /
buffer 窗 / SoC 集成**。下面的端口表是随代码走的**接口约定（PROPOSED）**，不是已签署的
MMIO ABI；任何冻结仍须接口 owner 按 Issue #68 评审。

> **2026-10-21 变更摘要（F6 / F7 / F8，全部为「零端口变更」实现）**
> · F8 存储读口：组合读 → **1 拍延迟同步读**（DW/FC 加 2 拍取数流水、requant 改两级），
>   周期数 344,016 → **352,020**（实测），原 `3.44 ms/帧 @100 MHz` 作废，见 §2.2。
> · F7 结果写口：加**层偏移**，FC 写 `[oh*ow*cout, +nout)`，不再覆盖 DW 前 4 字节，见 §2.3。
> · F6 错误路径：`error`/`error_code` **真实现**，错误码沿用 RFC §3 枚举，见 §5。
> · 附：bias 从「两段共用地址」改为**平表**（DW `0..cout-1`、FC `cout..cout+nout-1`），
>   与 quant ROM 布局一致，见 §2.4。

## 1. 模块与范围

| 文件 | 作用 |
|---|---|
| `openeye_srdhm.sv` | TFLite/gemmlowp 精确 requant：左移 → SRDHM → RoundingDivideByPOT → +zp → clamp |
| `openeye_dw_conv.sv` | Depthwise 卷积（Cin=1）：矩形核、四边非对称 pad、32 位累加、bias 通道末折叠一次、**2 拍取数流水 + 溢出检测** |
| `openeye_fc.sv` | Fully Connected（output-major 权重），单 MAC 串行、**2 拍取数流水 + 溢出检测** |
| `openeye_top.sv` | 层调度（DW → FC）+ **两级 requant** + 结果写口（**层偏移**）+ **错误路径** |
| `openeye_crc32.sv` | CRC-32/ISO-HDLC（与 `zlib.crc32` 一致），独立可例化，**尚未接到寄存器/写口**（K4-GAP-01 仍开放） |

`openeye_top` 只做「一层 DW + 一层 FC」的纯计算；层参数由端口输入，数据/权重/bias/quant
都来自调用方提供的存储。它没有 AXI/APB、没有中断、没有 timeout。

## 2. 端口冻结表（`openeye_top`，Draft / PROPOSED）

约定：`clk` 上升沿有效；`rst` 为**同步、高有效**复位。表中「组合」表示该输出由当前状态
组合产生、没有独立复位寄存器；**「同步读」表示 DUT 在第 N 拍给出地址、第 N+1 拍采样返回
数据**（= 标准 block RAM 行为，调用方无需再补流水）。

| 端口名 | 方向 | 位宽 | 时钟域 | 复位值 | 握手 | 读/写语义 |
|---|---|---|---:|---|---|---|
| `clk` | in | 1 | — | — | — | — |
| `rst` | in | 1 | `clk` | — | 同步高有效；清 `busy/done/error/error_code/layer_st` | — |
| `start` | in | 1 | `clk` | — | 单拍脉冲；仅 `!busy` 的 `L_IDLE` 接受，忙时**忽略** | — |
| `busy` | out | 1 | `clk` | 0 | 接受 `start` 后拉高，`done`/`error` 拍拉低 | — |
| `done` | out | 1 | `clk` | 0 | **单拍**脉冲；**保证最后一条结果已写入**后才置位（两级 requant 已排空） | — |
| `error` | out | 1 | `clk` | 0 | **sticky**：置位后保持到下一次 `start` 被接受；`done` 同时**不会**置位 | — |
| `error_code` | out | 8 | `clk` | 0 | 与 `error` 同拍有效；取值见 §5 | — |
| `dw_ih` / `dw_iw` | in | 16 / 16 | `clk` | — | `start` 前稳定，保持到 `done` | — |
| `dw_oh` / `dw_ow` | in | 16 / 16 | `clk` | — | 同上 | — |
| `dw_kh` / `dw_kw` | in | 8 / 8 | `clk` | — | 同上 | — |
| `dw_sh` / `dw_sw` | in | 8 / 8 | `clk` | — | 同上；**必须 ≥1**，0 触发 `OP` | — |
| `dw_pt` / `dw_pl` | in | 8 / 8 | `clk` | — | 同上；四边 pad 只有上/左两个参数，下/右由 `oh/ow` 反推，反推值必须 `< kh/kw` | — |
| `dw_cout` | in | 8 | `clk` | — | 同上 | — |
| `in_zp` | in | 32 signed | `clk` | — | 同上；越界抽头填 `in_zp`，不是 0 | — |
| `dw_out_zp` | in | 32 signed | `clk` | — | 同上 | — |
| `fc_nin` / `fc_nout` | in | 16 / 16 | `clk` | — | `start` 前稳定，保持到 `done`；**`fc_nin` 必须等于 `oh*ow*cout`** | — |
| `fc_out_zp` | in | 32 signed | `clk` | — | 同上 | — |
| `act_min` / `act_max` | in | 32 signed | `clk` | — | 同上；int8 激活裁剪边界 | — |
| `in_y` / `in_x` | out | 16 / 16 | `clk` | 组合（无独立复位） | DW 阶段有效 | 地址（次拍返数） |
| `vec_idx` | out | 16 | `clk` | 组合（无独立复位） | FC 阶段有效 | 地址（次拍返数） |
| `in_q` | in | 8 signed | 同步 | — | **地址后一拍**返回；DW 读输入平面，FC 读 DW 结果向量 | **同步读** |
| `dw_w_idx` | out | 16 | `clk` | 组合（无独立复位） | DW 阶段有效 | 地址（次拍返数） |
| `fc_w_idx` | out | 32 | `clk` | 组合（无独立复位） | FC 阶段有效 | 地址（次拍返数） |
| `w_q` | in | 8 signed | 同步 | — | **地址后一拍**返回 | **同步读** |
| `bias_idx` | out | 16 | `clk` | 组合（无独立复位） | **平表**：DW `0..cout-1`、FC `cout..cout+nout-1`（本模型 DW `0..7`、FC `8..11`） | 地址（次拍返数） |
| `bias_q` | in | 32 signed | 同步 | — | **地址后一拍**返回；通道内索引稳定 ⇒ 天然安全 | **同步读** |
| `quant_idx` | out | 16 | `clk` | 组合（无独立复位） | 与 bias **同一套平表编号**：DW `c`、FC `cout+o` | 地址（次拍返数） |
| `quant_mult` | in | 32 signed | 同步 | — | **地址后一拍**返回；Q31 multiplier | **同步读** |
| `quant_shift` | in | 32 signed | 同步 | — | **地址后一拍**返回；>0 左移、<0 右移 | **同步读** |
| `res_we` | out | 1 | `clk` | 组合（无 valid 时为 0） | 单拍写使能；与 `res_addr` / `res_data` 同拍 | —（写口） |
| `res_addr` | out | 16 | `clk` | 组合（复位后 DW 计数器为 0） | `res_we=1` 时有效；**DW `0..oh*ow*cout-1`，FC `oh*ow*cout..+nout-1`** | —（写口） |
| `res_data` | out | 8 signed | `clk` | 组合（随累加/zero-point） | `res_we=1` 时有效 | —（写口） |

### 2.1 时序

```text
rst=1                    -> busy=0, done=0, error=0, error_code=0
start & !busy & 参数合法  -> 下一拍 busy=1, 进入 DW
start & 参数非法/几何非法 -> 下一拍 error=1, error_code=OP/BUFFER, busy 保持 0
DW 完成                  -> 进入 FC（busy 保持 1）
FC 完成                  -> 等最后一条结果写完后 done=1（单拍），busy 同拍拉低
任一阶段累加溢出          -> 立即停层：error=1, error_code=ARITH, done 不置位, 不再写结果
```

- `start` 在 `busy=1` 时被忽略；K6 若要「忙时 START 报错」，在 MMIO 层做。
- `done` 是单拍脉冲，K6 必须锁存；**`done` 之后回读结果 RAM 一定能读到完整一帧**
  （两级 requant 已排空，这是 2026-10-21 修的一个隐蔽时序问题）。
- 层参数必须在 `start` 前稳定，并保持到 `done`。

### 2.2 存储读口：1 拍延迟同步读（F8 已修）

`in_q`、`w_q`、`bias_q`、`quant_mult`、`quant_shift` 全部按**标准同步读 block RAM**
工作：DUT 在第 N 拍给出地址，第 N+1 拍采样数据。

实现方式：DW/FC 各有 **2 拍取数流水**（地址来自状态寄存器、数据寄存一拍后再参与 MAC），
`top` 的 requant 拆成**两级**（第 1 级锁存 acc/地址/quant 索引并提前一拍给出 quant 地址，
第 2 级用 ROM 返回的 mult/shift 做 SRDHM 并写结果）。

代价是周期数变了，**旧的 `328,000 / 16,004 / 3.44 ms` 全部作废**：

| 阶段 | 组合读版（旧） | 同步读版（现行） | 说明 |
|---|---:|---:|---|
| DW | 328,000 | **336,007** | 4000 通道 × (2 取数 + 80 MAC + 1 bias + 1 推进) = 84 拍/通道 |
| FC | 16,004 | **16,013** | 4 logit × (2 + 4000 + 1) = 4003 拍/logit |
| 合计 | 344,016 | **352,020** | 实测（`tb_openeye_k4` 打印 `CYCLES`） |

| 时钟 | 单帧 | 占 20 ms hop |
|---|---:|---:|
| 100 MHz | 3.52 ms | 17.6 % |
| 50 MHz | 7.04 ms | 35.2 % |
| 27 MHz | 13.04 ms | 65.2 % |

> 注意：**这不改变「单 MAC 串行」的性能结论**——调度层面仍只有 ≤2.4 % 余量，
> 真正的杠杆是并行度（FC 4 路 / DW 8 路）或升时钟。

### 2.3 结果写口：层偏移（F7 已修）

`res_addr` 带层偏移：DW 写 `[0, oh*ow*cout)`（本模型 `0..3999`），FC 从
`fc_res_base = oh*ow*cout`（本模型 **4000**）起写 `[4000, 4003]`。
⇒ **两层结果落在同一段连续窗口内，不再互相覆盖**，K6 直接回读即可。

选「基址由几何反推」而不是新增 `fc_res_base` 端口，是为了**零端口变更**、不打断 ABI 评审。
验证台 `tb_openeye_k4.sv` 已改为**单窗口 `0..4003`** 比对（不再用 `capture_fc` 切换数组），
所以 F7 一旦回归，DW 比对会立刻失败——这个台现在能直接抓 F7。

### 2.4 bias / quant 平表（原「两阶段共用地址」耦合已消除）

`bias_idx` 与 `quant_idx` 使用**同一套平表编号**：DW 用 `c`，FC 用 `cout + o`。
本模型 bias ROM = 8×int32 (DW) ++ 4×int32 (FC)，quant ROM = 12 组 `{mult, shift}`。
调用方不再需要「按层选 bank」。

## 3. 参数 ROM / quant ROM 布局（调用方提供）

`params_rom.bin`（16,688 B）：

| 区段 | 偏移 | 字节 |
|---|---:|---:|
| DW 权重（OHWI） | 0 | 640 |
| DW folded bias（8×int32） | 640 | **32** |
| FC 权重（output-major） | 672 | 16,000 |
| FC folded bias（4×int32） | 16,672 | 16 |

> 注意：K4 报告早期写的 `conv_b_base=640, 128 B` 是笔误；DW bias 是 **32 B**。
> bias 平表 = 上面两段按 `[DW 0..7][FC 8..11]` 拼接（原始 ROM 里本来就是分开的两段，
> 集成时只需把 FC bias 的基址映射到 `cout`）。

`quant.mem`（96 B）：12 组 `{mult, shift}`，每组 8 B；DW 通道 0..7，FC 输出 8..11。

## 4. 未做 / 不在本目录

- MMIO / 控制窗 / buffer 窗 / 寄存器文件 / IRQ / timeout / **CRC 接线**：属接口层，等 ABI 批准。
- SoC 集成、K6 存储模型、PDS/STA/板级：`NOT_RUN`。
- 多 MAC / 并行度、真正的流水化 MAC：当前单 MAC 串行是刻意先把数值坐实，不是性能结论。

## 5. 错误路径（F6 已实现；K4-GAP-01 仍开放）

`error` / `error_code` 不再是死端口。错误码**严格沿用**
`docs/architecture/RFC-KWS-MMIO-ABI.md` §3 的枚举，**没有新增值**：

| 值 | 名称 | 触发条件（本版实现） |
|---:|---|---|
| 0 | `NONE` | 无错 |
| 1 | `OP` | 层参数非法：`ih/iw/oh/ow/kh/kw/sh/sw/cout/nin/nout` 任一为 0 |
| 2 | `BUFFER` | 几何不一致：由 `(oh-1)*sh + kh - ih` 反推的 `pb` 必须落在 `[0, kh)`，`pr` 落在 `[0, kw)`；`fc_nin` 必须等于 `oh*ow*cout`；`oh*ow*cout + nout` 必须落在 16 位地址窗口内 |
| 3 | `WATCHDOG` | **未实现**（V1 无 timeout，属 MMIO/接口层） |
| 4 | `ARITH` | DW/FC 的 32 位有符号累加（MAC 与 bias 折叠）溢出 ⇒ 结果无效 |

语义（与 `STATUS.error-sticky` 对齐）：

- 出错时 **不置 `done`**、**不再写任何结果**（不产出半份 logits）；
- `error` / `error_code` 保持到下一次 `start` 被接受，或 `rst`；
- 合法 job 全程 `error=0`（主台会检查，见 §6）。

| 缺口 ID | 内容 | 状态 |
|---|---|---|
| `K4-GAP-01` | 输入/权重/描述符 CRC 校验与错误码 | **仍开放**：`openeye_crc32.sv` 未接线；`0x040` 语义未批准（属 K5/K6） |
| `K4-GAP-02` | 几何/边界检查（`kh/kw`、pad、`ih/iw` 与 `oh/ow` 一致性） | **已关闭（RTL 侧）**：`OP`/`BUFFER` + `tb_openeye_errors` 的 case1/2/3 负控 |
| `K4-GAP-03` | 累加溢出检查与「失败不写部分 logits」 | **已关闭**：`ARITH` + case4 负控（断言 `writes=0`） |

> `WATCHDOG`（3）与 CRC（`K4-GAP-01`）仍归接口/MMIO 层；在它们接上之前，
> 不要把 `error_code` 宣传成「已覆盖 CRC/超时」。

## 6. 验证台

| 台 | 作用 | 现况 |
|---|---|---|
| `verification/kws/k4/tb_openeye_k4.sv` | 7 个 fixture 逐字节（DW 4000 + FC 4），**同步读存储模型**、单结果窗口 | **7 / 7 PASS** |
| `verification/kws/k4/tb_openeye_errors.sv` | 错误路径 6 用例（NORMAL / CFG / GEO / VECLEN / ARITH / RECOVER） | **6 / 6 PASS** |
| `verification/kws/k4/tb_srdhm_cases.sv` | requant 单元用例（含舍入边界） | PASS |
| `verification/kws/k4/tb_openeye_crc32.sv` | CRC32 vs `zlib.crc32` | 13 / 13 PASS |
| `tools/kws/negctl_k4.py` | 8 条变异负控（必须全部 CAUGHT） | **8 / 8 CAUGHT** |

## 7. 调试开关

`openeye_top.sv` 不再保留 `OPENEYE_DEBUG` 死引用。TB 观察用层次路径
（`u_dut.layer_st`、`u_dut.u_dw.st`、`u_dut.rq1_acc` 等）。
