`timescale 1ns/1ps
// 115200 8N1 at 50 MHz. Ten bytes: 55 AA, last interval LE32, mean LE32.
// A snapshot is accepted only while idle; rotation events are far slower than TX.
module ir_debug_uart(input wire clk, input wire rst, input wire update,
    input wire [31:0] last_ticks, input wire [31:0] mean_ticks,
    output reg tx);
    localparam integer DIV = 434;
    reg [79:0] payload;
    reg [9:0] shift;
    reg [8:0] timer;
    reg [3:0] bit_index, byte_index;
    reg busy;
    always @(posedge clk) begin
        if (rst) begin
            tx<=1; busy<=0; timer<=0; bit_index<=0; byte_index<=0;
            payload<=0; shift<=10'h3ff;
        end else if (!busy) begin
            tx<=1;
            if (update) begin
                payload<={mean_ticks,last_ticks,16'haa55};
                shift<={1'b1,8'h55,1'b0};
                tx<=0; busy<=1; timer<=DIV-1; bit_index<=0; byte_index<=0;
            end
        end else if (timer != 0) timer<=timer-1'b1;
        else begin
            timer<=DIV-1;
            if (bit_index == 9) begin
                if (byte_index == 9) begin busy<=0; tx<=1; end
                else begin
                    payload<=payload>>8;
                    shift<={1'b1,payload[15:8],1'b0};
                    tx<=0; bit_index<=0; byte_index<=byte_index+1'b1;
                end
            end else begin
                shift<={1'b1,shift[9:1]}; tx<=shift[1]; bit_index<=bit_index+1'b1;
            end
        end
    end
endmodule
