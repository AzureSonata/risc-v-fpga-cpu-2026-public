`timescale 1ns/1ps

// Draft K1 pipeline-control arbiter.
//
// This module deliberately consumes abstract events rather than member A/B
// payload or handshake signals. It defines this module's control policy;
// connecting the events to producer-specific signals remains an interface
// freeze point and must be reviewed separately.
//
// Stage1 scope deliberately excludes exception flushing.  A future precise
// trap interface must carry the exception's stage/age; a single global flush
// bit is not sufficient to preserve older instructions.
//
// A redirect may coincide with a blocked back end.  In that case the younger
// stages are invalidated while every older stage remains held and retirement
// stays blocked.  The eventual integration contract must keep the redirect
// target pending until the PC side accepts it.
module pipeline_control (
    input  wire redirect_valid,
    input  wire backend_hold,
    input  wire load_use_stall,

    output reg  pc_hold,
    output reg  if_id_hold,
    output reg  id_ex_hold,
    output reg  ex_mem_hold,
    output reg  mem_wb_hold,

    output reg  if_id_flush,
    output reg  id_ex_flush,
    output reg  id_ex_bubble,
    output reg  retire_block
);
    always @* begin
        pc_hold       = 1'b0;
        if_id_hold    = 1'b0;
        id_ex_hold    = 1'b0;
        ex_mem_hold   = 1'b0;
        mem_wb_hold   = 1'b0;
        if_id_flush   = 1'b0;
        id_ex_flush   = 1'b0;
        id_ex_bubble  = 1'b0;
        retire_block  = 1'b0;

        if (backend_hold) begin
            // Preserve every payload until the back end can advance.  Blocking
            // retire prevents a held MEM/WB transaction from committing twice.
            pc_hold      = 1'b1;
            if_id_hold   = 1'b1;
            id_ex_hold   = 1'b1;
            ex_mem_hold  = 1'b1;
            mem_wb_hold  = 1'b1;
            retire_block = 1'b1;
        end

        // NEGCTL：让 backend_hold **吞掉** redirect 的年轻冲刷 ⇒ 同拍 flush_id_ex=0，
        //         年轻 ID/EX 被保持而非丢弃（T13 契约破坏）。
        if (redirect_valid && !backend_hold) begin
            // EX redirect kills younger transactions even while older stages
            // are held.  No older-stage hold is cleared here.
            if_id_flush  = 1'b1;
            id_ex_flush  = 1'b1;
            id_ex_bubble = 1'b0;
        end else if (!backend_hold && load_use_stall) begin
            // The load continues downstream; its consumer stays in IF/ID and
            // ID/EX receives an invalid transaction for exactly this cycle.
            pc_hold      = 1'b1;
            if_id_hold   = 1'b1;
            id_ex_bubble = 1'b1;
        end
    end
endmodule
