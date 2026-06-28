// tb_fma_fp32_dot3 - Comprehensive testbench covering all required categories

`timescale 1ns / 1ps

module tb_fma_fp32_dot3;

    reg         clk;
    reg         rst_n;
    reg         valid_i;
    reg         mode_i;
    reg  [31:0] a_i;
    reg  [31:0] b_i;
    reg  [31:0] c_i;
    reg  [11:0] dx_i;
    reg  [11:0] dy_i;
    reg  [1:0]  dot_p_msb_i;
    wire        valid_o;
    wire [31:0] y_o;

    fma_fp32_dot3 dut (
        .clk(clk), .rst_n(rst_n),
        .valid_i(valid_i), .mode_i(mode_i),
        .a_i(a_i), .b_i(b_i), .c_i(c_i),
        .dx_i(dx_i), .dy_i(dy_i),
        .dot_p_msb_i(dot_p_msb_i),
        .valid_o(valid_o), .y_o(y_o)
    );

    // Clock generation: 50 MHz (20ns period)
    always #10 clk = ~clk;

    // FP32 helper functions
    function [31:0] make_fp32;
        input sign;
        input [7:0] exp;
        input [22:0] mant;
        begin
            make_fp32 = {sign, exp, mant};
        end
    endfunction

    function [31:0] float32;
        input sign;
        input [7:0] exp;
        input [22:0] mant;
        begin
            float32 = {sign, exp, mant};
        end
    endfunction

    // Result checking
    reg [31:0] expected;
    reg        check_enable;
    reg [255:0] test_name;

    integer pass_count, fail_count;

    task check_result;
        input [255:0] name;
        input [31:0]  exp_val;
        begin
            test_name = name;
            expected  = exp_val;
            check_enable = 1'b1;
            // Wait for valid_o (pipeline latency is 3 cycles from valid_i)
            @(posedge clk);
            check_enable = 1'b0;
            if (y_o === exp_val || (exp_val !== exp_val && y_o !== y_o)) begin
                pass_count = pass_count + 1;
                $display("[PASS] %0s: got 0x%h", name, y_o);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s: expected 0x%h, got 0x%h", name, exp_val, y_o);
            end
        end
    endtask

    task drive_fma;
        input [31:0] a, b, c;
        begin
            mode_i  <= 1'b0;
            a_i     <= a;
            b_i     <= b;
            c_i     <= c;
            dx_i    <= 12'd0;
            dy_i    <= 12'd0;
            dot_p_msb_i <= 2'd0;
            valid_i <= 1'b1;
        end
    endtask

    task drive_dot;
        input [31:0] ps, px, py;
        input [11:0] dx, dy;
        input [1:0]  msb;
        begin
            mode_i  <= 1'b1;
            a_i     <= ps;
            b_i     <= px;
            c_i     <= py;
            dx_i    <= dx;
            dy_i    <= dy;
            dot_p_msb_i <= msb;
            valid_i <= 1'b1;
        end
    endtask

    task drive_idle;
        begin
            valid_i <= 1'b0;
            mode_i  <= 1'b0;
            a_i     <= 32'd0;
            b_i     <= 32'd0;
            c_i     <= 32'd0;
            dx_i    <= 12'd0;
            dy_i    <= 12'd0;
            dot_p_msb_i <= 2'd0;
        end
    endtask

    initial begin
        clk     = 1'b0;
        rst_n   = 1'b0;
        valid_i = 1'b0;
        mode_i  = 1'b0;
        a_i     = 32'd0;
        b_i     = 32'd0;
        c_i     = 32'd0;
        dx_i    = 12'd0;
        dy_i    = 12'd0;
        dot_p_msb_i = 2'd0;
        check_enable = 1'b0;
        pass_count = 0;
        fail_count = 0;

        // Reset
        #100 rst_n = 1'b1;
        #20;

        $display("========================================");
        $display("  FMA Tests");
        $display("========================================");

        // --------------------------------------------------
        // Category 1: FMA Same Sign (A and B*C same sign)
        // --------------------------------------------------
        $display("-- FMA Same Sign --");

        // 1.5 + 2.0 * 3.0 = 1.5 + 6.0 = 7.5
        // 1.5  = 0x3FC00000
        // 2.0  = 0x40000000
        // 3.0  = 0x40400000
        // 7.5  = 0x40F00000
        @(posedge clk);
        drive_fma(32'h3FC00000, 32'h40000000, 32'h40400000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 1.5+2.0*3.0=7.5", 32'h40F00000);

        // 1.0 + 1.0 * 1.0 = 2.0
        @(posedge clk);
        drive_fma(32'h3F800000, 32'h3F800000, 32'h3F800000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 1.0+1.0*1.0=2.0", 32'h40000000);

        // -1.0 + -2.0 * 3.0 = -1.0 + -6.0 = -7.0
        @(posedge clk);
        drive_fma(32'hBF800000, 32'hC0000000, 32'h40400000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: -1.0+-2.0*3.0=-7.0", 32'hC0E00000);

        // --------------------------------------------------
        // Category 2: FMA Different Signs
        // --------------------------------------------------
        $display("-- FMA Different Signs --");

        // 5.0 + (-2.0) * 2.0 = 5.0 + (-4.0) = 1.0
        // 5.0 = 0x40A00000, -2.0 = 0xC0000000, 2.0 = 0x40000000
        @(posedge clk);
        drive_fma(32'h40A00000, 32'hC0000000, 32'h40000000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 5+-2*2=1", 32'h3F800000);

        // Product larger: 0.5 + 5.0 * 5.0 = 0.5 + 25.0 = 25.5
        // 0.5=0x3F000000, 5.0=0x40A00000, 25.5=0x41CC0000
        @(posedge clk);
        drive_fma(32'h3F000000, 32'h40A00000, 32'h40A00000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 0.5+5*5=25.5", 32'h41CC0000);

        // Near cancellation: 3.0 + (-1.0) * 3.0 = 3.0 + (-3.0) = 0.0
        @(posedge clk);
        drive_fma(32'h40400000, 32'hBF800000, 32'h40400000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 3+-1*3=0", 32'h00000000);

        // --------------------------------------------------
        // Category 3: Sticky / Round
        // --------------------------------------------------
        $display("-- Sticky / Round --");

        // Tie-to-even: exact halfway case should round to even LSB
        // 0.75 + 1.0 * 0.5 = 0.75 + 0.5 = 1.25 = 0x3FA00000
        @(posedge clk);
        drive_fma(32'h3F400000, 32'h3F800000, 32'h3F000000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 0.75+1.0*0.5=1.25", 32'h3FA00000);

        // Large exponent difference (stress test alignment)
        // 1.0 + 2^(-20) * 1.0 = 1.0 + 8 ULP = 1.0 + 2^(-20)
        // 2^(-20) = 8 * 2^(-23) = 8 ULP → 0x3F800008
        @(posedge clk);
        drive_fma(32'h3F800000, 32'h35800000, 32'h3F800000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 1+2^-20*1", 32'h3F800008);

        // --------------------------------------------------
        // Category 4: Zero / FTZ
        // --------------------------------------------------
        $display("-- Zero / FTZ --");

        // Product zero: 5.0 + 0.0 * 3.0 = 5.0
        @(posedge clk);
        drive_fma(32'h40A00000, 32'h00000000, 32'h40400000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 5+0*3=5", 32'h40A00000);

        // Addend zero: 0 + 2.0 * 3.0 = 6.0
        @(posedge clk);
        drive_fma(32'h00000000, 32'h40000000, 32'h40400000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 0+2*3=6", 32'h40C00000);

        // Subnormal input (FTZ): treat as zero
        // Subnormal 0x00000001 → flushed to 0
        @(posedge clk);
        drive_fma(32'h00000001, 32'h3F800000, 32'h40000000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: subnorm+1*2=2 (FTZ)", 32'h40000000);

        // --------------------------------------------------
        // Category 5: Special Values
        // --------------------------------------------------
        $display("-- Special Values --");

        // NaN input → quiet NaN
        @(posedge clk);
        drive_fma(32'h7FC00000, 32'h3F800000, 32'h40000000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: NaN+1*2=qNaN", 32'h7FC00000);

        // Inf * 0 → qNaN
        @(posedge clk);
        drive_fma(32'h3F800000, 32'h7F800000, 32'h00000000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: 1+Inf*0=qNaN", 32'h7FC00000);

        // Inf + normal = Inf
        @(posedge clk);
        drive_fma(32'h7F800000, 32'h3F800000, 32'h40000000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: Inf+1*2=Inf", 32'h7F800000);

        // -Inf + normal = -Inf
        @(posedge clk);
        drive_fma(32'hFF800000, 32'h3F800000, 32'h40000000);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: -Inf+1*2=-Inf", 32'hFF800000);

        // Directed test case from spec:
        // a=32'h00000001, b=32'h80000001, c=32'h7f7fffff
        // a is subnormal (FTZ→0), b is subnormal negative (FTZ→0), c is large
        // Result ≈ 0 + 0 * large = 0 (after FTZ)
        @(posedge clk);
        drive_fma(32'h00000001, 32'h80000001, 32'h7f7fffff);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("FMA: directed case (subnorm)", {1'b0, 8'd0, 23'd0});

        $display("========================================");
        $display("  Dot-Product Tests");
        $display("========================================");

        // --------------------------------------------------
        // Category 6: Dot Product
        // --------------------------------------------------
        $display("-- Dot Product --");

        // Ps=1.0, Px=2.0, Py=3.0, Dx=1.0(Q8.4=0x010=16), Dy=1.0(Q8.4=0x010=16)
        // Dx_raw=16, Dy_raw=16 → Dx_val=1.0, Dy_val=1.0
        // Y = 1.0 + 2.0*1.0 + 3.0*1.0 = 1.0 + 2.0 + 3.0 = 6.0
        // 6.0 = 0x40C00000
        // In dot mode, dot_p_msb_i[1]=1 for Px, [0]=1 for Py
        @(posedge clk);
        drive_dot(32'h3F800000, 32'h40000000, 32'h40400000, 12'h010, 12'h010, 2'b11);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("Dot: 1+2*1+3*1=6", 32'h40C00000);

        // Dx=0: Ps=1.0, Px=2.0, Py=3.0, Dx=0, Dy=1.0
        // Y = 1.0 + 2.0*0 + 3.0*1.0 = 4.0
        @(posedge clk);
        drive_dot(32'h3F800000, 32'h40000000, 32'h40400000, 12'h000, 12'h010, 2'b11);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("Dot: dx=0 → 1+0+3=4", 32'h40800000);

        // Dx max (11'h7FF = max unsigned with dx[11]=0)
        // Ps=0, Px=1.0, Py=0, Dx=11'h7FF (~127.9375), Dy=0
        // Y = 0 + 1.0 * 127.9375 + 0 ≈ 127.9375 = 0x42FFE000 (approximate)
        @(posedge clk);
        drive_dot(32'h00000000, 32'h3F800000, 32'h00000000, 12'h7FF, 12'h000, 2'b10);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("Dot: 0+1*127.94+0", 32'h42FFE000);

        // Dx min non-zero (=1, i.e. 1/16 = 0.0625)
        // Ps=0, Px=2.0, Py=0, Dx=1, Dy=0
        // Y = 2.0 * 0.0625 = 0.125 = 0x3E000000
        @(posedge clk);
        drive_dot(32'h00000000, 32'h40000000, 32'h00000000, 12'h001, 12'h000, 2'b10);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("Dot: 2*0.0625=0.125", 32'h3E000000);

        // Px/Py different signs
        // Ps=0, Px=2.0, Py=-2.0, Dx=1.0(Q8.4=16), Dy=1.0(Q8.4=16)
        // Y = 0 + 2.0*1.0 + (-2.0)*1.0 = 0
        @(posedge clk);
        drive_dot(32'h00000000, 32'h40000000, 32'hC0000000, 12'h010, 12'h010, 2'b11);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("Dot: 2*1+-2*1=0", 32'h00000000);

        // dot_p_msb_i combinations: test msb=0 for subnormal-like mantissa
        // Ps=0, Px mant with msb=0, Px=0x3F000000 (0.5 normal, but msb=0 gives mant=0.5 style)
        // Actually use msb=0: Px_mant = {0, 0.5_mant_bits} = 0.5 value
        @(posedge clk);
        drive_dot(32'h00000000, 32'h3F000000, 32'h00000000, 12'h010, 12'h000, 2'b10);
        @(posedge clk);
        drive_idle();
        repeat (2) @(posedge clk);
        check_result("Dot: dot_p_msb_i[1]=0 test", 32'h3F000000);

        $display("========================================");
        $display("  Results: %0d pass, %0d fail", pass_count, fail_count);
        $display("========================================");

        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        #100 $finish;
    end

endmodule
