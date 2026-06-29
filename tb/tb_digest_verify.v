// tb_digest_verify.v
// Validates the Digest article examples against actual RTL simulation.
// Drives 1.5 + 2.0 * 3.0 = 7.5 and dumps all internal pipeline registers.

`timescale 1ns / 1ps

module tb_digest_verify;

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

    fma_fp32_dot3 dut (.*);

    // Clock: 50 MHz
    always #10 clk = ~clk;

    task dump_stage1;
        begin
            #1;  // let NBAs settle
            $display("");
            $display("  === Stage 1 Registers (s2_*) @ %0t ===", $time);
            $display("  s2_valid      = %b", dut.s2_valid);
            $display("  s2_special    = %d (0=normal, 1=NaN, 2=+Inf, 3=-Inf)", dut.s2_special);
            $display("  s2_exp        = %0d (0x%02X)", dut.s2_exp, dut.s2_exp);
            $display("  s2_term1      = 0x%010X (addend, aligned)", dut.s2_term1);
            $display("  s2_term2      = 0x%010X (product, aligned)", dut.s2_term2);
            $display("  s2_term3      = 0x%010X (3rd term, dot only)", dut.s2_term3);
            $display("  s2_sign1      = %d  (0=zero, 1=pos, 2=neg)", dut.s2_sign1);
            $display("  s2_sign2      = %d", dut.s2_sign2);
            $display("  s2_sign3      = %d", dut.s2_sign3);
            $display("  s2_special_result = 0x%08X", dut.s2_special_result);
        end
    endtask

    task dump_stage2;
        begin
            #1;
            $display("");
            $display("  === Stage 2 Registers (s3_*) @ %0t ===", $time);
            $display("  s3_valid      = %b", dut.s3_valid);
            $display("  s3_special    = %d", dut.s3_special);
            $display("  s3_exp        = %0d (0x%02X)", dut.s3_exp, dut.s3_exp);
            $display("  s3_mant[39:0] = 0x%010X (absolute sum)", dut.s3_mant);
            $display("  s3_lod        = %0d (leading-zero count)", dut.s3_lod);
            $display("  s3_result_sign = %b", dut.s3_result_sign);
            $display("  s3_result_is_zero = %b", dut.s3_result_is_zero);
            $display("  s3_special_result = 0x%08X", dut.s3_special_result);

            // Show mantissa bit positions for Digest cross-check
            $display("  s3_mant bit analysis:");
            $display("    [39]=%b [38]=%b [37]=%b [36]=%b [35]=%b [34]=%b [33]=%b [32]=%b",
                dut.s3_mant[39], dut.s3_mant[38], dut.s3_mant[37], dut.s3_mant[36],
                dut.s3_mant[35], dut.s3_mant[34], dut.s3_mant[33], dut.s3_mant[32]);
            $display("    [31]=%b [30]=%b [29]=%b [28]=%b [27]=%b [26]=%b [25]=%b [24]=%b",
                dut.s3_mant[31], dut.s3_mant[30], dut.s3_mant[29], dut.s3_mant[28],
                dut.s3_mant[27], dut.s3_mant[26], dut.s3_mant[25], dut.s3_mant[24]);
            $display("    [23]=%b [22]=%b [21]=%b [20]=%b [19]=%b [18]=%b [17]=%b [16]=%b",
                dut.s3_mant[23], dut.s3_mant[22], dut.s3_mant[21], dut.s3_mant[20],
                dut.s3_mant[19], dut.s3_mant[18], dut.s3_mant[17], dut.s3_mant[16]);
            $display("    [15:8] = %08b", dut.s3_mant[15:8]);
            $display("    [7:0]  = %08b", dut.s3_mant[7:0]);
        end
    endtask

    task dump_output;
        begin
            #1;
            $display("");
            $display("  === Output @ %0t ===", $time);
            $display("  valid_o       = %b", valid_o);
            $display("  y_o           = 0x%08X", y_o);
            $display("  y_o decoded:  sign=%b exp=%0d(0x%02X) mant=0x%06X",
                y_o[31], y_o[30:23], y_o[30:23], y_o[22:0]);
        end
    endtask

    // ============================================================
    // Test 1: FMA 1.5 + 2.0 * 3.0 = 7.5 (the Digest worked example)
    // ============================================================
    task test_fma_1_5_plus_2_0_mul_3_0;
        begin
            $display("============================================================");
            $display("  DIGEST VERIFY: FMA 1.5 + 2.0 * 3.0 = 7.5");
            $display("============================================================");
            $display("  Input FP32 values:");
            $display("    A = 1.5  = 0x3FC00000  (sign=0 exp=7F mant=400000)");
            $display("    B = 2.0  = 0x40000000  (sign=0 exp=80 mant=000000)");
            $display("    C = 3.0  = 0x40400000  (sign=0 exp=80 mant=400000)");
            $display("    Expected: 7.5 = 0x40F00000");
            $display("");

            @(posedge clk);
            mode_i  <= 1'b0;
            a_i     <= 32'h3FC00000;  // 1.5
            b_i     <= 32'h40000000;  // 2.0
            c_i     <= 32'h40400000;  // 3.0
            dx_i    <= 12'd0;
            dy_i    <= 12'd0;
            dot_p_msb_i <= 2'd0;
            valid_i <= 1'b1;

            // After S1 processes inputs
            @(posedge clk);
            valid_i <= 1'b0;
            dump_stage1();

            // After S2
            @(posedge clk);
            dump_stage2();

            // After S3 = output
            @(posedge clk);
            dump_output();

            // Validate
            if (y_o === 32'h40F00000) begin
                $display("");
                $display("  [PASS] Output matches expected 0x40F00000 (7.5)");
                $display("  Digest values VERIFIED against simulation.");
            end else begin
                $display("");
                $display("  [FAIL] Expected 0x40F00000, got 0x%08X", y_o);
                $display("  Digest values may need correction.");
            end
        end
    endtask

    // ============================================================
    // Test 2: Extract exact unpacked mantissa values
    // ============================================================
    task test_unpack_values;
        begin
            $display("");
            $display("============================================================");
            $display("  DIGEST VERIFY: Unpack values check");
            $display("============================================================");

            // Drive a single cycle with clean values
            @(posedge clk);
            valid_i <= 1'b1;
            mode_i  <= 1'b0;
            a_i     <= 32'h3FC00000;  // 1.5
            b_i     <= 32'h40000000;  // 2.0
            c_i     <= 32'h40400000;  // 3.0
            dx_i    <= 12'd0;
            dy_i    <= 12'd0;
            dot_p_msb_i <= 2'd0;

            @(posedge clk);
            valid_i <= 1'b0;
            dump_stage1();

            // At this point s2_term1 is the aligned addend (A)
            // s2_term2 is the aligned product (B*C)
            // s2_exp is the anchor exponent

            $display("");
            $display("  Digest Article cross-check:");
            $display("    Article says: A_mant=1.5(0xC00000), B_mant=1.0(0x800000), C_mant=1.5(0xC00000)");
            $display("    Article says: prod_mant = B_mant*C_mant = 1.0*1.5 = 1.5 = 48'h600000000000");
            $display("    Article says: prod_exp = 128+128-127 = 129");
            $display("    Article says: A_exp = 127, anchor = max(129,127) = 129");
            $display("    Article says: A_aligned = A >> (129-127) = A >> 2 = 1.5/4 = 0.375");
            $display("");
            $display("  Actual RTL s2_exp = %0d", dut.s2_exp);
            $display("    (129 expected for anchor = max(prod_exp_adj, a_exp))", );
            $display("  Actual s2_term1 (addend)  = 0x%010X", dut.s2_term1);
            $display("  Actual s2_term2 (product) = 0x%010X", dut.s2_term2);
        end
    endtask

    // ============================================================
    // Test 3: Dot product worked example
    // ============================================================
    task test_dot_example;
        begin
            $display("");
            $display("============================================================");
            $display("  DIGEST VERIFY: Dot 1.0 + 2.0*1.0 + 3.0*1.0 = 6.0");
            $display("============================================================");
            $display("  Ps=1.0 (0x3F800000), Px=2.0 (0x40000000), Py=3.0 (0x40400000)");
            $display("  Dx=1.0 Q8.4=0x010, Dy=1.0 Q8.4=0x010, msb=2'b11");
            $display("  Expected: 6.0 = 0x40C00000");

            @(posedge clk);
            valid_i <= 1'b1;
            mode_i  <= 1'b1;         // Dot mode
            a_i     <= 32'h3F800000;  // Ps = 1.0
            b_i     <= 32'h40000000;  // Px = 2.0
            c_i     <= 32'h40400000;  // Py = 3.0
            dx_i    <= 12'h010;       // Dx = 1.0 in Q8.4
            dy_i    <= 12'h010;       // Dy = 1.0 in Q8.4
            dot_p_msb_i <= 2'b11;     // Both hidden bits = 1

            @(posedge clk);
            valid_i <= 1'b0;
            dump_stage1();

            @(posedge clk);
            dump_stage2();

            @(posedge clk);
            dump_output();

            if (y_o === 32'h40C00000)
                $display("  [PASS] Dot: 1+2*1+3*1 = 6.0 (0x40C00000)");
            else
                $display("  [FAIL] Expected 0x40C00000, got 0x%08X", y_o);
        end
    endtask

    // ============================================================
    // Test 4: Stage-3 normalization details (for Digest cross-check)
    // ============================================================
    task test_stage3_details;
        begin
            $display("");
            $display("============================================================");
            $display("  DIGEST VERIFY: Stage 3 normalization details");
            $display("============================================================");
            $display("  Checking: norm_exp, norm_mant, GRS bits, output packing");

            @(posedge clk);
            valid_i <= 1'b1;
            mode_i  <= 1'b0;
            a_i     <= 32'h3FC00000;  // 1.5
            b_i     <= 32'h40000000;  // 2.0
            c_i     <= 32'h40400000;  // 3.0
            dx_i    <= 12'd0;
            dy_i    <= 12'd0;
            dot_p_msb_i <= 2'd0;

            @(posedge clk);
            valid_i <= 1'b0;

            @(posedge clk);  // S2 done
            dump_stage2();
            $display("");
            $display("  Digest Article says:");
            $display("    sum = 1.875, MSB at bit position determined by LOD");
            $display("    norm_exp = anchor_exp + 1 - lod");
            $display("    norm_mant = shifted[39:16], guard=[15], round=[14], sticky=[13:0]");
            $display("");
            $display("  Actual RTL:");
            $display("    s3_exp = %0d, s3_lod = %0d", dut.s3_exp, dut.s3_lod);
            $display("    norm_exp_9 = s3_exp + 1 - s3_lod = %0d + 1 - %0d = %0d",
                dut.s3_exp, dut.s3_lod, dut.s3_exp + 1 - dut.s3_lod);
            $display("    s3_mant = 0x%010X", dut.s3_mant);

            @(posedge clk);
            dump_output();
            $display("    Final output: 0x%08X", y_o);
            $display("    Output sign=%b exp=%0d mant=0x%06X",
                y_o[31], y_o[30:23], y_o[22:0]);
        end
    endtask

    initial begin
        $dumpfile("tb_digest_verify.vcd");
        $dumpvars(0, tb_digest_verify);

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

        // Reset
        #100 rst_n = 1'b1;
        #30;

        // Run all verification tests
        test_fma_1_5_plus_2_0_mul_3_0();
        test_unpack_values();
        test_dot_example();
        test_stage3_details();

        $display("");
        $display("============================================================");
        $display("  DIGEST VERIFICATION COMPLETE");
        $display("============================================================");
        #100 $finish;
    end

endmodule
