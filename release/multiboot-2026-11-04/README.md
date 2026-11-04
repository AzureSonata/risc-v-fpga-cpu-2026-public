# 最终 Flash 多镜像包

该目录保存 2026-11-04 冻结并完成实板写入/readback 核对的版本。针对 Pangu100Pro+、PG2L100H-6IFBG676 和 XTX XT25F128F。

| Stream | 用途 | Flash 起始地址 | .sbit | .smsk |
|---:|---|---:|---|---|
| 0 | Golden：Boot Selector / READY / OLED P 修复 | 0x000000 | golden-oled-pfix.sbit | golden-oled-pfix.smsk |
| 1 | App A2：KWS v12demo / OLED P 修复 | 0x3A2000 | kws-app-a-pfix.sbit | kws-app-a-pfix.smsk |
| 2 | App B：CPU Z1，95.294 MHz | 0x741000 | cpu-z1-95294.sbit | cpu-z1-95294.smsk |

最终文件 w3_multiboot_oled_pfix.sfc 为 11,399,168 字节，SHA-256：

7CAE8E80B9B07B11A438A0E039FEA83F6C5F9E753CF325FF08E43F5141875469

逐文件 SHA-256 见 SHA256SUMS.txt，地址与组件哈希见 layout.csv 和 manifest.json。

Flash readback 的完整 SHA-256 与 .sfc 一致。公开仓库不包含重复的 readback 二进制；最终记录和校验值见项目结果文档。.smsk 为对应 PDS 组件文件，表中地址是三条 SFC stream 的起始地址。