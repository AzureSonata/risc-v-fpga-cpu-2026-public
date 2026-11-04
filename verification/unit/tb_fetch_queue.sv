`timescale 1ns/1ps
`include "defines.sv"

module tb_fetch_queue;
    reg clk = 1'b0;
    reg rst = `RstEnable;
    always #5 clk = ~clk;

    reg         in0_valid;
    reg  [31:0] in0_pc;
    reg  [31:0] in0_inst;
    reg         in0_fault;
    reg         in0_pred_valid;
    reg         in0_pred_taken;
    reg  [31:0] in0_pred_target;
    reg         in1_valid;
    reg  [31:0] in1_pc;
    reg  [31:0] in1_inst;
    reg         in1_fault;
    reg         in1_pred_valid;
    reg         in1_pred_taken;
    reg  [31:0] in1_pred_target;

    wire [1:0]  in_ready;
    wire        decode0_valid, decode1_valid;
    wire        out0_valid;
    wire [31:0] out0_pc, out0_inst, out0_pred_target;
    wire        out0_fault, out0_pred_valid, out0_pred_taken;
    wire        out1_valid;
    wire [31:0] out1_pc, out1_inst, out1_pred_target;
    wire        out1_fault, out1_pred_valid, out1_pred_taken;
    reg         out0_consume, out1_consume, flush;

    wire [98:0] out0_payload = {out0_pred_target, out0_pred_taken,
                                out0_pred_valid, out0_fault, out0_inst, out0_pc};
    wire [98:0] out1_payload = {out1_pred_target, out1_pred_taken,
                                out1_pred_valid, out1_fault, out1_inst, out1_pc};

    fetch_queue #(.DEPTH(4)) dut (
        .clk(clk), .rst(rst),
        .in0_valid(in0_valid), .in0_pc(in0_pc), .in0_inst(in0_inst),
        .in0_fault(in0_fault), .in0_pred_valid(in0_pred_valid),
        .in0_pred_taken(in0_pred_taken), .in0_pred_target(in0_pred_target),
        .in1_valid(in1_valid), .in1_pc(in1_pc), .in1_inst(in1_inst),
        .in1_fault(in1_fault), .in1_pred_valid(in1_pred_valid),
        .in1_pred_taken(in1_pred_taken), .in1_pred_target(in1_pred_target),
        .in_ready(in_ready),
        .decode0_valid(decode0_valid), .decode1_valid(decode1_valid),
        .out0_valid(out0_valid), .out0_pc(out0_pc), .out0_inst(out0_inst),
        .out0_fault(out0_fault), .out0_pred_valid(out0_pred_valid),
        .out0_pred_taken(out0_pred_taken), .out0_pred_target(out0_pred_target),
        .out1_valid(out1_valid), .out1_pc(out1_pc), .out1_inst(out1_inst),
        .out1_fault(out1_fault), .out1_pred_valid(out1_pred_valid),
        .out1_pred_taken(out1_pred_taken), .out1_pred_target(out1_pred_target),
        .out0_consume(out0_consume), .out1_consume(out1_consume),
        .flush(flush)
    );

    integer pass_count = 0;
    integer fail_count = 0;
    reg [98:0] model_entry [0:3];
    integer model_count = 0;
    integer cycle_idx;
    integer requested_pops;
    integer requested_pushes;
    integer effective_pops;
    integer expected_ready;
    integer survivor_count;
    integer accepted_pushes;
    integer model_idx;
    integer model_check_count = 0;
    integer model_fail_count = 0;
    reg [31:0] steering_lfsr;

    task check(input condition, input [1023:0] message);
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s", message);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s", message);
            end
        end
    endtask

    task check_model(input integer cycle_id);
        reg model_ok;
        begin
            model_ok = (decode0_valid == (model_count != 0)) &&
                       (decode1_valid == (model_count >= 2)) &&
                       (out0_valid == ((flush == `False) && (model_count != 0))) &&
                       (out1_valid == ((flush == `False) && (model_count >= 2)));
            if (model_count > 0)
                model_ok = model_ok && (out0_payload == model_entry[0]);
            if (model_count > 1)
                model_ok = model_ok && (out1_payload == model_entry[1]);
            if (model_ok) begin
                model_check_count = model_check_count + 1;
            end else begin
                model_fail_count = model_fail_count + 1;
                $display("FAIL: fetch_queue reference model mismatch at cycle %0d (model_count=%0d)",
                         cycle_id, model_count);
                $display("  decode=%b%b out_valid=%b%b payload0=%h expected0=%h payload1=%h expected1=%h",
                         decode1_valid, decode0_valid, out1_valid, out0_valid,
                         out0_payload, model_entry[0], out1_payload, model_entry[1]);
            end
        end
    endtask

    task clear_all;
        begin
            in0_valid = 1'b0; in1_valid = 1'b0;
            in0_pc = 32'h0; in0_inst = `INST_NOP; in0_fault = 1'b0;
            in0_pred_valid = 1'b0; in0_pred_taken = 1'b0; in0_pred_target = 32'h0;
            in1_pc = 32'h0; in1_inst = `INST_NOP; in1_fault = 1'b0;
            in1_pred_valid = 1'b0; in1_pred_taken = 1'b0; in1_pred_target = 32'h0;
            out0_consume = 1'b0; out1_consume = 1'b0; flush = 1'b0;
        end
    endtask

    task push1(input [31:0] pc, input [31:0] inst, input [31:0] tag);
        begin
            @(negedge clk);
            in0_valid = 1'b1; in0_pc = pc; in0_inst = inst;
            in0_pred_valid = 1'b1; in0_pred_taken = tag[0];
            in0_pred_target = tag;
            @(posedge clk); #1;
            in0_valid = 1'b0;
        end
    endtask

    task push2(input [31:0] pc0, input [31:0] inst0, input [31:0] tag0,
               input [31:0] pc1, input [31:0] inst1, input [31:0] tag1);
        begin
            @(negedge clk);
            in0_valid = 1'b1; in0_pc = pc0; in0_inst = inst0;
            in0_pred_valid = 1'b1; in0_pred_taken = tag0[0]; in0_pred_target = tag0;
            in1_valid = 1'b1; in1_pc = pc1; in1_inst = inst1;
            in1_pred_valid = 1'b1; in1_pred_taken = tag1[0]; in1_pred_target = tag1;
            @(posedge clk); #1;
            in0_valid = 1'b0; in1_valid = 1'b0;
        end
    endtask

    task pop2;
        begin
            @(negedge clk);
            out0_consume = 1'b1; out1_consume = 1'b1;
            @(posedge clk); #1;
            out0_consume = 1'b0; out1_consume = 1'b0;
        end
    endtask

    task pop1;
        begin
            @(negedge clk);
            out0_consume = 1'b1; out1_consume = 1'b0;
            @(posedge clk); #1;
            out0_consume = 1'b0;
        end
    endtask

    initial begin
        clear_all();
        repeat (3) @(posedge clk);
        #1;
        rst = `RstDisable;
        @(posedge clk); #1;

        check(out0_valid == 1'b0 && out1_valid == 1'b0 && in_ready == 2'd2,
              "empty queue: no output and two free slots");

        // 1. single push / single pop
        push1(32'h0000_1000, 32'h0000_0013, 32'hA000_0001);
        check(out0_valid == 1'b1 && out0_pc == 32'h0000_1000 &&
              out0_inst == 32'h0000_0013 && out0_pred_target == 32'hA000_0001,
              "single push is visible on out0");
        check(out1_valid == 1'b0 && in_ready == 2'd2,
              "single push leaves out1 empty and two slots free");

        push1(32'h0000_1004, 32'h0000_0013, 32'hA000_0002);
        check(out1_valid == 1'b1 && out1_pc == 32'h0000_1004,
              "second push is visible on out1");

        pop2();
        check(out0_valid == 1'b0 && out1_valid == 1'b0 && in_ready == 2'd2,
              "pop two drains the queue");

        // 2. dual push in one cycle
        push2(32'h0000_2000, 32'h0000_0001, 32'hB000_0001,
              32'h0000_2004, 32'h0000_0002, 32'hB000_0002);
        check(out0_valid == 1'b1 && out0_pc == 32'h0000_2000 &&
              out1_valid == 1'b1 && out1_pc == 32'h0000_2004,
              "dual push preserves program order");

        pop1();
        check(out0_valid == 1'b1 && out0_pc == 32'h0000_2004 &&
              out1_valid == 1'b0,
              "pop1 advances out1 into out0");

        // 3. fill to depth and check ready backpressure
        push2(32'h0000_3000, 32'h0000_0003, 32'hC000_0001,
              32'h0000_3004, 32'h0000_0004, 32'hC000_0002);
        @(negedge clk);
        out0_consume = 1'b1; out1_consume = 1'b1;
        #1;
        check(in_ready == 2'd1,
              "count=3 ready ignores same-cycle dual-pop credit");
        out0_consume = 1'b0; out1_consume = 1'b0;
        push1(32'h0000_3008, 32'h0000_0005, 32'hC000_0003);
        check(in_ready == 2'd0 && out0_pc == 32'h0000_2004 &&
              out1_pc == 32'h0000_3000,
              "queue full reports ready=0 and keeps oldest pair");

        // 4. Full-queue inputs are rejected even when two entries pop.
        // The producer must retry after occupancy registers the free slots.
        @(negedge clk);
        out0_consume = 1'b1; out1_consume = 1'b1;
        in0_valid = 1'b1; in0_pc = 32'h0000_4000; in0_inst = 32'h0000_0007;
        in0_pred_valid = 1'b1; in0_pred_target = 32'hD000_0001;
        in1_valid = 1'b1; in1_pc = 32'h0000_4004; in1_inst = 32'h0000_0008;
        in1_pred_valid = 1'b1; in1_pred_target = 32'hD000_0002;
        #1;
        check(in_ready == 2'd0,
              "full queue does not advertise unregistered pop credit");
        @(posedge clk); #1;
        out0_consume = 1'b0; out1_consume = 1'b0;
        in0_valid = 1'b0; in1_valid = 1'b0;
        check(out0_pc == 32'h0000_3004 && out1_pc == 32'h0000_3008,
              "full-queue pop2 keeps survivors and rejects unaccepted inputs");

        push2(32'h0000_4000, 32'h0000_0007, 32'hD000_0001,
              32'h0000_4004, 32'h0000_0008, 32'hD000_0002);

        pop2();
        check(out0_pc == 32'h0000_4000 && out1_pc == 32'h0000_4004,
              "after pop2 the new entries follow old survivor");

        // 5. flush clears everything
        @(negedge clk);
        flush = 1'b1;
        #1;
        check(decode0_valid == 1'b1 && decode1_valid == 1'b1 &&
              out0_valid == 1'b0 && out1_valid == 1'b0,
              "flush suppresses issue-valid but keeps decode occupancy separate");
        @(posedge clk); #1;
        flush = 1'b0;
        #1;
        $display("FLUSH_DEBUG flush=%b out0v=%b out1v=%b ready=%b count=%0d free=%0d post=%0d",
                 flush, out0_valid, out1_valid, in_ready, dut.count_q, dut.free_slots, dut.post_pop_count);
        check(out0_valid == 1'b0 && out1_valid == 1'b0 && in_ready == 2'd2,
              "flush clears the queue");

        // Exercise the full depth-4 steering state space with an independent
        // accepted-transaction FIFO model.  The LFSR sequence covers zero/one/
        // two pops, zero/one/two pushes, all occupancies, simultaneous
        // push/pop, backpressure, and periodic flushes without inspecting DUT
        // implementation state.
        model_count = 0;
        for (model_idx = 0; model_idx < 4; model_idx = model_idx + 1)
            model_entry[model_idx] = 99'd0;
        steering_lfsr = 32'h1ace_b00c;
        for (cycle_idx = 0; cycle_idx < 512; cycle_idx = cycle_idx + 1) begin
            @(negedge clk);
            steering_lfsr = {steering_lfsr[30:0],
                             steering_lfsr[31] ^ steering_lfsr[21] ^
                             steering_lfsr[1] ^ steering_lfsr[0]};
            requested_pops = (steering_lfsr[1:0] == 2'b00) ? 0 :
                             (steering_lfsr[1:0] == 2'b01) ? 1 : 2;
            requested_pushes = (steering_lfsr[3:2] == 2'b00) ? 0 :
                               (steering_lfsr[3:2] == 2'b01) ? 1 : 2;

            out0_consume = (requested_pops != 0);
            out1_consume = (requested_pops == 2);
            in0_valid = (requested_pushes >= 1);
            in1_valid = (requested_pushes >= 2);
            in0_pc = 32'h5000_0000 + (cycle_idx * 8);
            in0_inst = 32'h1000_0000 ^ cycle_idx;
            in0_fault = steering_lfsr[4];
            in0_pred_valid = steering_lfsr[5];
            in0_pred_taken = steering_lfsr[6];
            in0_pred_target = 32'hA500_0000 ^ cycle_idx;
            in1_pc = in0_pc + 32'd4;
            in1_inst = 32'h2000_0000 ^ cycle_idx;
            in1_fault = steering_lfsr[7];
            in1_pred_valid = steering_lfsr[8];
            in1_pred_taken = steering_lfsr[9];
            in1_pred_target = 32'h5A00_0000 ^ cycle_idx;
            flush = ((cycle_idx % 61) == 60);
            if (flush == `True) begin
                out0_consume = 1'b0;
                out1_consume = 1'b0;
            end
            #1;

            effective_pops = 0;
            if (out0_consume && (model_count != 0)) begin
                effective_pops = 1;
                if (out1_consume && (model_count >= 2))
                    effective_pops = 2;
            end
            if (flush == `True) begin
                expected_ready = 0;
            end else begin
                // Capacity is based on the pre-edge occupancy. Accepted
                // transactions still append after the effective pops below.
                expected_ready = 4 - model_count;
                if (expected_ready > 2)
                    expected_ready = 2;
            end
            if (in_ready !== expected_ready[1:0]) begin
                model_fail_count = model_fail_count + 1;
                $display("FAIL: fetch_queue ready mismatch at cycle %0d (got=%0d expected=%0d)",
                         cycle_idx, in_ready, expected_ready);
            end else begin
                model_check_count = model_check_count + 1;
            end

            @(posedge clk); #1;
            if (flush == `True) begin
                model_count = 0;
                for (model_idx = 0; model_idx < 4; model_idx = model_idx + 1)
                    model_entry[model_idx] = 99'd0;
            end else begin
                survivor_count = model_count - effective_pops;
                for (model_idx = 0; model_idx < survivor_count; model_idx = model_idx + 1)
                    model_entry[model_idx] = model_entry[model_idx + effective_pops];
                accepted_pushes = 0;
                if (in0_valid && (expected_ready >= 1)) begin
                    model_entry[survivor_count + accepted_pushes] =
                        {in0_pred_target, in0_pred_taken, in0_pred_valid,
                         in0_fault, in0_inst, in0_pc};
                    accepted_pushes = accepted_pushes + 1;
                end
                if (in0_valid && in1_valid && (expected_ready >= 2)) begin
                    model_entry[survivor_count + accepted_pushes] =
                        {in1_pred_target, in1_pred_taken, in1_pred_valid,
                         in1_fault, in1_inst, in1_pc};
                    accepted_pushes = accepted_pushes + 1;
                end
                model_count = survivor_count + accepted_pushes;
            end
            check_model(cycle_idx);
        end
        @(negedge clk);
        clear_all();
        check(model_fail_count == 0 && model_check_count == 1024,
              "independent FIFO reference model: 512 cycles, 1024 checks");

        if (fail_count == 0)
            $display("ALL TESTS PASSED (fetch_queue: %0d summaries; reference model: %0d/%0d checks)",
                     pass_count, model_check_count - model_fail_count, model_check_count);
        else
            $display("FETCH_QUEUE_RESULT: FAIL (%0d pass / %0d fail)", pass_count, fail_count);
        $finish;
    end

    initial begin
        #10000;
        $display("FETCH_QUEUE_RESULT: TIMEOUT");
        $finish;
    end
endmodule
