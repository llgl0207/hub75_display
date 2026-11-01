`timescale 1ns/1ps
module tb_ir_debug_uart;
    reg clk=0,rst=1,update=0;
    wire tx;
    integer k,b;
    reg [7:0] value;
    reg [79:0] expected=80'h89abcdef12345678aa55;
    always #10 clk=~clk;
    ir_debug_uart dut(.clk(clk),.rst(rst),.update(update),
        .last_ticks(32'h12345678),.mean_ticks(32'h89abcdef),.tx(tx));
    initial begin
        repeat(4) @(negedge clk); rst=0;
        @(negedge clk); update=1;
        @(negedge clk); update=0;
    end
    initial begin
        wait(!rst);
        for(b=0;b<10;b=b+1) begin
            @(negedge tx);
            #4340; // center of start bit (434 clocks/bit, 20 ns/clock)
            if(tx!==0) $fatal(1,"start bit");
            for(k=0;k<8;k=k+1) begin
                #8680; value[k]=tx;
            end
            #8680;
            if(tx!==1 || value!==expected[b*8+:8])
                $fatal(1,"UART byte %0d got %h expected %h",b,value,expected[b*8+:8]);
        end
        $display("PASS: UART 115200 8N1 ten-byte snapshot"); $finish;
    end
    initial begin #2_000_000; $fatal(1,"UART timeout"); end
endmodule
