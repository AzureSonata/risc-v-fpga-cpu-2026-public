# 第三方声明

本文件记录本快照中可识别的第三方材料。除相应文件自带的条款外，本文件不授予第三方材料额外权利。

## Apache License 2.0 材料

- rtl/core/defines.sv 保留了 tinyriscv / Blue Liang 的原始版权与 Apache 2.0 声明。随仓库提供许可证文本：sources/upstream/tinyriscv/LICENSE-2.0.txt。请保留 RTL 文件中的原声明。
- KWS / TensorFlow Lite for Microcontrollers 来源记录和许可证副本位于 sources/upstream/kws-tflm-230c9/，其中包含 TFLM-LICENSE。上游来源与文件哈希见同目录 manifest。

## CoreMark

CoreMark 源码不随本仓库打包；固件构建流程按其固定上游版本获取源码。EEMBC 上游 LICENSE.md 同时包含 Apache 2.0 许可文本与 CoreMark Acceptable Use Agreement。CoreMark 名称和商标受 EEMBC 条款约束：[EEMBC CoreMark LICENSE.md](https://github.com/eembc/coremark/blob/main/LICENSE.md)。

## 赛题和板卡资料

- sources/official/pango-2026-guide.pdf：2026 FPGA 赛题指南。文档未修改；项目成员确认允许随本项目公开。发布的文件哈希与来源说明见 sources/official/PROVENANCE.md。
- sources/vendor/pangu100proplus/hardware/：盘古 100Pro+ 引脚资料和原理图。保留原始文件；文件清单、哈希和公开来源说明见该目录 README.md。
- 公开快照不包含群聊答疑截图或个人协作记录。

## OLED 字模

OLED SystemVerilog 中嵌入了小尺寸 SimSun 栅格字形数据；原始 Windows 字体文件未打包。项目作者确认已获得公开这些字模及包含字模的最终位流所需的单独授权。原始 Windows 字体文件未打包。

## 项目级许可

本仓库按作者决定暂不添加项目级许可证。仓库代码默认仍受著作权保护；GitHub 公共仓库可供用户在 GitHub 服务内查看和 fork，但没有项目级许可证就没有额外的通用复用许可。请参见 [GitHub licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)。