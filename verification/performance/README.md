# 双发射完整 SoC 的 Verilator 测量入口

入口：`python scripts/run_dual_coremark_sim.py`。只运行软件仿真，不访问 PDS、JTAG 或实体串口。

## 输入与源码绑定

- `--hex` 与旁边的 `manifest.json` 必须匹配 SHA-256；当前支持完整 `rv32im`、performance 或 validation、正数迭代与 timer_hz。
- 默认读取当前工作树，在复制前后比较每个 RTL 文件字节，变化时失败；每次在全新输出目录保存完整源快照及 hashes、runner 副本/哈希、Git head、dirty diff、固件清单、实际工具版本、argv、日志、退出码和阶段 PID。
- `--source-ref <commit>` 从 Git blob 读取 RTL，用于历史候选。测试 harness 仍取当前 runner 版本并单独记录 hash。
- `--source-snapshot <root>` 从不可变目录读取 `rtl/`，用于两个参数配置严格同源 A/B。可传前次输出的 `src/`；比较两个结果的 `source.files`，不能只比较 Git head。
- `--wide-icache 0/1` 控制新宽口；不指定时按快照 top 是否支持自动选择。旧提交无此参数时保持 legacy，显式请求不支持的 wide=1 会失败。
- `--extra-source rtl/...` 允许追加新的模块文件；默认列表是当前完整 top 的最小闭包，Verilator 对缺少的模块定义报错。

Windows 已实跑安装为 Verilator 5.050、UCRT64 g++/运行库、MinGW make 和 MSYS bash。runner 直接选 `verilator_bin.exe`，避免 Perl wrapper；每次 fresh Mdir；编译和执行均带所选 UCRT64 runtime PATH。工具路径也可用 `--verilator`、`--make`、`--bash` 显式指定。

## 短窗口定位

```powershell
python scripts/run_dual_coremark_sim.py --hex C:/pdswork/firmware/coremark.hex --out-dir C:/pdswork/dual-window-001 --dual-issue 1 --wide-icache 1 --window-cycles 2000000
```

默认从第一笔被接受的 MMIO timer 读请求或第一条退休的 mcycle/mcycleh 读取开始统计。`--start-event timer|mcycle|reset` 可限定事件，`--start-pc 0x...` 可指定退休 PC。窗口结束明确输出 `SIM_WINDOW_DONE`；超时以 `$fatal` 非零退出。脚本独立检查完成标记、精确窗口长度和分类周期和，普通 `$finish` 不构成通过。

`primary_*` 采用固定优先级：redirect → LSU pending → MDU pending → CSR pending → fetch queue empty → issue0 accepted → other wait。各项互斥且总和等于窗口周期。`overlap_*`、RAW/WAW 和 lane1 blocked 是可能重叠的观测事件，不能相加为独占损失，也不能直接视为去掉该事件后的加速量。cache hit/miss 为窗口两端 DUT 计数差。`PASS_WINDOW` 永远不包含 CoreMark 分数。

## 完整 CoreMark / CRC

```powershell
python scripts/run_dual_coremark_sim.py --hex C:/pdswork/firmware-i32/coremark.hex --out-dir C:/pdswork/dual-complete-001 --dual-issue 1 --mode complete --allow-short-run --max-cycles 100000000 --run-timeout 900
```

完整模式必须显式给 `--max-cycles`；wall timeout 和 cycle timeout 都失败，保留部分日志。harness 解码真实 `uart_tx` 引脚、确认 stop bit，将字节写到 `uart.raw`，检测 CoreMark 终态并排空尾部输出。脚本对 iterations、正 ticks、seedcrc、list/matrix/state CRC、crcfinal 字段和终态作独立检查。已知 CRC 来源为 [锁定 EEMBC core_main.c](https://github.com/eembc/coremark/blob/1f483d5b8316753a742cbf5590caf5bd0a4e4777/core_main.c) 的 2K 两组官方向量。

官方程序会把 `<10s` 运行写成 `ERROR! Must execute for at least 10 secs for a valid result!`，并打印 `Errors detected`。32/128 迭代软件仿真通常触发该规则，不能更改算法源绕过检查。默认完整模式严格拒绝；只有显式 `--allow-short-run`，且唯一错误为该时长提示、已知算法 CRC 全部正确、完整输出结束时，才返回 `PASS_COMPLETE_CRC_ONLY`。JSON 同时设置 `official_run_rules_pass=false`；其归一化比值只用于仿真诊断，不能作为正式板测分数。正式满足时长且验证通过返回 `PASS_COMPLETE`，但仍为软件仿真证据。

使用现有构建入口生成对应镜像：

```powershell
python scripts/build_coremark_candidate.py --iterations 32 --mode performance --march rv32im
python scripts/build_coremark_candidate.py --iterations 128 --mode validation --march rv32im
```

该构建入口的实际 upstream/toolchain 路径须存在；runner 不自动下载或修改 CoreMark。以每次真实输出路径和其 manifest 为准，不把32与128两份固件的结果拼成同一镜像。1280迭代完整仿真可能持续很久，应先估计速度并明确超时再启动。

## 结果与验证

- `result.json` 是最终状态与指标；`elaborate.log`、`build.log`、`simulate.log` 实时落盘。
- `uart.raw` / `uart.txt` 保存 UART 原始输出；`src/` 和 `runner.py` 为运行时实际快照。
- `python verification/performance/test_dual_coremark_sim.py` 检查标准 CRC 向量、短跑例外、CRC/迭代不符、缺字段、假完成和 timeout 拒绝路径。
- 编译/模拟超时只终止本 runner 创建的进程树，保留日志与 PID；不复用不完整 Mdir。

2026-10-25 首轮结果：旧 S4 双发射 2M 窗口 IPC `0.218580`；同源 `8c24976`（含 redirect 修复）的单发射 `0.2591385`、双发射 `0.2594815`。修复同时改善单发射，当前真实双发射收益约 `0.1324%`，旧 `0.218374` 不可作为新双发射的同源对照。这些窗口尚未完成整个 CoreMark。
