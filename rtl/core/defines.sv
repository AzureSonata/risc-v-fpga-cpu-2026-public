// ============================================================================
//        RV32I 五级流水 CPU — 全局宏定义
//        参考：tinyriscv/defines.v (Apache 2.0)
//        本项目精简版，仅含 RV32I + 控制信号 + 总线宽度
// ============================================================================
// 保留 Apache 2.0 版权声明
// Copyright 2019 Blue Liang, liangkangnan@163.com
// Licensed under Apache 2.0 — https://www.apache.org/licenses/LICENSE-2.0

`ifndef __DEFINES_V__
`define __DEFINES_V__

// ==================== 基础常量 ====================
`define RstEnable       1'b1
`define RstDisable      1'b0
`define ZeroWord        32'h0
`define ZeroReg         5'h0
`define WriteEnable     1'b1
`define WriteDisable    1'b0
`define ReadEnable      1'b1
`define ReadDisable     1'b0
`define True            1'b1
`define False           1'b0
`define ChipEnable      1'b1
`define ChipDisable     1'b0

// ==================== 控制信号 ====================
`define JumpEnable      1'b1
`define JumpDisable     1'b0
`define HoldEnable      1'b1
`define HoldDisable     1'b0
`define FlushEnable     1'b1
`define FlushDisable    1'b0

`define HoldFlagBus     2:0
`define HoldNone        3'b000
`define HoldPc          3'b001
`define HoldIf          3'b010
`define HoldId          3'b011

// ==================== 总线宽度 ====================
`define MemBus          31:0
`define MemAddrBus      31:0
`define InstBus         31:0
`define InstAddrBus     31:0
`define RegAddrBus       4:0
`define RegBus          31:0
`define RegWidth        32
`define RegNum          32
`define RegNumLog2       5

// ==================== 复位地址 ====================
`define CpuResetAddr    32'h00000000

// ==================== RV32I Opcode 定义 ====================
// I 型（立即数算术）
`define INST_TYPE_I     7'b0010011
`define INST_ADDI       3'b000
`define INST_SLTI       3'b010
`define INST_SLTIU      3'b011
`define INST_XORI       3'b100
`define INST_ORI        3'b110
`define INST_ANDI       3'b111
`define INST_SLLI       3'b001
`define INST_SRI        3'b101

// L 型（取数）
`define INST_TYPE_L     7'b0000011
`define INST_LB         3'b000
`define INST_LH         3'b001
`define INST_LW         3'b010
`define INST_LBU        3'b100
`define INST_LHU        3'b101

// S 型（存数）
`define INST_TYPE_S     7'b0100011
`define INST_SB         3'b000
`define INST_SH         3'b001
`define INST_SW         3'b010

// R 型（寄存器-寄存器运算）
`define INST_TYPE_R_M   7'b0110011
`define INST_ADD_SUB    3'b000
`define INST_SLL        3'b001
`define INST_SLT        3'b010
`define INST_SLTU       3'b011
`define INST_XOR        3'b100
`define INST_SR         3'b101
`define INST_OR         3'b110
`define INST_AND        3'b111

// JAL / JALR
`define INST_JAL        7'b1101111
`define INST_JALR       7'b1100111

// LUI / AUIPC
`define INST_LUI        7'b0110111
`define INST_AUIPC      7'b0010111

// B 型（分支）
`define INST_TYPE_B     7'b1100011
`define INST_BEQ        3'b000
`define INST_BNE        3'b001
`define INST_BLT        3'b100
`define INST_BGE        3'b101
`define INST_BLTU       3'b110
`define INST_BGEU       3'b111

// NOP
`define INST_NOP        32'h00000013

// ==================== 流水线级间字段 ====================
`define EpochBus        1:0

`endif