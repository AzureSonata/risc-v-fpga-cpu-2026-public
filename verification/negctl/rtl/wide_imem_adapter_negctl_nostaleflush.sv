// ============================================================================
//        64-bit I-fetch to 32-bit I-memory adapter
//
//        wide_fetch expects one 64-bit instruction block per request.  The
//        project cpu_mem_subsystem exposes a frozen 32-bit I port.  This
//        adapter serialises each 64-bit block into two word reads at
//        {base, base+4} and assembles the 64-bit response.
//
//        The adapter is intentionally conservative: one 32-bit request is
//        outstanding at a time.  It is a functional bridge, not a performance
//        path.
// ============================================================================
`include "defines.sv"

module wide_imem_adapter (
    input  wire        clk,
    input  wire        rst,

    // CPU side: matches wide_fetch
    input  wire        cpu_req_valid,
    output wire        cpu_req_ready,
    input  wire [31:0] cpu_req_addr,
    output wire        cpu_rsp_valid,
    input  wire        cpu_rsp_ready,
    output wire [63:0] cpu_rsp_data,
    output wire [1:0] cpu_rsp_error,

    // Memory side: 32-bit frozen project interface
    output wire        mem_req_valid,
    input  wire        mem_req_ready,
    output wire [31:0] mem_req_addr,
    output wire        mem_req_write,
    output wire [31:0] mem_req_wdata,
    output wire [3:0]  mem_req_wstrb,
    input  wire        mem_rsp_valid,
    output wire        mem_rsp_ready,
    input  wire [31:0] mem_rsp_rdata,
    input  wire        mem_rsp_error
);

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_CMD   = 3'd1;
    localparam [2:0] S_RESP  = 3'd2;
    localparam [2:0] S_DONE  = 3'd3;

    reg [2:0]  state_q;
    reg [31:0] base_q;
    reg [1:0]  beat_q;
    reg [31:0] low_q, high_q;
    reg [1:0]  err_q;

    wire [31:0] req_addr_w = base_q + (beat_q ? 32'd4 : 32'd0);
    wire        cpu_take = cpu_req_valid && cpu_req_ready;
    wire        mem_take = mem_req_valid && mem_req_ready;
    wire        mem_resp = mem_rsp_valid && mem_rsp_ready;

    assign cpu_req_ready = (state_q == S_IDLE) ||
                           (state_q == S_DONE && cpu_rsp_ready);

    assign mem_req_valid = (state_q == S_CMD);
    assign mem_req_addr  = req_addr_w;
    assign mem_req_write = 1'b0;
    assign mem_req_wdata = 32'h0;
    assign mem_req_wstrb = 4'h0;
    assign mem_rsp_ready = 1'b1;

    assign cpu_rsp_valid = (state_q == S_DONE);
    assign cpu_rsp_data  = {high_q, low_q};
    assign cpu_rsp_error = err_q;

    // mem_rsp_valid may legally arrive in the same cycle as the command
    // handshake for a zero-latency slave; both cases are handled below.
    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            state_q <= S_IDLE;
            base_q  <= 32'h0;
            beat_q  <= 1'b0;
            low_q   <= 32'h0;
            high_q  <= 32'h0;
            err_q   <= 1'b0;
        end else begin
            case (state_q)
                S_IDLE: begin
                    if (cpu_take) begin
                        base_q  <= cpu_req_addr;
                        beat_q  <= 1'b0;
                        low_q   <= 32'h0;
                        high_q  <= 32'h0;
                        err_q   <= 1'b0;
                        state_q <= S_CMD;
                    end
                end

                S_CMD: begin
                    if (mem_resp) begin
                        // capture response; issue next beat or finish
                        err_q[beat_q[0]] <= mem_rsp_error;
                        if (beat_q == 1'b0) begin
                            low_q   <= mem_rsp_rdata;
                            beat_q  <= 1'b1;
                            state_q <= S_CMD;
                        end else begin
                            high_q  <= mem_rsp_rdata;
                            state_q <= S_DONE;
                        end
                    end else if (mem_take) begin
                        state_q <= S_RESP;
                    end
                end

                S_RESP: begin
                    if (mem_resp) begin
                        err_q[beat_q[0]] <= mem_rsp_error;
                        if (beat_q == 1'b0) begin
                            low_q   <= mem_rsp_rdata;
                            beat_q  <= 1'b1;
                            state_q <= S_CMD;
                        end else begin
                            high_q  <= mem_rsp_rdata;
                            state_q <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    if ((cpu_rsp_valid && cpu_rsp_ready) || cpu_req_valid) begin // NEGCTL: new request may replace a backpressured response
                        if (cpu_req_valid) begin
                            base_q  <= cpu_req_addr;
                            beat_q  <= 1'b0;
                            low_q   <= 32'h0;
                            high_q  <= 32'h0;
                            err_q   <= 1'b0;
                            state_q <= S_CMD;
                        end else begin
                            state_q <= S_IDLE;
                        end
                    end
                    // Hold valid/data under backpressure. Only wide_fetch knows
                    // whether a response is stale; new req_valid is not cancel.

                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
