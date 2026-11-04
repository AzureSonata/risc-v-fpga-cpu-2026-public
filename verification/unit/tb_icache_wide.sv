`timescale 1ns/1ps
`include "defines.sv"
// The reference memory is address-derived, not read from the cache arrays.
// Covers both halves, per-word refill faults, held responses and hit turnover.
module tb_icache_wide;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg req_valid=0, rsp_ready=1, write=0;
    reg [31:0] addr=0;
    wire req_ready, rsp_valid, error, error_hi;
    wire [31:0] rdata, rdata_hi, line_addr;
    wire mem_read, mem_write, beat_ready, hit;
    reg beat_valid=0, beat_last=0, beat_error=0;
    reg [31:0] beat_data=0;
    wire [31:0] hits, misses;
    icache #(.FETCH_WORDS(2), .NEXT_LINE_PREFETCH(1)) dut(
      .clk(clk),.rst(rst),.req_valid(req_valid),.req_ready(req_ready),.addr(addr),
      .write(write),.wdata(32'b0),.wstrb(4'b0),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
      .rdata(rdata),.error(error),.rdata_hi(rdata_hi),.error_hi(error_hi),
      .line_addr(line_addr),.mem_read(mem_read),.mem_write(mem_write),
      .beat_valid(beat_valid),.beat_ready(beat_ready),.beat_data(beat_data),
      .beat_last(beat_last),.beat_error(beat_error),.hit_o(hit),.stat_hit(hits),.stat_miss(misses));
    function [31:0] mem_value(input [31:0] a);
      mem_value = (a * 32'h01010101) ^ 32'h5a19c3e7;
    endfunction
    integer state=0, beat=0, fills=0;
    reg [31:0] base;
    reg [3:0] inject=0, mask;
    always @(negedge clk) begin
      beat_valid=0;
      if(rst) begin state=0; beat=0; end
      else case(state)
        0: if(mem_read) begin base=line_addr; mask=inject; beat=0; state=1; fills=fills+1; end
        1: begin
          beat_valid=1; beat_data=mem_value(base+beat*4);
          beat_error=mask[beat]; beat_last=(beat==3);
        end
        2: if(mem_read && line_addr!=base) begin base=line_addr; mask=inject; beat=0; state=1; fills=fills+1; end
           else if(!mem_read) state=0;
      endcase
    end
    always @(posedge clk) begin
      if(!rst && beat_valid && beat_ready) begin
        if(beat==3) state=2; else beat=beat+1;
      end
    end
    integer checks=0;
    task check(input bit ok,input [255:0] text);
      begin checks=checks+1; if(!ok) $fatal(1,"FAIL %0s",text); end
    endtask
    task query(input [31:0] a,input [1:0] err,input integer hold_cycles);
      integer n,j;
      reg [63:0] saved;
      reg [1:0] saved_err;
      begin
        @(negedge clk); req_valid=1; addr=a; rsp_ready=0;
        n=0;
        begin : take_req
          while(n<100) begin
            @(posedge clk);
            if(req_ready) disable take_req;
            n=n+1;
          end
          $fatal(1,"request timeout %h",a);
        end
        @(negedge clk); req_valid=0;
        n=0;
        while(!rsp_valid && n<100) begin @(negedge clk); n=n+1; end
        check(rsp_valid,"response bounded");
        check({error_hi,error}===err,"per-word faults");
        if(a[2:0]==0) begin
          check(rdata===mem_value(a),"low address-derived data");
          check(rdata_hi===mem_value(a+4),"high address-derived data");
        end
        saved={rdata_hi,rdata}; saved_err={error_hi,error};
        for(j=0;j<hold_cycles;j=j+1) begin
          @(negedge clk); check(rsp_valid && {rdata_hi,rdata}===saved && {error_hi,error}===saved_err,"held payload");
        end
        rsp_ready=1;
        @(posedge clk);
        @(negedge clk);
      end
    endtask
    task sequential_nextline_prefetch;
      integer n, old_prefetch, old_hits;
      begin
        @(negedge clk); req_valid=1; addr=32'h300; rsp_ready=1;
        n=0;
        begin : request_first_line
          while(n<100) begin @(posedge clk); if(req_ready) disable request_first_line; n=n+1; end
          $fatal(1,"first line request timeout");
        end
        @(negedge clk); req_valid=0;
        n=0;
        while(!rsp_valid && n<100) begin @(negedge clk); n=n+1; end
        check(rsp_valid && rdata===mem_value(32'h300) && rdata_hi===mem_value(32'h304),
              "first line returns before refill tail");
        old_prefetch=dut.stat_prefetch;
        old_hits=dut.stat_prefetch_hit;
        @(posedge clk); // consume the first response while beats 2 and 3 remain
        @(negedge clk); req_valid=1; addr=32'h310;
        n=0;
        while(dut.stat_prefetch==old_prefetch && n<100) begin @(posedge clk); n=n+1; end
        check(dut.stat_prefetch==old_prefetch+1,"sequential line refill starts at prior line end");
        n=0;
        begin : request_prefetched_line
          while(n<100) begin @(posedge clk); if(req_ready) disable request_prefetched_line; n=n+1; end
          $fatal(1,"prefetched line request timeout");
        end
        @(negedge clk); req_valid=0;
        n=0;
        while(!rsp_valid && n<100) begin @(negedge clk); n=n+1; end
        check(rsp_valid && {error_hi,error}==0 && rdata===mem_value(32'h310) &&
              rdata_hi===mem_value(32'h314),"prefetched line supplies correct 64-bit block");
        check(dut.stat_prefetch_hit==old_hits+1,"prefetch service is counted once");
        @(posedge clk);
        @(negedge clk); rsp_ready=1;
      end
    endtask
    integer i, before_fills;
    reg stream=0;
    integer sent=0, received=0, cycle=0, first_cycle=0,last_cycle=0;
    reg [31:0] expected [0:63];
    always @(posedge clk) begin
      cycle=cycle+1;
      if(stream) begin
        if(rsp_valid && rsp_ready) begin
          check(received<sent,"no extra stream response");
          check({error_hi,error}==0,"stream no error");
          check(rdata===mem_value(expected[received]) && rdata_hi===mem_value(expected[received]+4),"stream ordering/data");
          received=received+1;
        end
        if(req_valid && req_ready) begin
          if(sent==0) first_cycle=cycle;
          last_cycle=cycle; expected[sent]=addr; sent=sent+1;
        end
      end
    end
    initial begin
      repeat(3) @(negedge clk); rst=0;
      query(0,0,3); query(8,0,0);
      query(0,0,0); query(8,0,0);
      before_fills=fills;
      @(negedge clk); stream=1; req_valid=1; addr=0;
      while(sent<32) begin @(negedge clk); addr=(sent%2)*8; end
      req_valid=0;
      repeat(4) @(negedge clk);
      stream=0;
      check(sent==32 && received==32,"all stream transactions complete");
      check(last_cycle-first_cycle==31,"one aligned block per cycle on hot hits");
      check(fills==before_fills,"stream does not refill");
      // Distinct lines ensure each injection is a cold fill. Repeat without
      // injection verifies a faulted line was not allocated.
      for(i=0;i<4;i=i+1) begin
        inject=4'b0001 << i;
        query(32'h100+i*32+(i>=2 ? 8:0), i[0] ? 2'b10:2'b01, 2);
        inject=0;
        query(32'h100+i*32+(i>=2 ? 8:0),0,0);
      end
      sequential_nextline_prefetch();
      query(4,2'b11,2);
      check(!mem_write,"read-only cache");
      $display("PASS: icache_wide %0d checks; 32 hot blocks accepted in 32 clocks",checks);
      $display("ALL TESTS PASSED (icache_wide)"); $finish;
    end
    initial begin #100000; $fatal(1,"watchdog"); end
endmodule
