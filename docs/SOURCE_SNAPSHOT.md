# 源码快照来源

公开快照按项目冻结记录组合了三条最终集成线。该仓库使用一个全新的快照提交，不携带原仓库的 Git 历史、PR、Issue 或协作讨论。

## 主要源码线

| 用途 | 冻结分支 | 源提交 |
|---|---|---|
| CPU Z1、最终多镜像包与收口证据 | feat/e1-w3-night-20261103 | 50fe8c915497c8ac4f933e197a1ea1a3a19c9f7b |
| Boot Selector、OLED Golden、按键探测与 READY 面板 | feat/mrev-keyprobe-20261104 | 70ea219c24d771ad54c4077ac48099ffdd15d0c7 |
| KWS v12demo App A2 与 OLED 显示层 | feat/mrev-kws-oled-20261104 | 41e1afb4857dafc364423d279930891eda0bb2e0 |

## 冻结记录中的支撑分支

项目冻结清单还列出以下相关分支。这些 SHA 用于记录工程来源，不代表公开快照把这些分支的整棵目录逐个叠加：

| 支撑内容 | 冻结分支 | 冻结提交 |
|---|---|---|
| KWS v12demo 诊断固件链 | feat/int-uar-banner-20261103 | 38b4bd528abedb601661f66df5c96f9aced95b15 |
| Boot Selector 偏移与 PDS 工程 | feat/mrev-bootsel-20261104 | 35dc9e99d55127b65877941d0d942fd0e5eca513 |
| GTP_IPAL_E2 warmboot 生成器与仿真 | feat/mrev-warmboot-20261104 | 121c5d8a47de0cf65d03283df6f06bd53d929062 |
| OLED 驱动提取与字模资源校验 | feat/mrev-oled-extract-20261104 | 9680775dda11af20bd6665168b73650664aa9f6b |
| OLED 页面显示层 | feat/mrev-oled-20261104 | 605872174498914f53d6aa39730e08285b685b4c |
| PDS RAM 推断网表转换 | feat/int-ramfix-20261103 | d598a98c2d5d39ab2f351f04bc8691263fc81799 |

冻结记录的截图未作为文件发布；上述信息是根据截图与相应 Git 提交核对后转录。

## 组合边界

- SFC 的 SHA-256、容量、地址布局、Flash readback 和 KEY1/KEY2 板测，来自最终冻结记录 evidence/multiboot-20261104。
- 最终 SFC 由三份独立生成的 .sbit 组成；源码快照是在不同冻结提交之间选择文件构成的组合树。
- 组合后的公开源码树没有作为一个提交整体重新执行 PDS build、重新生成 SFC 或重新进行板测。不要把已有二进制结果表述成这个公开提交的一次可重复构建结果。
- 最终包中的 .smsk 是对应组件的伴随文件；Flash 流地址与组件哈希列于发布目录清单。