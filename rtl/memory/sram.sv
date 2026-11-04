// ============================================================================
//        SRAM / 主存（可缓存，单字 ready/valid 从端）
//
//        依据：docs/architecture/TECHNICAL_BASELINE.md §「接口和地址图」
//        「SRAM/主存 0x8000_0000 起 —— I/D Cache 可缓存；实际大小由板卡回填」
//
//        契约与 rom.sv 相同：上升沿握手、一次请求一次响应、
//        同步读（接受后下一拍响应）、valid && !ready 时载荷保持。
//
//        写：上升沿按 wstrb 做字节使能写入，与读同拍完成；
//        读改写不会发生冲突，因为本端口一次只接受一笔事务。
//        D-Cache 采用 write-through/no-write-allocate（基线 §「分支、Cache 与异常接入」），
//        因此命中的 store 会以单字写到达这里，本模块无需 burst 写支持。
// ============================================================================

`include "defines.sv"

module sram #(
    parameter [31:0]  BASE   = 32'h8000_0000,
    parameter integer DEPTH  = 16384,            // 字数，默认 64 KiB
    parameter integer AW     = 14,
    parameter [1023:0] INIT_FILE = 1024'd0       // 可选 $readmemh 初始化文件（0 = 不用）
)(
    input  wire         clk,
    input  wire         rst,

    input  wire         req_valid,
    output wire         req_ready,
    input  wire [31:0]  addr,
    input  wire         write,
    input  wire [31:0]  wdata,
    input  wire [3:0]   wstrb,

    output reg          rsp_valid,
    input  wire         rsp_ready,
    output reg  [31:0]  rdata,
    output wire         error
);

    // Each byte bank has one whole-byte write port. Do not combine these
    // into four partial writes to one array: the PDS input flow previously
    // treated that form as multiple write ports. Independent banks also avoid
    // feeding unselected old bytes back through the memory write-data path.
    reg [7:0] mem0 [0:DEPTH-1];
    reg [7:0] mem1 [0:DEPTH-1];
    reg [7:0] mem2 [0:DEPTH-1];
    reg [7:0] mem3 [0:DEPTH-1];

    wire accept = req_valid && req_ready;
    assign req_ready = ~rsp_valid;
    assign error     = 1'b0;

    wire [AW-1:0] widx = addr[AW+1:2];

    generate
        if (INIT_FILE != 1024'd0) begin : gen_init_file
            // This word array is used only at initialization to preserve the
            // existing 32-bit HEX format; it has no runtime readers or writers.
            reg [31:0] init_words [0:DEPTH-1];
            integer init_idx;
            initial begin
                for (init_idx = 0; init_idx < DEPTH; init_idx = init_idx + 1)
                    init_words[init_idx] = 32'h0000_0000;
                $readmemh(INIT_FILE, init_words);
                for (init_idx = 0; init_idx < DEPTH; init_idx = init_idx + 1) begin
                    mem0[init_idx] = init_words[init_idx][7:0];
                    mem1[init_idx] = init_words[init_idx][15:8];
                    mem2[init_idx] = init_words[init_idx][23:16];
                    mem3[init_idx] = init_words[init_idx][31:24];
                end
            end
        end else begin : gen_init_zero
`ifdef COREMARK_YOSYS_PREP
            // Yosys 0.66 spends over 20 minutes expanding the 16K-word
            // procedural zero-fill loop. The candidate builder supplies this
            // exact 16K-byte zero image as a frozen input; $readmemh preserves
            // the FPGA memory INIT values while keeping frontend elaboration
            // bounded. Normal simulation and synthesis use the original loop.
            initial begin
                $readmemh("src/memory/sram_zero_16384.mem", mem0);
                $readmemh("src/memory/sram_zero_16384.mem", mem1);
                $readmemh("src/memory/sram_zero_16384.mem", mem2);
                $readmemh("src/memory/sram_zero_16384.mem", mem3);
            end
`else
            integer init_idx;
            initial begin
                for (init_idx = 0; init_idx < DEPTH; init_idx = init_idx + 1) begin
                    mem0[init_idx] = 8'h00;
                    mem1[init_idx] = 8'h00;
                    mem2[init_idx] = 8'h00;
                    mem3[init_idx] = 8'h00;
                end
            end
`endif
        end
    endgenerate

    always @(posedge clk) begin
        if (rst == `RstDisable && accept && write && wstrb[0])
            mem0[widx] <= wdata[7:0];
    end
    always @(posedge clk) begin
        if (rst == `RstDisable && accept && write && wstrb[1])
            mem1[widx] <= wdata[15:8];
    end
    always @(posedge clk) begin
        if (rst == `RstDisable && accept && write && wstrb[2])
            mem2[widx] <= wdata[23:16];
    end
    always @(posedge clk) begin
        if (rst == `RstDisable && accept && write && wstrb[3])
            mem3[widx] <= wdata[31:24];
    end

    always @(posedge clk) begin
        if (rst == `RstEnable) begin
            rsp_valid <= 1'b0;
            rdata     <= `ZeroWord;
        end else begin
            if (accept) begin
                rsp_valid <= 1'b1;
                // The LSU consumes response data only for loads; store
                // responses acknowledge completion and ignore rdata. Keeping
                // the SRAM read result for both request types removes the
                // store-enable mux from the response-data path.
                // Nonblocking bank writes preserve the accepted old-word
                // response for stores as well as the synchronous load read.
                rdata     <= {mem3[widx], mem2[widx], mem1[widx], mem0[widx]};
            end else if (rsp_valid && rsp_ready) begin
                rsp_valid <= 1'b0;
            end
        end
    end

endmodule
