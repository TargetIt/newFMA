// Minimal verification for shared-multiplier design
`timescale 1ns / 1ps
module tb_fma_fp32_dot3;
    reg clk, rst_n, valid_i, mode_i;
    reg [31:0] a_i, b_i, c_i;
    reg [11:0] dx_i, dy_i;
    reg [1:0] dot_p_msb_i;
    wire valid_o; wire [31:0] y_o;
    fma_fp32_dot3 dut (.*);
    always #10 clk = ~clk;
    integer pass, fail;
    task check; input [255:0] nm; input [31:0] exp, act;
        begin if(exp===act) begin pass=pass+1; $display("[PASS] %0s",nm); end
        else begin fail=fail+1; $display("[FAIL] %0s exp=0x%08X act=0x%08X",nm,exp,act); end end
    endtask
    task fma; input [31:0] a,b,c,e; input [255:0] n;
        begin @(posedge clk); mode_i<=0; valid_i<=1; a_i<=a; b_i<=b; c_i<=c;
        @(posedge clk); valid_i<=0; repeat(2) @(posedge clk); check(n,e,y_o); end
    endtask
    task dot; input [31:0] ps,px,py; input [11:0] dx,dy; input [1:0] msb; input [31:0] e; input [255:0] n;
        begin @(posedge clk); mode_i<=1; valid_i<=1; a_i<=ps; b_i<=px; c_i<=py; dx_i<=dx; dy_i<=dy; dot_p_msb_i<=msb;
        @(posedge clk); valid_i<=0; repeat(3) @(posedge clk); check(n,e,y_o); end
    endtask
    initial begin
        clk=0; rst_n=0; valid_i=0; a_i=0; b_i=0; c_i=0; dx_i=0; dy_i=0; dot_p_msb_i=0; pass=0; fail=0;
        #100 rst_n=1; #30;
        fma(32'h3FC00000,32'h40000000,32'h40400000,32'h40F00000,"FMA 1.5+2*3=7.5");
        fma(32'h3F800000,32'h3F800000,32'h3F800000,32'h40000000,"FMA 1+1*1=2");
        fma(32'hBF800000,32'hC0000000,32'h40400000,32'hC0E00000,"FMA -1+-2*3=-7");
        fma(32'h40A00000,32'hC0000000,32'h40000000,32'h3F800000,"FMA 5+-2*2=1");
        fma(32'h3F000000,32'h40A00000,32'h40A00000,32'h41CC0000,"FMA 0.5+5*5=25.5");
        fma(32'h40400000,32'hBF800000,32'h40400000,32'h00000000,"FMA 3+-1*3=0");
        fma(32'h00000000,32'h40000000,32'h40400000,32'h40C00000,"FMA 0+2*3=6");
        fma(32'h7FC00000,32'h3F800000,32'h40000000,32'h7FC00000,"FMA NaN=>qNaN");
        fma(32'h3F800000,32'h7F800000,32'h00000000,32'h7FC00000,"FMA Inf*0=>qNaN");
        fma(32'h7F800000,32'h3F800000,32'h40000000,32'h7F800000,"FMA Inf=>Inf");
        dot(32'h3F800000,32'h40000000,32'h40400000,12'h010,12'h010,2'b11,32'h40C00000,"Dot 1+2*1+3*1=6");
        dot(32'h3F800000,32'h40000000,32'h40400000,12'h000,12'h010,2'b11,32'h40800000,"Dot dx=0");
        dot(32'h00000000,32'h3F800000,32'h00000000,12'h7FF,12'h000,2'b10,32'h42FFE000,"Dot max");
        dot(32'h00000000,32'h40000000,32'h00000000,12'h001,12'h000,2'b10,32'h3E000000,"Dot min");
        dot(32'h00000000,32'h40000000,32'hC0000000,12'h010,12'h010,2'b11,32'h00000000,"Dot cancel");
        $display("Results: %0d pass, %0d fail", pass, fail);
        if(fail==0) $display("ALL TESTS PASSED"); else $display("SOME FAILED");
    end
endmodule
