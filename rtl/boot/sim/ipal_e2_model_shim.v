// -----------------------------------------------------------------------------
// Filename     : ipal_e2_model_shim.v
// Description  : SIMULATION-ONLY shim/stubs for the Pango GTP_IPAL_E2 model.
//
//                The PDS 2022.2-SP6.4 simulation model
//                (arch/vendor/pango/verilog/simulation/GTP_IPAL_E2.v) is plain
//                Verilog at the top level, but it instantiates four submodules
//                that ship only as IEEE-1735 encrypted sources (.vp) under
//                .../simulation/modelsim10.2c/ipal_e2_source_codes/:
//
//                    ipal_e2_ispal  (slave parallel interface)
//                    ipal_e2_crc    (bitstream CRC check)
//                    ipal_e2_rbcrc  (readback CRC)
//                    ipal_e2_secded (SEU SECDED check)
//
//                Icarus Verilog cannot decrypt P1735 protected envelopes and no
//                ModelSim/Questa or VCS is installed on this machine, so this
//                file replaces those four submodules with:
//
//                  * ipal_e2_ispal : a functional "protocol observer" of the
//                    internal slave parallel interface.  Word assembly for
//                    X8/X16/X32 matches the documented interface (UG040005
//                    Table 7-2 / Figure 7-2): 1 beat per word in X32, 2 beats
//                    in X16, 4 beats in X8, CS_N framing the transfer, one
//                    data_valid pulse per assembled word, one re_rb pulse per
//                    read word.
//                  * ipal_e2_crc / ipal_e2_rbcrc / ipal_e2_secded : inert stubs
//                    (no error, index 0).  The warmboot sequence never issues
//                    RSTCRC / WCMEM / RCMEM / SEU commands, so these paths are
//                    not exercised by the warmboot test.
//
//                This shim is NOT synthesizable and must never be added to an
//                FPGA project; it exists only so that the vendor top-level
//                model can be compiled with iverilog for the A3 warmboot
//                sequence check.  A P1735-capable simulator (ModelSim/Questa
//                with the Pango license file) would use the encrypted sources
//                instead and drop this file.
// -----------------------------------------------------------------------------
`timescale 1 ns / 1 ps

// =============================================================================
// Internal slave parallel interface observer (write path functional)
// =============================================================================
module ipal_e2_ispal (
    input  wire        rstn,
    input  wire        clk,
    input  wire        en,
    input  wire [1:0]  m,          // 0 = X8, 1 = X16, 2 = X32
    input  wire [31:0] din,        // DI
    input  wire        cs_n,
    input  wire        rdwr_n,     // 0 = write, 1 = read
    input  wire        flg_desync,
    input  wire [31:0] data_rb,    // read data from register/cmem model
    output reg  [31:0] dout,       // DO
    output reg  [31:0] data,       // aligned 32-bit word
    output reg         data_valid, // one pulse per word
    output reg         re_rb       // one pulse per read word
);
    localparam [1:0] M_X8  = 2'd0;
    localparam [1:0] M_X16 = 2'd1;
    localparam [1:0] M_X32 = 2'd2;

    integer   beat;       // beat index inside the current word
    reg [31:0] acc;       // bytes/halfwords already collected
    reg        desync_d;  // flg_desync delayed (DESYNC is a level in the model)

    // flg_desync is the decoded CMDR==DESYNC level; the real interface uses it
    // to terminate the current transfer, so only its assertion (a pulse) may
    // reset the beat alignment.  Treating it as a permanent block would freeze
    // the interface after the first DESYNC command.
    wire desync_p = flg_desync & ~desync_d;

    initial begin
        dout       = 32'h0000_0000;
        data       = 32'h0000_0000;
        data_valid = 1'b0;
        re_rb      = 1'b0;
        beat       = 0;
        acc        = 32'h0000_0000;
        desync_d   = 1'b0;
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            beat       <= 0;
            acc        <= 32'h0000_0000;
            dout       <= 32'h0000_0000;
            data       <= 32'h0000_0000;
            data_valid <= 1'b0;
            re_rb      <= 1'b0;
            desync_d   <= 1'b0;
        end else if (en) begin
            data_valid <= 1'b0;
            re_rb      <= 1'b0;
            desync_d   <= flg_desync;

            if (cs_n) begin
                // CS_N high terminates the current beat alignment.
                beat <= 0;
            end else if (!rdwr_n) begin
                // ----------------------------- write -----------------------------
                case (m)
                    M_X32: begin
                        data       <= din;
                        data_valid <= 1'b1;
                        beat       <= 0;
                    end
                    M_X16: begin
                        if (desync_p || beat == 1) begin
                            data       <= {din[15:0], acc[15:0]};
                            data_valid <= 1'b1;
                            beat       <= 0;
                        end else begin
                            acc  <= {16'h0000, din[15:0]};
                            beat <= 1;
                        end
                    end
                    default: begin // M_X8
                        if (desync_p || beat == 3) begin
                            data       <= {din[7:0], acc[23:0]};
                            data_valid <= 1'b1;
                            beat       <= 0;
                        end else begin
                            acc  <= {din[7:0], acc[31:8]};
                            beat <= beat + 1;
                        end
                    end
                endcase
            end else begin
                // ----------------------------- read ------------------------------
                case (m)
                    M_X32: begin
                        dout  <= data_rb;
                        re_rb <= 1'b1;
                        beat  <= 0;
                    end
                    M_X16: begin
                        if (desync_p || beat == 1) begin
                            dout  <= {16'h0000, data_rb[31:16]};
                            re_rb <= 1'b1;
                            beat  <= 0;
                        end else begin
                            dout <= {16'h0000, data_rb[15:0]};
                            beat <= 1;
                        end
                    end
                    default: begin // M_X8
                        dout <= {24'h000000, data_rb[8*beat +: 8]};
                        if (desync_p || beat == 3) begin
                            re_rb <= 1'b1;
                            beat  <= 0;
                        end else begin
                            beat <= beat + 1;
                        end
                    end
                endcase
            end
        end
    end
endmodule

// =============================================================================
// Inert stubs (paths not used by the warmboot sequence)
// =============================================================================
module ipal_e2_crc (
    input  wire        rstn,
    input  wire        clk,
    input  wire [4:0]  regaddr,
    input  wire        id_err,
    input  wire        crc_disable,
    input  wire [31:0] data,
    input  wire        data_valid,
    input  wire        flg_write,
    input  wire        flg_rstcrc,
    input  wire [31:0] reg_crc,
    input  wire        prcfg_en,
    input  wire        prcfg_err,
    input  wire        drcfg_en,
    input  wire        drcfg_err,
    output wire        crc_err
);
    assign crc_err = 1'b0;
endmodule

module ipal_e2_rbcrc (
    input  wire        rstn,
    input  wire        clk,
    input  wire        rbcrc_en,
    input  wire [31:0] data,
    input  wire        data_valid,
    input  wire        flg_rrbcrc,
    input  wire        flg_rbcrc,
    input  wire        irstn,
    input  wire        iclk,
    output wire        rbcrc_err,
    output wire        rbcrc_valid
);
    assign rbcrc_err   = 1'b0;
    assign rbcrc_valid = 1'b0;
endmodule

module ipal_e2_secded (
    input  wire        rstn,
    input  wire        clk,
    input  wire        en,
    input  wire [6:0]  addr,
    input  wire        we,
    input  wire [31:0] din,
    output wire        flg_ecc_over,
    output wire        flg_sec,
    output wire        flg_ded,
    output wire [11:0] index
);
    assign flg_ecc_over = 1'b0;
    assign flg_sec      = 1'b0;
    assign flg_ded      = 1'b0;
    assign index        = 12'd0;
endmodule
