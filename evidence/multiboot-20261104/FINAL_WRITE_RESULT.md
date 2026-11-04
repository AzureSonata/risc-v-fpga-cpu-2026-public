# 最终镜像写入结果（OLED P 修复版）

日期：2026-11-04。目标板：Pangu100Pro+，PG2L100H-6IFBG676；板载 Flash：XTX XT25F128F。

- 文件：w3_multiboot_oled_pfix.sfc
- 大小：11,399,168 字节
- SFC SHA-256：7CAE8E80B9B07B11A438A0E039FEA83F6C5F9E753CF325FF08E43F5141875469
- Flash 完整回读 SHA-256：7CAE8E80B9B07B11A438A0E039FEA83F6C5F9E753CF325FF08E43F5141875469
- 结果：器件 verify 通过；回读 SHA-256 与 SFC 完全一致。

记录的主要写入阶段耗时：Flash erase 38.2 s、program 185.8 s、verify 12.1 s、readback 12.0 s。

三条流：Golden 0x000000 / KWS-OLED 0x3A2000 / CPU Z1 0x741000。完整组件哈希见发布目录 manifest。