// CPU-visible MMIO bridge for the SEN0327 PCM sample FIFO.
//
// Address window: 0x4000_2000..0x4000_2fff (the caller performs page decode).
//   +0x00 DATA     RO, signed PCM16 sign-extended; an accepted nonempty read pops
//   +0x04 LEVEL    RO, FIFO sample count in bits [9:0]
//   +0x08 STATUS   RO, bit0=nonempty, bit1=full, bit2=sticky overrun
//   +0x0c OVERRUN  bit0=sticky overrun; write bit0=1 to clear
// Empty DATA reads return zero without popping. Invalid or misaligned accesses
// return a bus error. Each accepted request produces one registered response.
`default_nettype none

module sen0327_audio_mmio #(
    parameter integer FIFO_DEPTH = 512
)(
    input  wire                 clk,
    input  wire                 rst,

    input  wire                 sample_valid,
    output wire                 sample_ready,
    input  wire signed [15:0]   sample_data,
    input  wire [9:0]           fifo_level,
    input  wire                 overrun,
    output wire                 overrun_clear,

    input  wire                 req_valid,
    output wire                 req_ready,
    input  wire [31:0]          addr,
    input  wire                 write,
    input  wire [31:0]          wdata,
    input  wire [3:0]           wstrb,
    output wire                 rsp_valid,
    input  wire                 rsp_ready,
    output wire [31:0]          rdata,
    output wire                 error
);
    localparam [11:0] REG_DATA    = 12'h000;
    localparam [11:0] REG_LEVEL   = 12'h004;
    localparam [11:0] REG_STATUS  = 12'h008;
    localparam [11:0] REG_OVERRUN = 12'h00c;

    reg        rsp_valid_q;
    reg [31:0] rsp_data_q;
    reg        rsp_error_q;

    wire req_fire = req_valid && req_ready;
    wire [11:0] offset = addr[11:0];
    wire aligned = (addr[1:0] == 2'b00);

    assign req_ready = !rsp_valid_q || rsp_ready;
    assign rsp_valid = rsp_valid_q;
    assign rdata = rsp_data_q;
    assign error = rsp_error_q;

    // Pop only on the accepted CPU read, and only if a sample exists.
    assign sample_ready = req_fire && !write && aligned &&
                          (offset == REG_DATA) && sample_valid;
    assign overrun_clear = req_fire && write && aligned &&
                           (offset == REG_OVERRUN) &&
                           wstrb[0] && wdata[0];

    wire fifo_full = (fifo_level == FIFO_DEPTH);

    always @(posedge clk) begin
        if (rst) begin
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 32'd0;
            rsp_error_q <= 1'b0;
        end else begin
            if (rsp_valid_q && rsp_ready)
                rsp_valid_q <= 1'b0;

            if (req_fire) begin
                rsp_valid_q <= 1'b1;
                rsp_data_q  <= 32'd0;
                rsp_error_q <= 1'b0;

                if (!aligned) begin
                    rsp_error_q <= 1'b1;
                end else begin
                    case (offset)
                        REG_DATA: begin
                            if (write) begin
                                rsp_error_q <= 1'b1;
                            end else if (sample_valid) begin
                                rsp_data_q <= {{16{sample_data[15]}}, sample_data};
                            end
                        end
                        REG_LEVEL: begin
                            if (write)
                                rsp_error_q <= 1'b1;
                            else
                                rsp_data_q <= {22'd0, fifo_level};
                        end
                        REG_STATUS: begin
                            if (write)
                                rsp_error_q <= 1'b1;
                            else
                                rsp_data_q <= {29'd0, overrun, fifo_full, sample_valid};
                        end
                        REG_OVERRUN: begin
                            if (write)
                                rsp_data_q <= {31'd0, overrun};
                            else
                                rsp_data_q <= {31'd0, overrun};
                        end
                        default: rsp_error_q <= 1'b1;
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
