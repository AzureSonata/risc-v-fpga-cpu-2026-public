`timescale 1ns/1ps

module tb_pipeline_control;
    reg redirect_valid = 0;
    reg backend_hold = 0;
    reg load_use_stall = 0;

    wire pc_hold, if_id_hold, id_ex_hold, ex_mem_hold, mem_wb_hold;
    wire if_id_flush, id_ex_flush;
    wire id_ex_bubble, retire_block;

    integer checks = 0;

    pipeline_control dut (.*);

    task check_ok;
        input condition;
        input [8*64-1:0] label;
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("FAIL check %0d: %0s", checks, label);
                $fatal(1);
            end
        end
    endtask

    task set_events;
        input redirect_i;
        input backend_i;
        input load_use_i;
        begin
            redirect_valid = redirect_i;
            backend_hold = backend_i;
            load_use_stall = load_use_i;
            #1;
        end
    endtask

    initial begin
        #1000;
        $display("FAIL timeout");
        $fatal(1);
    end

    initial begin
        set_events(0, 0, 0);
        check_ok({pc_hold, if_id_hold, id_ex_hold, ex_mem_hold, mem_wb_hold,
                  if_id_flush, id_ex_flush,
                  id_ex_bubble, retire_block} == 11'b0,
                 "normal advances every stage");

        set_events(0, 0, 1);
        check_ok(pc_hold && if_id_hold, "load-use freezes PC and IF/ID");
        check_ok(id_ex_bubble && !id_ex_hold, "load-use injects ID/EX bubble");
        check_ok(!ex_mem_hold && !mem_wb_hold && !retire_block,
                 "load continues and older work may retire");
        check_ok(!if_id_flush && !id_ex_flush,
                 "load-use does not flush payloads");

        set_events(0, 1, 0);
        check_ok(pc_hold && if_id_hold && id_ex_hold && ex_mem_hold && mem_wb_hold,
                 "backend hold preserves every stage");
        check_ok(retire_block, "backend hold prevents duplicate retire");
        check_ok(!id_ex_bubble && !if_id_flush && !id_ex_flush &&
                 !id_ex_flush,
                 "backend hold does not destroy payloads");

        set_events(0, 1, 1);
        check_ok(id_ex_hold && !id_ex_bubble,
                 "backend hold wins over load-use bubble");

        set_events(1, 0, 0);
        check_ok(if_id_flush && id_ex_flush, "redirect clears younger stages");
        check_ok(!retire_block,
                 "redirect preserves older stages and retire");
        check_ok(!pc_hold && !if_id_hold && !id_ex_hold && !id_ex_bubble,
                 "redirect wins without retaining stale front end");

        set_events(1, 1, 1);
        check_ok(if_id_flush && id_ex_flush && id_ex_hold && !id_ex_bubble,
                 "redirect flushes young stages while back end remains held");
        check_ok(pc_hold && if_id_hold && ex_mem_hold && mem_wb_hold && retire_block,
                 "redirect never clears an older backend hold");

        // Exhaustively assert that no output is unknown for any input vector.
        for (integer events = 0; events < 8; events = events + 1) begin
            set_events(events[2], events[1], events[0]);
            check_ok((^{pc_hold, if_id_hold, id_ex_hold, ex_mem_hold, mem_wb_hold,
                         if_id_flush, id_ex_flush,
                         id_ex_bubble, retire_block}) !== 1'bx,
                     "all outputs remain known");
        end

        $display("PASS tb_pipeline_control (%0d checks)", checks);
        $finish;
    end
endmodule
