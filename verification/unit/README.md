# verification/unit

模块测试；用有意义的边界和负例证明测试会失败。

## 套件清单（与 `scripts/run_tests.py` 注册一致，2026-09-28 核对）

| 测试名 | Testbench | 覆盖 |
|--------|-----------|------|
| pc_reg | tb_pc_reg.sv | PC 复位/顺序/重定向/暂停 |
| if_stage | tb_if_stage.sv | IF FSM 基本 handshake 与状态迁移 |
| if_id | tb_if_id.sv | IF/ID 锁存、hold、flush |
| id_stage | tb_id_stage.sv | RV32I 译码、非法指令、fault 门控、pred_* 透传；**SYSTEM 类（CSR 字段/立即数变体/ECALL/EBREAK/MRET/WFI 与保留编码）+ 「ID 不判 CSR 地址合法性」的决策锁定（Test 24）** |
| decode_matrix | tb_decode_matrix.sv | **穷尽译码矩阵**：规范模型（独立于 RTL）比对，128 opcode × 2 配置 + 10 个已实现 opcode × 8 funct3 × 4 funct7 + 副作用抑制 |
| frontend | tb_frontend.sv | pc_reg+if_stage+if_id+id_stage 联合通路 |
| branch_predictor | tb_branch_predictor.sv | BTB/2-bit 计数器单元行为 |
| predictor_flow | tb_predictor_flow.sv | 预测元数据 IF→ID 流转 |
| predictor_gshare | tb_predictor_gshare.sv | gshare 方向预测（GHR 更新、索引一致性） |
| predictor_ras | tb_predictor_ras.sv | 返回地址栈（压栈地址、返回预测） |
| frontend_perf | tb_frontend_perf.sv | 前端性能计数（第二层：与**真实 id_stage** 对接） |
| if_throughput | tb_if_throughput.sv | IF 取指吞吐 |
| random_delay | tb_random_delay.sv | 随机延迟 6 阶段 + drain 严格对账（PC 序列监控） |
| redirect_race | tb_redirect_race.sv | redirect×响应/请求/flush 同拍竞态（确定性，Gate #1） |
| payload_hold | tb_payload_hold.sv | 同拍响应×下游 hold 载荷保持（确定性，Gate #3）：skid/背压/两次同拍窗口/fault 载荷/恰好一次 scoreboard |
| reset_polarity | tb_reset_polarity.sv | 同步高有效复位（Gate #4）：非异步判别、采样沿清零、释放恢复 |
| if_buffer_contract | tb_if_buffer_contract.sv | IF 缓冲契约（响应与 hold 同拍等边界） |
| if_id_hold_contract | tb_if_id_hold_contract.sv | D-8 回归：用**真实 `if_id`** 驱动 `if_out_ready` 的 hold 契约 |
| periph | tb_periph.sv | UART/GPIO/Timer 从端：窗口内偏移、只读拒写、未映射报错 |
| csr | tb_csr.sv | `csr_file`：7 个冻结 CSR 读写与 WARL、精确 machine trap 状态迁移、中断判定（37 项） |
| icache | tb_icache.sv | I-Cache（2 KiB / 2 路 / 64 组 / 16 B 行 / 4 beat 突发填充） |
| dcache | tb_dcache.sv | D-Cache（写透 / 不写分配） |
| lsu | tb_lsu.sv | LSU 定向测试（含批 (b) 新增的故障归因 `fault_misaligned_o`/`fault_addr_o`；内部计数 62） |

系统级套件不在本目录：`verification/system/`（`tb_cpu_mem_subsystem`、`tb_mem_map`、
`tb_cpu_core_stage1`、`tb_cpu_core_faults`、`tb_cpu_core_btb`、`tb_cpu_core_csr`、
**`tb_cpu_core_trap`**、`tb_pangu100proplus_top`）。

## 负向对照突变体

在 `verification/negctl/rtl/`（仅供 `scripts/run_tests.py --negative-controls`，**禁止综合**）；
全部由 `scripts/gen_*_negctl.py` 从当前源**确定性生成**（锚点必须恰好命中一次，失配即报错）：

- IF：`if_stage_negctl_{orphan,double_req,strand,skiddrop,rstpol}`（生成器 `scripts/gen_ifstage_negctl.py`）、
  `if_id_negctl_readyalways`
- 译码：`id_stage_negctl_{illegallatch,funct3blind,shiftf7}`、**`id_stage_negctl_csrwealways`**（CSR 写意图恒 1）
- 预测器/性能：`branch_predictor_negctl_{noghr,nogshareidx,rasaddr}`、`frontend_perf_negctl_{nogate,misclass}`
- 存储/接入：`addr_decode_negctl_nosram`、`mem_map_adapter_negctl_{romwriteok,errswallow}`、
  `cpu_mem_subsystem_negctl_{uarttie,wdata}`、`cpu_core_stage1_negctl_nontrecover`
- **CSR 接入（2026-09-28 批 (a)）**：`cpu_core_stage1_negctl_{csrnostall,csrnowbdata}`、`id_stage_negctl_csrwealways`
- **同步异常精确陷阱（2026-09-28 批 (b)）**：`cpu_core_stage1_negctl_{trapnoredir,trapcauseswap,trapnomret,csrwritableblind}`

> ⚠️ **已知问题（2026-09-28 记录，尚未修复）**：`if_stage_negctl_{orphan,double_req,strand,skiddrop,rstpol}.sv`
> 是 **BTB 接入之前**的 `if_stage.sv` 手工副本（端口 19 个，现为 25 个），**已无法编译** ——
> 即"违规从未进入可运行 RTL"。`run_tests.py --negative-controls` 自 2026-09-28 起把
> **编译失败计为"对照失效"**（不再算捕获），故这 6 条对照当前为**失效**状态，
> 修复计划见 `docs/logs/成员A/2026-09-28/29-同步异常精确陷阱-WIP.md` §10。

> ✅ **已修复（2026-09-29）**：上述 5 个突变体已改由 **`scripts/gen_ifstage_negctl.py`** 从**当前**
> `rtl/core/if_stage.sv` 确定性再生（保留 25 端口与 BTB 预测锁存，只注入各自那一处违规；
> 5 个锚点各须命中恰好 1 次，失配即整体报错且不写文件）。实测：5/5 编译通过、
> `--negative-controls` **40/40 真捕获、exit 0**（"对照失效"与编译失败均为 0 次）、
> 正向回归 **666 PASS / 0 FAIL**。**请勿手工编辑这 5 个文件**——改注入意图请改生成器并重跑。
> 细节见 `docs/logs/成员A/2026-09-28/29-同步异常精确陷阱-WIP.md` §11。
> 上一条 ⚠️ 保留为历史记录。
