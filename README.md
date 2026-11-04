# RISC-V FPGA CPU 2026 — 最终 Flash 多镜像集成

这是 2026-11-04 冻结的 Pangu100Pro+ 实板交付快照，包含 Boot Selector、KWS-OLED App A2、CPU Z1 三镜像 Flash 包，以及对应的源代码和整理后的验收记录。

**English summary:** A frozen three-image Flash integration for the Pangu100Pro+ FPGA board: OLED boot selector, KWS App A2 application, and CPU Z1 CoreMark image.

## 集成概览

- 板卡：盘古 100Pro+，PG2L100H-6IFBG676；板载 Flash：XTX XT25F128F，16 MiB。
- 默认上电：Golden 启动后 warmboot 到 KWS-OLED App A2；OLED 三行状态显示，语音 yes/no 演示可切换风扇状态。
- 按住 KEY1 上电：Golden 停在 READY；READY 状态下按 KEY2，warmboot 到 CPU Z1 并运行 CoreMark 4096。
- Flash 地址：Golden **0x000000**、KWS-OLED **0x3A2000**、CPU Z1 **0x741000**。
- 最终包：[release/multiboot-2026-11-04/w3_multiboot_oled_pfix.sfc](release/multiboot-2026-11-04/w3_multiboot_oled_pfix.sfc)，11,399,168 字节，SHA-256 **7CAE8E80B9B07B11A438A0E039FEA83F6C5F9E753CF325FF08E43F5141875469**。
- Flash 写入、器件 verify 和完整 readback 均通过；readback SHA-256 与 SFC 相同。实板启动与按键链结果见 [docs/RESULTS.md](docs/RESULTS.md)。

## 快速导航

- 作者与共同作者说明：[AUTHORS.md](AUTHORS.md)
- 公开快照来源与组合边界：[docs/SOURCE_SNAPSHOT.md](docs/SOURCE_SNAPSHOT.md)
- 实板结果、指标和限制：[docs/RESULTS.md](docs/RESULTS.md)
- 工具与复现边界：[docs/REPRODUCING.md](docs/REPRODUCING.md)
- 第三方材料与声明：[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- 最终 Flash 文件清单：[release/multiboot-2026-11-04/README.md](release/multiboot-2026-11-04/README.md)

## 快照与许可状态

此仓库是只读的发布快照，仓库级别**没有添加项目许可证**。各作者保留其代码权利；公开 GitHub 仓库允许在 GitHub 服务内查看和 fork，但这不等于获得仓库代码的通用复制、再发布或衍生作品许可。第三方文件继续适用其各自声明。参见 [GitHub 关于仓库许可的说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)。

源代码由多个已冻结分支组合而成；这一组合快照没有作为一个整体重新构建或实板复测。二进制与板测结论对应已记录的独立构建线，边界详见来源和结果说明。