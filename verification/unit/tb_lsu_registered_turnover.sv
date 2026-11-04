`timescale 1ns/1ps

module tb_lsu_registered_turnover;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, valid = 0, hold = 0;
    reg [31:0] instr = 0, pc = 0, ra = 0, rb = 0;
    wire req_valid, req_write, rsp_ready, wb_valid, fault_valid;
    wire [31:0] req_addr, req_data, wb_data, fault_pc, fault_addr;
    wire [3:0] req_strb;
    wire [4:0] fault_rd;
    wire fault_misaligned;
    reg req_ready = 0, rsp_valid = 0, rsp_error = 0, fault_ready = 0;
    reg [31:0] rsp_data = 0;
    integer accepted = 0, writes = 0;

    riscv_lsu #(.WB_ON_RESPONSE(1), .TURNOVER_ON_RESPONSE(1),
                .REGISTER_TURNOVER_REQUEST(1)) dut (
        .clk_i(clk), .rst_i(rst), .valid_i(valid), .opcode_i(instr), .pc_i(pc),
        .ra_operand_i(ra), .rb_operand_i(rb), .hold_i(hold),
        .req_valid_o(req_valid), .req_ready_i(req_ready), .req_addr_o(req_addr),
        .req_write_o(req_write), .req_wdata_o(req_data), .req_wstrb_o(req_strb),
        .rsp_valid_i(rsp_valid), .rsp_ready_o(rsp_ready), .rsp_rdata_i(rsp_data),
        .rsp_error_i(rsp_error), .fault_valid_o(fault_valid), .fault_ready_i(fault_ready),
        .valid_o(wb_valid), .result_o(wb_data), .fault_o(), .fault_pc_o(fault_pc),
        .fault_rd_o(fault_rd), .fault_misaligned_o(fault_misaligned),
        .fault_addr_o(fault_addr), .stall_o(), .rd_idx_o(),
        .load_not_ready_o(), .mem_advanceable_o()
    );

    always @(posedge clk) begin
        if (!rst && req_valid && req_ready) begin
            accepted <= accepted + 1;
            if (req_write) writes <= writes + 1;
        end
    end

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        // First aligned load is accepted directly from IDLE.
        valid = 1; instr = 32'h00052083; pc = 32'h100; ra = 32'h80000000;
        req_ready = 1;
        #1;
        if (!req_valid || req_addr !== 32'h80000000 || req_write)
            $fatal(1, "initial load request wrong");
        @(posedge clk); #1;
        @(negedge clk);
        // Old load finishes while an independent younger store is issued.
        // Even with ready high it must not be exposed on this response edge.
        valid = 1; instr = 32'h00352223; pc = 32'h104;
        ra = 32'h80000000; rb = 32'haabbccdd;
        rsp_valid = 1; rsp_data = 32'h12345678; rsp_error = 0; req_ready = 1;
        #1;
        if (!rsp_ready || !wb_valid || wb_data !== 32'h12345678 || req_valid ||
            req_addr !== 32'h80000000)
            $fatal(1, "response edge exposed request or lost old result");
        @(posedge clk); #1;
        @(negedge clk);
        valid = 0; instr = 0; ra = 0; rb = 0; rsp_valid = 0; req_ready = 0; hold = 1;
        repeat (3) begin
            #1;
            if (!req_valid || req_addr !== 32'h80000004 || !req_write ||
                req_data !== 32'haabbccdd || req_strb !== 4'hf)
                $fatal(1, "registered store payload not held under backpressure");
            @(posedge clk); #1;
            @(negedge clk);
        end
        req_ready = 1;
        #1;
        if (!req_valid || req_addr !== 32'h80000004 || !req_write)
            $fatal(1, "registered store missing when ready released");
        @(posedge clk); #1;
        @(negedge clk);
        hold = 0; rsp_valid = 1; rsp_error = 0;
        // Store responses do not accept another turnover.
        valid = 1; instr = 32'h00052183; pc = 32'h108; ra = 32'h80000000;
        #1;
        if (req_valid || !rsp_ready || !wb_valid || wb_data !== 0)
            $fatal(1, "store response incorrectly accepted a younger request");
        @(posedge clk); #1;
        @(negedge clk);
        valid = 0; rsp_valid = 0;
        #1;
        if (accepted != 2 || writes != 1)
            $fatal(1, "first load/store handshakes=%0d writes=%0d", accepted, writes);

        // A failed old load must not capture or send the younger request.
        valid = 1; instr = 32'h00852283; pc = 32'h200; ra = 32'h80000000;
        #1;
        if (!req_valid || req_addr !== 32'h80000008 || req_write)
            $fatal(1, "fault scenario load request wrong");
        @(posedge clk); #1;
        @(negedge clk);
        valid = 1; instr = 32'h00352223; pc = 32'h204;
        rsp_valid = 1; rsp_error = 1; rsp_data = 32'hdeadbeef;
        #1;
        if (req_valid || wb_valid || !rsp_ready)
            $fatal(1, "fault response exposed younger request or successful writeback");
        @(posedge clk); #1;
        @(negedge clk);
        valid = 0; rsp_valid = 0; rsp_error = 0;
        repeat (2) begin
            #1;
            if (!fault_valid || fault_misaligned || fault_pc !== 32'h200 ||
                fault_rd !== 5'd5 || fault_addr !== 32'h80000008 || req_valid)
                $fatal(1, "held fault context or request suppression wrong");
            @(posedge clk); #1;
            @(negedge clk);
        end
        fault_ready = 1;
        @(posedge clk); #1;
        @(negedge clk);
        #1;
        if (fault_valid || accepted != 3 || writes != 1)
            $fatal(1, "duplicate/lost handshake or unconsumed fault");
        // A replacement load must retain byte offset and signedness after the
        // source instruction/operands disappear from the upstream interface.
        valid = 1; instr = 32'h00052083; pc = 32'h300; ra = 32'h80000000;
        req_ready = 1;
        #1;
        if (!req_valid || req_addr !== 32'h80000000)
            $fatal(1, "second initial load request wrong");
        @(posedge clk); #1;
        @(negedge clk);
        valid = 1; instr = 32'h00350303; pc = 32'h304; // lb x6,3(x10)
        rsp_valid = 1; rsp_data = 32'h12345678;
        #1;
        if (req_valid || !wb_valid || wb_data !== 32'h12345678)
            $fatal(1, "replacement-load capture corrupted old result");
        @(posedge clk); #1;
        @(negedge clk);
        valid = 0; instr = 0; pc = 0; ra = 0; rsp_valid = 0;
        #1;
        if (!req_valid || req_addr !== 32'h80000000 || req_write)
            $fatal(1, "replacement byte load not issued from captured tuple");
        @(posedge clk); #1;
        @(negedge clk);
        rsp_valid = 1; rsp_data = 32'h80000000;
        #1;
        if (!wb_valid || wb_data !== 32'hffffff80)
            $fatal(1, "replacement load lost signed byte formatting context");
        @(posedge clk); #1;
        @(negedge clk);
        rsp_valid = 0;
        #1;
        if (accepted != 5 || writes != 1)
            $fatal(1, "replacement load handshake count wrong");
        // Misaligned requests never reach the D-side and retain their PC even
        // after the upstream changes its inputs.
        valid = 1; instr = 32'h00152283; pc = 32'h400; ra = 32'h80000000;
        fault_ready = 0;
        #1;
        if (req_valid) $fatal(1, "misaligned load produced a request");
        @(posedge clk); #1;
        @(negedge clk);
        valid = 0; pc = 32'h404; ra = 0;
        @(posedge clk); #1;
        @(negedge clk); #1;
        if (!fault_valid || !fault_misaligned || fault_pc !== 32'h400 ||
            fault_rd !== 5'd5 || fault_addr !== 32'h80000001 || accepted != 5)
            $fatal(1, "misaligned fault context or side effects wrong");
        $display("PASS: registered turnover holds payload, accepts once, and preserves fault context");
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
