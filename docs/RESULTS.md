# 最终实板结果

## Flash 多镜像包

| 项目 | 结果 |
|---|---|
| 目标板 | Pangu100Pro+，PG2L100H-6IFBG676 |
| Flash | XTX XT25F128F，16 MiB，JEDEC 0x000B4018 |
| 镜像包 | w3_multiboot_oled_pfix.sfc |
| 文件大小 | 11,399,168 字节（0xADF000） |
| SHA-256 | 7CAE8E80B9B07B11A438A0E039FEA83F6C5F9E753CF325FF08E43F5141875469 |
| 地址 | Golden 0x000000 / KWS-OLED 0x3A2000 / CPU Z1 0x741000 |
| Flash 写入 | 擦除、写入、器件 verify 均通过 |
| Readback | Flash 完整回读 SHA-256 与 SFC 完全相同 |

完整文件哈希和布局见 [release/multiboot-2026-11-04/](../release/multiboot-2026-11-04/)。

## 启动与交互

- 冷启动且不按键：Golden 不 warmboot，随后进入 KWS-OLED App A2。
- KWS 演示：OLED 三行显示正常；语音 yes/no 对应的风扇开关与 OLED 状态切换正常，P 字形修复已包含在最终镜像中。
- KEY1 上电：Golden 进入 READY 面板；状态流对应 mode_sel=1、ready=1、running=0、state=5。
- READY 下按 KEY2：warmboot 到 CPU Z1，CoreMark 4096 在板上完成，输出 Correct operation validated.。
- Boot Selector 与 GTP_IPAL_E2 warmboot 命令生成器已在 PDS 2022.2 / PG2L100H 路线上完成映射；官方 219-word warmboot 命令流在目标板上生效。

## CPU Z1 CoreMark

- CPU 频率：95.29411765 MHz。
- 迭代数：4096；报告 ticks：1,433,935,241。
- 评分：2.856475 CoreMark/MHz。
- CRC：seed 0xe9f5、list 0xe714、matrix 0x1fd7、state 0x8e3a、final 0x7b65；与冻结记录中的 Z1 验证值一致。

原串口输出含 timer_hz=100058824 字段，该频率元数据与 95.294 MHz CPU 时钟不一致；本快照不依据这一字段发布墙钟时间或每秒迭代数。串口中整数格式的 Total time(secs) 和 Iterations/Sec 也不作为精确性能指标。

## 结果边界

- KWS 记录证明了指定板卡上的功能演示，不是量化准确率、FAR/FRR 或完整数据集评估。
- 100 MHz CPU 时序目标未关闭；最终交付采用冻结的 95.294 MHz Z1 版本。
- 已有实板证据对应冻结分支分别构建出的 Golden、KWS 和 CPU 镜像；它不是公开快照组合提交的一次端到端重建。
- PDS 2022.2 需要本地配置 XTX XT25F128F 器件条目。该环境配置不是 RTL 或本仓库位流的一部分，未包含本机 PDS 配置文件。
- 公开快照整理期间没有运行仿真或 PDS 构建。