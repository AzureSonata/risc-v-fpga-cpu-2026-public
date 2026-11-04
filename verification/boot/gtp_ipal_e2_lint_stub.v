// Lint-only behavioural stub for the Pango GTP_IPAL_E2 primitive used by the
// A4 board wrapper elaboration check with Icarus Verilog (the real primitive is
// supplied by PDS). Tracked in verification/boot so the board-level power-up tb\n// (tb_board_powerup.sv) reproduces from a clean checkout; never part of a PDS build.
`timescale 1ns/1ps
module GTP_IPAL_E2 #(
    parameter            DATA_WIDTH = "X8",
    parameter     [31:0] IDCODE     = 32'hAAAA5555,
    parameter            SIM_DEVICE = "PG2L100H"
) (
    output        [31:0] DO,
    output               RBCRC_ERR,
    output               RBCRC_VALID,
    output               ECC_VALID,
    output        [11:0] ECC_INDEX,
    output               SERROR,
    output               DERROR,
    output reg     [7:0] SEU_FRAME_ADDR,
    output reg     [7:0] SEU_COLUMN_ADDR,
    output reg     [4:0] SEU_REGION_ADDR,
    output reg     [7:0] SEU_FRAME_NADDR,
    output reg     [7:0] SEU_COLUMN_NADDR,
    output reg     [4:0] SEU_REGION_NADDR,
    output               PRCFG_OVER,
    output               PRCFG_ERR,
    output               DRCFG_OVER,
    output               DRCFG_ERR,
    input                RST_N,
    input                CLK,
    input                CS_N,
    input                RW_SEL,
    input         [31:0] DI
);
    assign DO          = 32'h0;
    assign RBCRC_ERR   = 1'b0;
    assign RBCRC_VALID = 1'b0;
    assign ECC_VALID   = 1'b0;
    assign ECC_INDEX   = 12'h0;
    assign SERROR      = 1'b0;
    assign DERROR      = 1'b0;
    assign PRCFG_OVER  = 1'b0;
    assign PRCFG_ERR   = 1'b0;
    assign DRCFG_OVER  = 1'b0;
    assign DRCFG_ERR   = 1'b0;
    initial begin
        SEU_FRAME_ADDR   = 8'h0;
        SEU_COLUMN_ADDR  = 8'h0;
        SEU_REGION_ADDR  = 5'h0;
        SEU_FRAME_NADDR  = 8'h0;
        SEU_COLUMN_NADDR = 8'h0;
        SEU_REGION_NADDR = 5'h0;
    end
endmodule
