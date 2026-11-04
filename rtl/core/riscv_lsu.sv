//-----------------------------------------------------------------
// B1: EX/ALU - Load/Store Unit
// Address calculation, store mask, load formatting, D-side interface
// Based on ultraembedded/riscv (BSD license)
//-----------------------------------------------------------------

module riscv_lsu #(
    parameter WB_ON_RESPONSE = 1'b0,
    parameter TURNOVER_ON_RESPONSE = 1'b0,
    // When turnover is enabled, capture the replacement at the response edge
    // and present its registered request beginning in the next cycle.
    parameter REGISTER_TURNOVER_REQUEST = 1'b0,
    // Prepared-request mode: the integration core registers the effective
    // address and operands of the next memory instruction ahead of issue.
    // The D-side request payload is then driven only from those registers
    // (and from the LSU's own captured payload), never from the live
    // FQ/RF/bypass cone.  Legacy instantiations keep the port set below tied
    // to zero and this parameter at its default.
    parameter PREPARED_REQUEST = 1'b0,
    // Present-then-confirm accept (S3).  The request is presented in the
    // issue cycle exactly as in legacy mode, but the FSM samples req_ready_i
    // into accept_q and never puts the combinational ready in its next-state
    // equation.  A rejected request is re-presented from the registered
    // payload (REPRESENT) until it is accepted, so hit latency is unchanged.
    // Requires PREPARED_REQUEST=0 (the prepared packet mode has its own
    // presentation contract).
    parameter FAST_ACCEPT = 1'b0
) (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        valid_i,         // Input instruction valid
    input  logic [31:0] opcode_i,        // Instruction opcode
    input  logic [31:0] pc_i,            // PC
    input  logic [31:0] ra_operand_i,    // RS1 value (base address)
    input  logic [31:0] rb_operand_i,    // RS2 value (store data)
    input  logic        hold_i,          // Pipeline hold

    // Prepared request packet (used when PREPARED_REQUEST=1).  valid is
    // asserted only when the packet still matches the current FQ head and
    // the integration core permits the LSU to consume it.
    input  logic        prep_valid_i,
    input  logic [31:0] prep_pc_i,
    input  logic [31:0] prep_instr_i,
    input  logic [31:0] prep_addr_i,     // precomputed effective byte address
    input  logic [31:0] prep_rb_i,       // store data operand (unshifted)
    output logic        prep_take_o,     // packet consumed into the LSU this cycle

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
wire [3:0]    store_byte_lane_oh = 4'b0001 << addr[1:0];
wire [3:0]    store_half_lane_oh = addr[1] ? 4'b1100 : 4'b0011;

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
        // Build each byte lane from one-hot byte/halfword selects. Store widths
        // are mutually exclusive decode wires, so the OR terms cannot overlap.
        store_data = {
            ({8{req_sw}}                  & rb_operand_i[31:24]) |
            ({8{req_sb && store_byte_lane_oh[3]}} & rb_operand_i[7:0]) |
            ({8{req_sh && store_half_lane_oh[3]}} & rb_operand_i[15:8]),
            ({8{req_sw}}                  & rb_operand_i[23:16]) |
            ({8{req_sb && store_byte_lane_oh[2]}} & rb_operand_i[7:0]) |
            ({8{req_sh && store_half_lane_oh[2]}} & rb_operand_i[7:0]),
            ({8{req_sw}}                  & rb_operand_i[15:8]) |
            ({8{req_sb && store_byte_lane_oh[1]}} & rb_operand_i[7:0]) |
            ({8{req_sh && store_half_lane_oh[1]}} & rb_operand_i[15:8]),
            ({8{req_sw}}                  & rb_operand_i[7:0]) |
            ({8{req_sb && store_byte_lane_oh[0]}} & rb_operand_i[7:0]) |
            ({8{req_sh && store_half_lane_oh[0]}} & rb_operand_i[7:0])
        };
        store_wstrb = ({4{req_sb}} & store_byte_lane_oh) |
                      ({4{req_sh}} & store_half_lane_oh) |
                      ({4{req_sw}} & 4'b1111);
    end
end

//-----------------------------------------------------------------
// Outstanding Transaction Tracking
//-----------------------------------------------------------------
typedef enum logic [2:0] {
    IDLE,
    REQ_WAIT,       // 已锁存请求；请求已向 D 端口呈现但未被接受
    WAIT_RSP,
    MISALIGNED_ST,
    REPRESENT       // FAST_ACCEPT=1：未被接受的请求重新呈现（载荷来自 req_*_q）
} state_t;

state_t state_q;
localparam FAST_MODE = FAST_ACCEPT && !PREPARED_REQUEST;
logic        accept_q;      // FAST_ACCEPT=1：上一呈现沿采到的 req_ready_i

logic   is_store_q;
logic [31:0] addr_q;
logic        load_signed_q;
logic        req_lb_q, req_lh_q;
logic [ 4:0] rd_idx_q;      // 目的寄存器索引；须在首个使用点（下方时序块）之前声明

// PR #20 review #2：REQ_WAIT 期间保持的请求与上下文载荷。
// 组合信号（addr / store_data / store_wstrb / store_req）全部依赖当拍 valid_i，
// 上游一旦推进即消失，故必须在呈现拍锁存，等待期内由这些寄存器驱动 D 端口输出。
logic [31:0] req_addr_q, req_wdata_q;
logic [31:0] req_pc_q;
logic [3:0]  req_wstrb_q;
logic        req_write_q;
// FAST_ACCEPT derived timing: the accept sampled on the presentation edge is
// the only "ready" input the FSM consumes.  resp_cycle is WAIT_RSP, or the
// single transition cycle in which an accepted request may already have its
// response (hit path: no extra cycle versus legacy).
wire fast_wait_acc  = FAST_MODE && ((state_q == REQ_WAIT) || (state_q == REPRESENT));
wire acc_resp_cycle = fast_wait_acc && accept_q;
wire resp_cycle     = (state_q == WAIT_RSP) || acc_resp_cycle;
wire fast_replay    = fast_wait_acc && ~accept_q;

// A new aligned operation is presented directly to the D-side in IDLE. If it
// cannot be accepted immediately, the payload is captured below and held in
// REQ_WAIT. This removes the old capture-only cycle without weakening the
// valid/ready hold rule.
wire idle_request = (state_q == IDLE) && ~hold_i && ~misaligned &&
                    (load_req || store_req);
// In the dual-issue core, a younger cacheable memory instruction may replace
// a successful older load on the response edge. This identifies the incoming
// request independently of downstream ready: if it cannot handshake on this
// edge, its payload is captured and held in REQ_WAIT. Keeping ready out of this
// request-valid path breaks the LSU -> address decode -> cache ready feedback.
wire turnover_request = TURNOVER_ON_RESPONSE && WB_ON_RESPONSE &&
                        resp_cycle && rsp_valid_i && ~rsp_error_i &&
                        ~is_store_q && ~hold_i && ~misaligned &&
                        (load_req || store_req);

//-----------------------------------------------------------------
// Prepared request packet decode (PREPARED_REQUEST=1)
//-----------------------------------------------------------------
// The integration core registers the next memory instruction's effective
// address and store data ahead of issue.  Every field below is derived from
// those registers, so the presented request payload never depends on the live
// FQ/RF/bypass cone (the structural decoupling this mode exists for).
wire p_load_inst  = ((prep_instr_i & 32'h707f) == 32'h0003) ||
                    ((prep_instr_i & 32'h707f) == 32'h1003) ||
                    ((prep_instr_i & 32'h707f) == 32'h2003) ||
                    ((prep_instr_i & 32'h707f) == 32'h4003) ||
                    ((prep_instr_i & 32'h707f) == 32'h5003) ||
                    ((prep_instr_i & 32'h707f) == 32'h6003);
wire p_store_inst = ((prep_instr_i & 32'h707f) == 32'h0023) ||
                    ((prep_instr_i & 32'h707f) == 32'h1023) ||
                    ((prep_instr_i & 32'h707f) == 32'h2023);
wire p_load_signed = ((prep_instr_i & 32'h707f) == 32'h0003) ||
                     ((prep_instr_i & 32'h707f) == 32'h1003) ||
                     ((prep_instr_i & 32'h707f) == 32'h2003);
wire p_req_lb = ((prep_instr_i & 32'h707f) == 32'h0003) || ((prep_instr_i & 32'h707f) == 32'h4003);
wire p_req_lh = ((prep_instr_i & 32'h707f) == 32'h1003) || ((prep_instr_i & 32'h707f) == 32'h5003);
wire p_req_lw = ((prep_instr_i & 32'h707f) == 32'h2003) || ((prep_instr_i & 32'h707f) == 32'h6003);
wire p_req_sw = ((prep_instr_i & 32'h707f) == 32'h2023);
wire p_req_sh = ((prep_instr_i & 32'h707f) == 32'h1023);
wire p_req_sb = ((prep_instr_i & 32'h707f) == 32'h0023);

wire [31:0] p_addr = prep_addr_i;
wire [3:0]  p_byte_lane_oh = 4'b0001 << p_addr[1:0];
wire [3:0]  p_half_lane_oh = p_addr[1] ? 4'b1100 : 4'b0011;
wire        p_misaligned   = (p_req_lw || p_req_sw) ? (p_addr[1:0] != 2'b0) :
                             ((p_req_lh || p_req_sh) ? p_addr[0] : 1'b0);
wire        p_load_req  = PREPARED_REQUEST && prep_valid_i && p_load_inst  && ~p_misaligned;
wire        p_store_req = PREPARED_REQUEST && prep_valid_i && p_store_inst && ~p_misaligned;

logic [31:0] p_store_data;
logic [3:0]  p_store_wstrb;
always @* begin
    p_store_data  = '0;
    p_store_wstrb = 4'b0;
    if (PREPARED_REQUEST && prep_valid_i && p_store_inst && ~p_misaligned) begin
        p_store_data = {
            ({8{p_req_sw}}                       & prep_rb_i[31:24]) |
            ({8{p_req_sb && p_byte_lane_oh[3]}}  & prep_rb_i[7:0])   |
            ({8{p_req_sh && p_half_lane_oh[3]}}  & prep_rb_i[15:8]),
            ({8{p_req_sw}}                       & prep_rb_i[23:16]) |
            ({8{p_req_sb && p_byte_lane_oh[2]}}  & prep_rb_i[7:0])   |
            ({8{p_req_sh && p_half_lane_oh[2]}}  & prep_rb_i[7:0]),
            ({8{p_req_sw}}                       & prep_rb_i[15:8])  |
            ({8{p_req_sb && p_byte_lane_oh[1]}}  & prep_rb_i[7:0])   |
            ({8{p_req_sh && p_half_lane_oh[1]}}  & prep_rb_i[15:8]),
            ({8{p_req_sw}}                       & prep_rb_i[7:0])   |
            ({8{p_req_sb && p_byte_lane_oh[0]}}  & prep_rb_i[7:0])   |
            ({8{p_req_sh && p_half_lane_oh[0]}}  & prep_rb_i[7:0])
        };
        p_store_wstrb = ({4{p_req_sb}} & p_byte_lane_oh) |
                        ({4{p_req_sh}} & p_half_lane_oh) |
                        ({4{p_req_sw}} & 4'b1111);
    end
end

// The prepared packet is consumed either at IDLE (first presentation of a
// transaction) or on a successful load response when a younger request may
// continue on the same edge.  prep_take_o is the integration core's real
// issue event for lane0 memory instructions.
wire prep_take_idle = PREPARED_REQUEST && (state_q == IDLE) && ~hold_i &&
                      prep_valid_i && (p_load_inst || p_store_inst);
wire prep_take_turnover = PREPARED_REQUEST && (state_q == WAIT_RSP) && rsp_valid_i &&
                          TURNOVER_ON_RESPONSE && WB_ON_RESPONSE && ~rsp_error_i &&
                          ~is_store_q && ~hold_i && prep_valid_i &&
                          (p_load_inst || p_store_inst) && ~p_misaligned;
assign prep_take_o = prep_take_idle || prep_take_turnover;

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
        // Capture request and fault context on its first presentation. A same-
        // cycle handshake goes directly to WAIT_RSP; otherwise REQ_WAIT owns
        // the registered payload until downstream ready is asserted.
        if (PREPARED_REQUEST) begin
            if (prep_take_o) begin
                req_addr_q    <= {p_addr[31:2], 2'b0};
                req_write_q   <= p_store_req;
                req_wdata_q   <= p_store_data;
                req_wstrb_q   <= p_store_wstrb;
                req_pc_q      <= prep_pc_i;
                addr_q        <= p_addr;
                load_signed_q <= p_load_signed;
                req_lb_q      <= p_req_lb;
                req_lh_q      <= p_req_lh;
                rd_idx_q      <= prep_instr_i[11:7];
                is_store_q    <= p_store_inst;
            end
        end
        else if (((state_q == IDLE) || turnover_request) && ~hold_i && ~misaligned &&
            (load_req || store_req)) begin
            req_addr_q    <= {addr[31:2], 2'b0};
            req_write_q   <= store_req;
            req_wdata_q   <= store_data;
            req_wstrb_q   <= store_wstrb;
            req_pc_q      <= pc_i;
            addr_q        <= addr;
            load_signed_q <= load_signed;
            req_lb_q      <= req_lb;
            req_lh_q      <= req_lh;
            rd_idx_q      <= opcode_i[11:7];
            is_store_q    <= store_req;
        end

        case (state_q)
            IDLE: begin
                if (PREPARED_REQUEST) begin
                    if (prep_take_idle) begin
                        if (p_misaligned)
                            state_q <= MISALIGNED_ST;
                        else if (req_ready_i)
                            state_q <= WAIT_RSP;
                        else
                            state_q <= REQ_WAIT;
                    end
                end
                else if (misaligned && valid_i && (load_inst || store_inst)) begin
                    state_q <= MISALIGNED_ST;
                    // Preserve the offending byte address for the precise fault/mtval output.
                    addr_q <= addr;
                    is_store_q <= store_inst;
                    rd_idx_q <= opcode_i[11:7];
                    req_pc_q <= pc_i;
                end
                else if (idle_request) begin
                    if (FAST_MODE)
                        // Present-then-confirm: enter REQ_WAIT unconditionally;
                        // accept_q decides at the next edge, so the ready input
                        // is no longer in this next-state equation.
                        state_q <= REQ_WAIT;
                    else if (req_ready_i)
                        state_q <= WAIT_RSP;
                    else
                        state_q <= REQ_WAIT;
                end
            end
            REQ_WAIT, REPRESENT: begin
                if (!FAST_MODE) begin
                    // 握手完成才前进；此期间 valid 与载荷恒定，上游被 stall、MEM 不推进
                    if (req_ready_i)
                        state_q <= WAIT_RSP;
                end
                else if (!accept_q) begin
                    // 未被接受：保持同一请求（载荷来自 req_*_q），重新采样 ready
                    state_q <= REPRESENT;
                end
                else if (rsp_valid_i) begin
                    // 已接受且响应已到（命中路径）：与 WAIT_RSP 同拍处理
                    if (turnover_request)
                        state_q <= REQ_WAIT;
                    else
                        state_q <= IDLE;
                end
                else begin
                    state_q <= WAIT_RSP;
                end
            end
            WAIT_RSP: begin
                if (rsp_valid_i) begin
                    if (PREPARED_REQUEST) begin
                        if (prep_take_turnover) begin
                            if (REGISTER_TURNOVER_REQUEST)
                                state_q <= REQ_WAIT;
                            else if (req_ready_i)
                                state_q <= WAIT_RSP;
                            else
                                state_q <= REQ_WAIT;
                        end else begin
                            state_q <= IDLE;
                        end
                    end
                    else if (turnover_request) begin
                        if (REGISTER_TURNOVER_REQUEST || FAST_MODE)
                            state_q <= REQ_WAIT;
                        else if (req_ready_i)
                            state_q <= WAIT_RSP;
                        else
                            state_q <= REQ_WAIT;
                    end else begin
                        state_q <= IDLE;
                    end
                end
            end
            MISALIGNED_ST: begin
                state_q <= IDLE;
            end
        endcase
    end
end

// FAST_ACCEPT: sample the downstream accept on every presentation edge.  The
// sampled value (not the live ready) is what the FSM consumes on the next
// cycle, which keeps ready out of the state next-state/clock-enable cone.
always @(posedge clk_i) begin
    if (rst_i)
        accept_q <= 1'b0;
    else if (FAST_MODE)
        accept_q <= req_ready_i;
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
// Requests are driven from the current instruction in IDLE and from the
// captured payload in REQ_WAIT. Once backpressured, valid and all payload
// fields remain stable and are independent of upstream hold/input changes.
wire in_req_wait = (state_q == REQ_WAIT) || (FAST_MODE && (state_q == REPRESENT));
wire req_holding = in_req_wait;
wire request_in_flight = (state_q == REQ_WAIT) ||
                         ((state_q == WAIT_RSP) &&
                          (!turnover_request || REGISTER_TURNOVER_REQUEST));

// The prepared-request presentation draws every payload field from the
// registered packet.  In REQ_WAIT (or a WAIT_RSP cycle with no turnover) the
// LSU's own captured replay payload keeps valid/ready semantics unchanged.
wire prepared_use_old = (state_q == REQ_WAIT) ||
                        ((state_q == WAIT_RSP) && ~prep_take_turnover);

// FAST_MODE presentation: the request is valid whenever it is first presented
// (IDLE / turnover) or while a rejected request is re-presented from the
// registered payload.  None of these terms depends on req_ready_i.
wire fast_request_valid = idle_request || turnover_request || fast_replay;

assign req_valid_o = PREPARED_REQUEST
                   ? ((state_q == REQ_WAIT) ||
                      (prep_take_idle && ~p_misaligned) ||
                      prep_take_turnover)
                   : FAST_MODE
                   ? fast_request_valid
                   : (in_req_wait || idle_request ||
                      (turnover_request && !REGISTER_TURNOVER_REQUEST));
assign req_addr_o  = PREPARED_REQUEST
                   ? (prepared_use_old ? req_addr_q : {p_addr[31:2], 2'b0})
                   : FAST_MODE
                   ? (fast_replay ? req_addr_q : {addr[31:2], 2'b0})
                   : (request_in_flight ? req_addr_q : {addr[31:2], 2'b0});
assign req_write_o = PREPARED_REQUEST
                   ? (prepared_use_old ? req_write_q : p_store_req)
                   : FAST_MODE
                   ? (fast_replay ? req_write_q : store_req)
                   : (request_in_flight ? req_write_q : store_req);
assign req_wdata_o = PREPARED_REQUEST
                   ? (prepared_use_old ? req_wdata_q : p_store_data)
                   : FAST_MODE
                   ? (fast_replay ? req_wdata_q : store_data)
                   : (request_in_flight ? req_wdata_q : store_data);
assign req_wstrb_o = PREPARED_REQUEST
                   ? (prepared_use_old ? req_wstrb_q : p_store_wstrb)
                   : FAST_MODE
                   ? (fast_replay ? req_wstrb_q : store_wstrb)
                   : (request_in_flight ? req_wstrb_q : store_wstrb);
assign rsp_ready_o = resp_cycle;

//-----------------------------------------------------------------
// The dual-issue core can consume a successful response directly because its
// retirement shadow is ready on that same response cycle. Legacy single-issue
// integrations retain the registered writeback timing by default. Faults
// remain registered and held until acknowledged below.
//-----------------------------------------------------------------
wire success_response = resp_cycle && rsp_valid_i && ~rsp_error_i;
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
        wb_valid_q <= 1'b0;
        wb_result_q <= '0;
        fault_valid_q <= 1'b0;
        fault_misaligned_q <= 1'b0;
        fault_pc_q  <= '0;
        fault_rd_q  <= '0;
    end
    else begin
        wb_valid_q <= 1'b0;
        if (!WB_ON_RESPONSE && success_response) begin
            wb_valid_q <= 1'b1;
            wb_result_q <= load_result;
        end
        if (fault_consume)
            fault_valid_q <= 1'b0;
        if (state_q == MISALIGNED_ST) begin
            fault_valid_q <= 1'b1;
            fault_misaligned_q <= 1'b1;
            fault_pc_q <= (PREPARED_REQUEST || REGISTER_TURNOVER_REQUEST) ? req_pc_q : pc_i;
            fault_rd_q <= rd_idx_q;
        end
        else if (resp_cycle && rsp_valid_i) begin
            if (rsp_error_i) begin
                fault_valid_q <= 1'b1;
                fault_misaligned_q <= 1'b0;
                fault_pc_q <= (PREPARED_REQUEST || REGISTER_TURNOVER_REQUEST) ? req_pc_q : pc_i;
                fault_rd_q <= rd_idx_q;
            end
        end
    end
end

assign valid_o     = WB_ON_RESPONSE ? success_response : wb_valid_q;
assign result_o    = WB_ON_RESPONSE
                   ? ((success_response && ~is_store_q) ? load_result : 32'b0)
                   : wb_result_q;
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
// Stall upstream only while an unaccepted captured request or response is
// outstanding; an IDLE request is either accepted this cycle or captured at
// this edge before upstream state advances.
assign stall_o = req_holding || (resp_cycle && ~rsp_valid_i) || fault_backpressure;

//-----------------------------------------------------------------
// B3: Hazard Status
//-----------------------------------------------------------------
assign load_not_ready_o  = resp_cycle && ~is_store_q;
// In IDLE the LSU can accept a new instruction; an unaccepted D-side request
// is captured at the same edge and will be held in REQ_WAIT.
assign mem_advanceable_o = (state_q == IDLE) &&
                           ~((load_req || store_req) && ~hold_i && misaligned) &&
                           ~fault_backpressure;

endmodule
