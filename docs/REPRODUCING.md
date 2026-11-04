# 工具与复现说明

## 已归档产物

release/multiboot-2026-11-04/ 保存最终 SFC、三个镜像的 .sbit/.smsk 伴随文件、地址布局、JSON 清单和 SHA-256 列表。可先据此核对文件是否与冻结交付一致。

## 仿真工具

Boot Selector 回归脚本为 verification/boot/run_iverilog.ps1，需要 Icarus Verilog（iverilog 与 vvp）：

    pwsh -File verification/boot/run_iverilog.ps1

可将 IVERILOG_BIN 设置为包含两个可执行文件的目录。若要运行使用 Pango 仿真模型的 A3 warmboot 用例，将 PANGO_GTP_IPAL_E2_MODEL 设置为 GTP_IPAL_E2.v 文件路径；未提供模型时，该用例会跳过。厂商模型受其原始分发条款约束，本仓库不含该文件。

## FPGA 构建

重新生成位流需要 Pango PDS 2022.2-SP6.4、目标 PG2L100H 器件支持、相应本地板卡约束和 KWS 固件输入。公开树记录了源码与输入来源，但组合源码快照没有整体重建或验证，不能据此保证从单一快照命令产生完全相同的 SFC。

本仓库不包含板卡烧写脚本，也不自动执行 Flash 擦除或写入操作。已验证的二进制和结果边界见 RESULTS.md。