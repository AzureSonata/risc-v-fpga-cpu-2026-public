// ============================================================================
//        4R2W Register File (M1-3)
//
//        Four combinational read ports, two synchronous write ports.
//        - x0 reads as zero and ignores writes.
//        - Same-cycle read bypass has independent rd/data inputs from the
//          architectural write ports, keeping queue-selected retirement data
//          off the operand path.
//        - Same-cycle write->read bypass is write-first.
//        - If both write ports target the same non-zero register, the younger
//          port (w1) wins.  issue_arb separately blocks WAW pairs; this is a
//          defensive definition for illegal/forced cases.
//        - This is a behavioural FF/mux implementation.  It is intentionally
//          not a dual-port RAM: PR #64 review warns that two-port RAM does not
//          automatically provide independent 4R2W semantics.
// ============================================================================
`include "defines.sv"

module regfile_4r2w (
    input  wire        clk,
    input  wire        rst,

    input  wire [4:0]  r0a_addr,
    output wire [31:0] r0a_data,
    input  wire [4:0]  r0b_addr,
    output wire [31:0] r0b_data,
    input  wire [4:0]  r1a_addr,
    output wire [31:0] r1a_data,
    input  wire [4:0]  r1b_addr,
    output wire [31:0] r1b_data,

    input  wire        w0_we,
    // Read-port bypass may be speculative at a trap boundary. Keep it separate
    // from w0_we, which is the architectural register-array write enable.
    input  wire        w0_bypass_we,
    input  wire [4:0]  w0_rd,
    input  wire [4:0]  w0_bypass_rd,
    input  wire [31:0] w0_data,
    input  wire [31:0] w0_bypass_data,
    input  wire        w1_we,
    // Keep read bypass independent from the architectural younger-slot write.
    input  wire        w1_bypass_we,
    input  wire [4:0]  w1_rd,
    input  wire [4:0]  w1_bypass_rd,
    input  wire [31:0] w1_data,
    input  wire [31:0] w1_bypass_data
);

    reg [31:0] regs [0:31];
    integer i;

    wire w0_write = w0_we && (w0_rd != 5'd0);
    wire w0_bypass = w0_bypass_we && (w0_bypass_rd != 5'd0);
    wire w1_write = w1_we && (w1_rd != 5'd0);
    wire w1_bypass = w1_bypass_we && (w1_bypass_rd != 5'd0);

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'h0;
        end else begin
            if (w0_write)
                regs[w0_rd] <= w0_data;
            if (w1_write)
                regs[w1_rd] <= w1_data;
        end
    end

    // Four independent combinational read muxes.  A Verilog function called
    // from a continuous assignment is only sensitive to its explicit inputs in
    // some simulators, so the register array change would not refresh the read
    // data.  Always blocks below explicitly make the mux sensitive to regs[].
    reg [31:0] r0a_data_r, r0b_data_r, r1a_data_r, r1b_data_r;

    always @* begin
        r0a_data_r = 32'h0;
        if (r0a_addr != 5'd0) begin
            if (w1_bypass && (w1_bypass_rd == r0a_addr)) r0a_data_r = w1_bypass_data;
            else if (w0_bypass && (w0_bypass_rd == r0a_addr)) r0a_data_r = w0_bypass_data;
            else r0a_data_r = regs[r0a_addr];
        end
    end

    always @* begin
        r0b_data_r = 32'h0;
        if (r0b_addr != 5'd0) begin
            if (w1_bypass && (w1_bypass_rd == r0b_addr)) r0b_data_r = w1_bypass_data;
            else if (w0_bypass && (w0_bypass_rd == r0b_addr)) r0b_data_r = w0_bypass_data;
            else r0b_data_r = regs[r0b_addr];
        end
    end

    always @* begin
        r1a_data_r = 32'h0;
        if (r1a_addr != 5'd0) begin
            if (w1_bypass && (w1_bypass_rd == r1a_addr)) r1a_data_r = w1_bypass_data;
            else if (w0_bypass && (w0_bypass_rd == r1a_addr)) r1a_data_r = w0_bypass_data;
            else r1a_data_r = regs[r1a_addr];
        end
    end

    always @* begin
        r1b_data_r = 32'h0;
        if (r1b_addr != 5'd0) begin
            if (w1_bypass && (w1_bypass_rd == r1b_addr)) r1b_data_r = w1_bypass_data;
            else if (w0_bypass && (w0_bypass_rd == r1b_addr)) r1b_data_r = w0_bypass_data;
            else r1b_data_r = regs[r1b_addr];
        end
    end

    assign r0a_data = r0a_data_r;
    assign r0b_data = r0b_data_r;
    assign r1a_data = r1a_data_r;
    assign r1b_data = r1b_data_r;

endmodule
