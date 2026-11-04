`default_nettype none

// Versioned model storage interface. Images are generated from the binary
// packer outputs by tools/kws/export_model_rom_hex.py.
// Read ports are synchronous (one cycle), matching the OpenEye K4 contract.
//
// Model image selection is a compile-time choice so that every existing
// micro_speech-230c9 evidence run stays bit-exactly reproducible. Define
// KWS_MODEL_ZH_NEG selects the archived Chinese hard-negative model.
// KWS_MODEL_ZH_AUG selects the 2026-10-30 Chinese-augmented control model.
// The parameter lists remain explicit literals in both branches because Yosys
// 0.66 does not reliably constant-fold string concatenation in parameters.
`ifdef KWS_MODEL_ZH_NEG
`define KWS_DW_WEIGHTS_FILE "fpga/kws/generated/zh_neg_ab_20261101/readmemh/dw_weights.hex"
`define KWS_FC_WEIGHTS_FILE "fpga/kws/generated/zh_neg_ab_20261101/readmemh/fc_weights.hex"
`define KWS_BIAS_FILE       "fpga/kws/generated/zh_neg_ab_20261101/readmemh/bias.hex"
`define KWS_QUANT_FILE      "fpga/kws/generated/zh_neg_ab_20261101/readmemh/quant.hex"
`define KWS_DESC_FILE       "fpga/kws/generated/zh_neg_ab_20261101/readmemh/descriptor.hex"
`elsif KWS_MODEL_ZH_AUG
`define KWS_DW_WEIGHTS_FILE "fpga/kws/generated/model_zh_aug_s20261030/readmemh/dw_weights.hex"
`define KWS_FC_WEIGHTS_FILE "fpga/kws/generated/model_zh_aug_s20261030/readmemh/fc_weights.hex"
`define KWS_BIAS_FILE       "fpga/kws/generated/model_zh_aug_s20261030/readmemh/bias.hex"
`define KWS_QUANT_FILE      "fpga/kws/generated/model_zh_aug_s20261030/readmemh/quant.hex"
`define KWS_DESC_FILE       "fpga/kws/generated/model_zh_aug_s20261030/readmemh/descriptor.hex"
`else
`define KWS_DW_WEIGHTS_FILE "fpga/kws/generated/micro_speech-230c9/readmemh/dw_weights.hex"
`define KWS_FC_WEIGHTS_FILE "fpga/kws/generated/micro_speech-230c9/readmemh/fc_weights.hex"
`define KWS_BIAS_FILE       "fpga/kws/generated/micro_speech-230c9/readmemh/bias.hex"
`define KWS_QUANT_FILE      "fpga/kws/generated/micro_speech-230c9/readmemh/quant.hex"
`define KWS_DESC_FILE       "fpga/kws/generated/micro_speech-230c9/readmemh/descriptor.hex"
`endif
module kws_model_rom #(
    parameter [1023:0] DW_WEIGHTS_FILE = `KWS_DW_WEIGHTS_FILE,
    parameter [1023:0] FC_WEIGHTS_FILE = `KWS_FC_WEIGHTS_FILE,
    parameter [1023:0] BIAS_FILE       = `KWS_BIAS_FILE,
    parameter [1023:0] QUANT_FILE      = `KWS_QUANT_FILE,
    parameter [1023:0] DESC_FILE       = `KWS_DESC_FILE
)(
    input wire clk,
    input wire [15:0] dw_w_idx,
    input wire [31:0] fc_w_idx,
    input wire [15:0] bias_idx,
    input wire [15:0] quant_idx,
    output reg signed [7:0] dw_w_q,
    output reg signed [7:0] fc_w_q,
    output reg signed [31:0] bias_q,
    output reg signed [31:0] quant_mult,
    output reg signed [31:0] quant_shift,

    output reg [15:0] dw_ih, dw_iw, dw_oh, dw_ow,
    output reg [15:0] dw_kh, dw_kw, dw_sh, dw_sw, dw_pt, dw_pl, dw_cout,
    output reg signed [31:0] in_zp, dw_out_zp,
    output reg [15:0] fc_nin, fc_nout,
    output reg signed [31:0] fc_out_zp, act_min, act_max
);
    reg [7:0] dw_weights [0:639];
    reg [7:0] fc_weights [0:15999];
    reg [7:0] biases [0:47];
    reg [7:0] quant [0:95];
    reg [7:0] descriptors [0:255];

    initial begin
        $readmemh(DW_WEIGHTS_FILE, dw_weights);
        $readmemh(FC_WEIGHTS_FILE, fc_weights);
        $readmemh(BIAS_FILE, biases);
        $readmemh(QUANT_FILE, quant);
        $readmemh(DESC_FILE, descriptors);
    end

    function [31:0] desc_u32(input integer a);
        begin desc_u32 = {descriptors[a+3], descriptors[a+2], descriptors[a+1], descriptors[a]}; end
    endfunction
    function [31:0] desc_s32(input integer a);
        begin desc_s32 = desc_u32(a); end
    endfunction
    function [31:0] bias_u32(input integer a);
        begin bias_u32 = {biases[a+3], biases[a+2], biases[a+1], biases[a]}; end
    endfunction
    function [31:0] quant_u32(input integer a);
        begin quant_u32 = {quant[a+3], quant[a+2], quant[a+1], quant[a]}; end
    endfunction

    // Synchronous model parameter ports. Indexes follow the frozen K4 layouts:
    // OHWI DW weights, output-major FC weights, flat bias and {mult,shift} pairs.
    always @(posedge clk) begin
        dw_w_q <= $signed(dw_weights[dw_w_idx]);
        fc_w_q <= $signed(fc_weights[fc_w_idx]);
        bias_q <= $signed(bias_u32({bias_idx, 2'b00}));
        quant_mult <= $signed(quant_u32({quant_idx, 3'b000}));
        quant_shift <= $signed(quant_u32({quant_idx, 3'b000} + 4));

        // The two 128-byte descriptors are the source of the execution geometry
        // and quantization zero-points; no descriptor field is tied to zero.
        dw_ih <= desc_u32(16'h024);
        dw_iw <= desc_u32(16'h028);
        dw_oh <= desc_u32(16'h030);
        dw_ow <= desc_u32(16'h034);
        dw_cout <= desc_u32(16'h038);
        dw_kh <= {descriptors[16'h03d], descriptors[16'h03c]};
        dw_kw <= {descriptors[16'h03f], descriptors[16'h03e]};
        dw_sw <= {8'd0, descriptors[16'h040]};
        dw_sh <= {8'd0, descriptors[16'h041]};
        dw_pt <= {8'd0, descriptors[16'h044]};
        dw_pl <= {8'd0, descriptors[16'h046]};
        in_zp <= desc_s32(16'h048);
        dw_out_zp <= desc_s32(16'h04c);
        fc_nin <= desc_u32(16'h0e4);
        fc_nout <= desc_u32(16'h0e0);
        fc_out_zp <= desc_s32(16'h04c + 128);
        act_min <= desc_s32(16'h050);
        act_max <= desc_s32(16'h054);
    end
endmodule

`default_nettype wire
