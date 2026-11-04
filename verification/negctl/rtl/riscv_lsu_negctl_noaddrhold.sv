//-----------------------------------------------------------------
// B1: EX/ALU - Load/Store Unit
// Address calculation, store mask, load formatting, D-side interface
// Based on ultraembedded/riscv (BSD license)
//-----------------------------------------------------------------

module riscv_lsu (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        valid_i,         // Input instruction valid
    input  logic [31:0] opcode_i,        // Instruction opcode
    input  logic [31:0] pc_i,            // PC
    input  logic [31:0] ra_operand_i,    // RS1 value (base address)
    input  logic [31:0] rb_operand_i,    // RS2 value (store data)
    input  logic        hold_i,          // Pipeline hold

    // Memory request interface (to D-side)
    output logic        req_valid_o,     // Request valid
    input  logic        req_ready_i,     // Request accepted
    output logic [31:0] req_addr_o,      // Request address
    output logic        req_write_o,     // 1=write, 0=read
    output logic [31:0] req_wdata_o,     // Write data
    output logic [ 3:0] req_wstrb_o,     // Write strobe (byte enables)

    // Memory response interface (from D-side)
    input  logic        rsp_valid_i,     // Response valid
    output logic        rsp_ready_o,     // Response ready
    input  logic [31:0] rsp_rdata_i,     // Read data
    input  logic        rsp_error_i,     // Error

    // Fault event is held until the integration stage consumes it.
    output logic        fault_valid_o,
    input  logic        fault_ready_i,

    // Outputs
    output logic        valid_o,         // Output valid
    output logic [31:0] result_o,        // Load result（仅成功写回有效；访问错误/非对齐不再用地址充当结果）
    output logic        fault_o,         // PR #20 review #3：访问错误 / 非对齐故障
    output logic [31:0] fault_pc_o,      // 出错指令的 PC（供集成端归因）
    output logic [ 4:0] fault_rd_o,      // 出错指令的目的寄存器索引
    // 批 (b) 精确陷阱所需的两项故障归因（加性输出，不改变既有行为）：
    //   fault_misaligned_o：本次故障是否由**非对齐**引起 → 集成端区分
    //                       cause 4/6（load/store address misaligned）与 5/7（access fault）
    //   fault_addr_o      ：出错访问的**字节地址**（未被 {addr[31:2],2'b0} 抹掉低位）→ mtval
    output logic        fault_misaligned_o,
    output logic [31:0] fault_addr_o,
    output logic        stall_o,         // Stall upstream
    output logic [ 4:0] rd_idx_o,        // Destination register index

    // B3: Hazard status outputs
    output logic        load_not_ready_o,// Load outstanding, result not available
    output logic        mem_advanceable_o// MEM stage can advance (no stall needed)
);

`include "riscv_defs.svh"

//-----------------------------------------------------------------
// Instruction Decode (wires, resolve before any always block)
//-----------------------------------------------------------------
wire load_inst  = ((opcode_i & 32'h707f) == 32'h3)  ||
                  ((opcode_i & 32'h707f) == 32'h1003) ||
                  ((opcode_i & 32'h707f) == 32'h2003) ||
                  ((opcode_i & 32'h707f) == 32'h4003) ||
                  ((opcode_i & 32'h707f) == 32'h5003) ||
                  ((opcode_i & 32'h707f) == 32'h6003);

wire load_signed = ((opcode_i & 32'h707f) == 32'h3)  ||
                   ((opcode_i & 32'h707f) == 32'h1003) ||
                   ((opcode_i & 32'h707f) == 32'h2003);

wire store_inst = ((opcode_i & 32'h707f) == 32'h23)  ||
                  ((opcode_i & 32'h707f) == 32'h1023) ||
                  ((opcode_i & 32'h707f) == 32'h2023);

wire req_lb = ((opcode_i & 32'h707f) == 32'h3)  || ((opcode_i & 32'h707f) == 32'h4003);
wire req_lh = ((opcode_i & 32'h707f) == 32'h1003) || ((opcode_i & 32'h707f) == 32'h5003);
wire req_lw = ((opcode_i & 32'h707f) == 32'h2003) || ((opcode_i & 32'h707f) == 32'h6003);
wire req_sw = ((opcode_i & 32'h707f) == 32'h2023);
wire req_sh = ((opcode_i & 32'h707f) == 32'h1023);
wire req_sb = ((opcode_i & 32'h707f) == 32'h23);

//-----------------------------------------------------------------
// Combinational: addr, misaligned, request signals
// ALL in one always @* to guarantee determinism
//-----------------------------------------------------------------
logic [31:0]  addr;
logic [31:0]  store_data;
logic [3:0]   store_wstrb;
logic         store_req;
logic         misaligned;
logic         load_req;

always @* begin
    addr        = '0;
    store_data  = '0;
    store_wstrb = 4'b0;
    store_req   = 1'b0;
    misaligned  = 1'b0;
    load_req    = 1'b0;

    // Address calculation
    if (valid_i && load_inst)
        addr = ra_operand_i + {{20{opcode_i[31]}}, opcode_i[31:20]};
    else if (valid_i && store_inst)
        addr = ra_operand_i + {{20{opcode_i[31]}}, opcode_i[31:25], opcode_i[11:7]};

    // Misalignment detection
    if (valid_i) begin
        if (req_lw || req_sw)
            misaligned = (addr[1:0] != 2'b0);
        else if (req_lh || req_sh)
            misaligned = addr[0];
    end

    // Load request flag
    load_req = valid_i && load_inst && ~misaligned;

    // Store mask and data alignment
    if (valid_i && store_inst && ~misaligned) begin
        store_req = 1'b1;
        case (opcode_i[13:12])
            2'b00: begin
                case (addr[1:0])
                    2'h3: begin store_data = {rb_operand_i[7:0],24'h000000}; store_wstrb=4'b1000; end
                    2'h2: begin store_data = {8'h00,rb_operand_i[7:0],16'h0000}; store_wstrb=4'b0100; end
                    2'h1: begin store_data = {16'h0000,rb_operand_i[7:0],8'h00}; store_wstrb=4'b0010; end
                    2'h0: begin store_data = {24'h000000,rb_operand_i[7:0]}; store_wstrb=4'b0001; end
                endcase
            end
            2'b01: begin
                if (addr[1])
                    begin store_data={rb_operand_i[15:0],16'h0000}; store_wstrb=4'b1100; end
                else
                    begin store_data={16'h0000,rb_operand_i[15:0]}; store_wstrb=4'b0011; end
            end
            2'b10: begin
                store_data  = rb_operand_i;
                store_wstrb = 4'b1111;
            end
            default: ;
        endcase
    end
end

//-----------------------------------------------------------------
// Outstanding Transaction Tracking
//-----------------------------------------------------------------
typedef enum logic [2:0] {
    IDLE,
    REQ_WAIT,       // 请求已向 D 端口呈现但未被接受
    WAIT_RSP,
    MISALIGNED_ST
} state_t;

state_t state_q;
logic   is_store_q;
logic [31:0] addr_q;
logic        load_signed_q;
logic        req_lb_q, req_lh_q;
logic [ 4:0] rd_idx_q;      // 目的寄存器索引；须在首个使用点（下方时序块）之前声明

// PR #20 review #2：REQ_WAIT 期间保持的请求与上下文载荷。
// 组合信号（addr / store_data / store_wstrb / store_req）全部依赖当拍 valid_i，
// 上游一旦推进即消失，故必须在呈现拍锁存，等待期内由这些寄存器驱动 D 端口输出。
logic [31:0] req_addr_q, req_wdata_q;
logic [3:0]  req_wstrb_q;
logic        req_write_q;

always @(posedge clk_i) begin
    if (rst_i) begin
        state_q      <= IDLE;
        is_store_q   <= 1'b0;
        addr_q       <= '0;
        load_signed_q <= 1'b0;
        req_lb_q     <= 1'b0;
        req_lh_q     <= 1'b0;
    end
    else begin
        case (state_q)
            IDLE: begin
                if (misaligned && valid_i && (load_inst || store_inst)) begin
                    state_q <= MISALIGNED_ST;
                    addr_q <= addr;
                    is_store_q <= store_inst;
                    rd_idx_q <= opcode_i[11:7];
                end
                else if (load_req && req_ready_i && ~hold_i) begin
                    state_q <= WAIT_RSP;
                    // Hold the complete D-side request stable for the whole
                    // transaction.  The cache path may hand back req_ready
                    // early and then use the address during its internal line
                    // fill, while the full-core issue pulse has already gone.
                    req_addr_q    <= {addr[31:2], 2'b0};
                    req_write_q   <= 1'b0;
                    req_wdata_q   <= store_data;
                    req_wstrb_q   <= store_wstrb;
                    addr_q <= addr;
                    load_signed_q <= load_signed;
                    req_lb_q <= req_lb;
                    req_lh_q <= req_lh;
                    rd_idx_q <= opcode_i[11:7];
                    is_store_q <= 1'b0;
                end
                else if (store_req && req_ready_i && ~hold_i) begin
                    state_q <= WAIT_RSP;
                    req_addr_q    <= {addr[31:2], 2'b0};
                    req_write_q   <= 1'b1;
                    req_wdata_q   <= store_data;
                    req_wstrb_q   <= store_wstrb;
                    is_store_q <= 1'b1;
                    rd_idx_q <= opcode_i[11:7];
                    // 与 load 分支对齐：锁存字节地址，供故障归因（fault_addr_o → mtval）使用。
                    // 行为中性：addr_q 只被 load 的字节选择逻辑与故障归因读取，
                    // store 路径不依赖它（req_lb_q/req_lh_q 对 store 恒为 0）。
                    addr_q <= addr;
                end
                else if ((load_req || store_req) && ~hold_i) begin
                    // 已呈现但未被接受：进入等待态并锁存请求与上下文载荷。
                    // 此后 D 端口由锁存寄存器驱动，不再依赖上游 valid_i。
                    state_q       <= REQ_WAIT;
                    req_addr_q    <= {addr[31:2], 2'b0};
                    req_write_q   <= store_req;
                    req_wdata_q   <= store_data;
                    req_wstrb_q   <= store_wstrb;
                    addr_q        <= addr;
                    load_signed_q <= load_signed;
                    req_lb_q      <= req_lb;
                    req_lh_q      <= req_lh;
                    rd_idx_q      <= opcode_i[11:7];
                    is_store_q    <= store_inst;
                end
            end
            REQ_WAIT: begin
                // 握手完成才前进；此期间 valid 与载荷恒定，上游被 stall、MEM 不推进
                if (req_ready_i)
                    state_q <= WAIT_RSP;
            end
            WAIT_RSP: begin
                if (rsp_valid_i)
                    state_q <= IDLE;
            end
            MISALIGNED_ST: begin
                state_q <= IDLE;
            end
        endcase
    end
end

//-----------------------------------------------------------------
// Load Response Formatting
//-----------------------------------------------------------------
logic [31:0] load_result;

always @* begin
    load_result = '0;
    if (rsp_valid_i && ~rsp_error_i) begin
        if (req_lb_q) begin
            case (addr_q[1:0])
                2'h3: load_result = {24'b0, rsp_rdata_i[31:24]};
                2'h2: load_result = {24'b0, rsp_rdata_i[23:16]};
                2'h1: load_result = {24'b0, rsp_rdata_i[15:8]};
                2'h0: load_result = {24'b0, rsp_rdata_i[7:0]};
            endcase
            if (load_signed_q && load_result[7])
                load_result = {24'hFFFFFF, load_result[7:0]};
        end
        else if (req_lh_q) begin
            if (addr_q[1])
                load_result = {21'b0, rsp_rdata_i[31:16]};
            else
                load_result = {21'b0, rsp_rdata_i[15:0]};
            if (load_signed_q && load_result[15])
                load_result = {16'hFFFF, load_result[15:0]};
        end
        else begin
            load_result = rsp_rdata_i;
        end
    end
end

//-----------------------------------------------------------------
// Memory Request Interface (combinational)
//-----------------------------------------------------------------
// PR #20 review #2：请求呈现后须保持到 req_valid && req_ready。
// REQ_WAIT 期间由锁存寄存器驱动全部载荷，且 valid 不受 hold_i 影响 —— 已呈现的请求不得撤回。
wire in_req_wait = (state_q == REQ_WAIT);
// 「请求已呈现但尚未被接受」的窗口（含呈现当拍与整个 REQ_WAIT 态）
wire req_holding = in_req_wait ||
                   (state_q == IDLE && (load_req || store_req) && ~hold_i && ~req_ready_i);

assign req_valid_o = in_req_wait ? 1'b1        : (~hold_i && (state_q == IDLE) && (load_req || store_req));
assign req_addr_o  = in_req_wait ? req_addr_q  : {addr[31:2], 2'b0};
assign req_write_o = in_req_wait ? req_write_q : store_req;
assign req_wdata_o = in_req_wait ? req_wdata_q : store_data;
assign req_wstrb_o = in_req_wait ? req_wstrb_q : store_wstrb;
assign rsp_ready_o = (state_q == WAIT_RSP);

//-----------------------------------------------------------------
// Writeback Valid (Registered)
//-----------------------------------------------------------------
logic        wb_valid_q;
logic [31:0] wb_result_q;
// Fault is a held event: the consumer must acknowledge it before the LSU may
// advance to another transaction, otherwise the instruction attribution could
// be overwritten by a later fault.
logic        fault_valid_q;
// 故障类别：1=非对齐，0=访问错误（供集成端映射 cause 4/6 与 5/7）
logic        fault_misaligned_q;
// 故障归因上下文：出错时锁存当拍的 PC 与 rd。
// LSU 在 WAIT_RSP 期间 stall 上游，故采样时刻 pc_i 仍是该指令的 PC。
logic [31:0] fault_pc_q;
logic [ 4:0] fault_rd_q;

// A floating ready input is treated as ready for compatibility with older
// standalone instances. An explicit 0 applies backpressure until acknowledgement.
wire fault_ack = (fault_ready_i !== 1'b0);
wire fault_consume = fault_valid_q && fault_ack;
wire fault_backpressure = fault_valid_q && ~fault_ack;

always @(posedge clk_i) begin
    if (rst_i) begin
        wb_valid_q  <= 1'b0;
        wb_result_q <= '0;
        fault_valid_q <= 1'b0;
        fault_misaligned_q <= 1'b0;
        fault_pc_q  <= '0;
        fault_rd_q  <= '0;
    end
    else begin
        wb_valid_q  <= 1'b0;
        if (fault_consume)
            fault_valid_q <= 1'b0;
        if (state_q == MISALIGNED_ST) begin
            fault_valid_q <= 1'b1;
            fault_misaligned_q <= 1'b1;
            fault_pc_q <= pc_i;
            fault_rd_q <= rd_idx_q;
        end
        else if (state_q == WAIT_RSP && rsp_valid_i) begin
            if (rsp_error_i) begin
                fault_valid_q <= 1'b1;
                fault_misaligned_q <= 1'b0;
                fault_pc_q <= pc_i;
                fault_rd_q <= rd_idx_q;
            end
            else begin
                wb_valid_q  <= 1'b1;
                wb_result_q <= load_result;
            end
        end
    end
end

assign valid_o     = wb_valid_q;
assign result_o    = wb_result_q;
assign fault_o     = fault_valid_q;      // compatibility alias
assign fault_valid_o = fault_valid_q;
assign fault_pc_o  = fault_pc_q;
assign fault_rd_o  = fault_rd_q;
assign fault_misaligned_o = fault_misaligned_q;
assign fault_addr_o       = addr_q;
assign rd_idx_o = rd_idx_q;

//-----------------------------------------------------------------
// Stall: hold upstream when waiting for response
//-----------------------------------------------------------------
// PR #20 review #2：请求未被接受的窗口内必须 stall 上游，否则全局控制会推进并覆盖该条指令
assign stall_o = req_holding || (state_q == WAIT_RSP && ~rsp_valid_i) || fault_backpressure;

//-----------------------------------------------------------------
// B3: Hazard Status
//-----------------------------------------------------------------
assign load_not_ready_o  = (state_q == WAIT_RSP) && ~is_store_q;
// PR #20 review #2：请求未被接受的窗口内 MEM 不得推进。
// 注意只覆盖「未接受」窗口，**fire 当拍仍保持 mem_advanceable_o=1** ——
// 否则会与同拍 stall_o=0 自相矛盾：只按 mem_advanceable_o 判推进的集成端
// 会把指令永远留在 MEM 并反复重发同一请求。
assign mem_advanceable_o = (state_q == IDLE) &&
                           ~((load_req || store_req) && ~hold_i && ~req_ready_i) &&
                           ~fault_backpressure;

endmodule
