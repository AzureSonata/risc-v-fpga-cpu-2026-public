(* blackbox *)
module GTP_PPLL #(
    parameter real CLKIN_FREQ=27.0, parameter LOCK_MODE=1'b0,
    parameter integer STATIC_RATIOI=1, STATIC_RATIOM=1, STATIC_RATIOF=63, STATIC_RATIO0=17,
    parameter integer STATIC_DUTYF=63, STATIC_DUTY0=17,
    parameter INTERNAL_FB="CLKOUTF", EXTERNAL_FB="DISABLE", BANDWIDTH="OPTIMIZED"
) (
    output CLKOUT0, output CLKOUT0N, output CLKOUT1, output CLKOUT1N, output CLKOUT2, output CLKOUT2N,
    output CLKOUT3, output CLKOUT3N, output CLKOUT4, output CLKOUTPHY, output CLKOUTPHYN,
    output CLKOUTF, output CLKOUTFN, output LOCK,
    output [15:0] APB_RDATA, output APB_READY,
    input CLKIN1, input CLKIN2, input CLKFB, input CLKIN_SEL,
    input CLKOUT0_SYN, input CLKOUT1_SYN, input CLKOUT2_SYN, input CLKOUT3_SYN,
    input CLKOUT4_SYN, input CLKOUTPHY_SYN, input CLKOUTF_SYN,
    input PLL_PWD, input RST, input APB_CLK, input APB_RST_N,
    input [4:0] APB_ADDR, input APB_SEL, input APB_EN, input APB_WRITE, input [15:0] APB_WDATA
);
endmodule
