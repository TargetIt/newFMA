// fma_fp32_dot3 - FP32 FMA / Dot-Product (3-stage pipeline)
// Area-optimized approximate FMA, not bit-exact fused FMA.
// RN-even rounding, input/output FTZ.

`timescale 1ns / 1ps

module fma_fp32_dot3 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_i,
    input  wire        mode_i,       // 0: FMA (Y=A+B*C), 1: Dot (Y=Ps+Px*Dx+Py*Dy)
    input  wire [31:0] a_i,          // FMA: A,  Dot: Ps
    input  wire [31:0] b_i,          // FMA: B,  Dot: Px
    input  wire [31:0] c_i,          // FMA: C,  Dot: Py
    input  wire [11:0] dx_i,         // FMA: ignored, Dot: unsigned Q8.4 (dx_i[11]=0)
    input  wire [11:0] dy_i,         // FMA: ignored, Dot: unsigned Q8.4 (dy_i[11]=0)
    input  wire [1:0]  dot_p_msb_i,  // FMA: ignored, Dot: [1]=Px mant MSB, [0]=Py mant MSB
    output reg         valid_o,
    output reg  [31:0] y_o
);

    // ============================================================
    // Parameters
    // ============================================================
    localparam EXP_W    = 8;
    localparam MANT_W   = 23;
    localparam BIAS     = 127;
    localparam MANT_FULL = 24;  // mantissa width (1 hidden + 23 fraction)
    localparam MUL_W    = 48;   // 24b x 24b product width
    localparam INT_W    = 28;   // internal datapath: hard minimum (INT_W-27 >= 0)
    localparam AD_PAD   = INT_W - 1 - MANT_FULL;  // addend trailing zeros
    localparam PR_PAD   = 0;    // product truncated to fit

    // Shared multiplier — exactly ONE * instance for Yosys
    reg  [23:0] mult_a, mult_b;
    wire [47:0] shared_product;
    assign shared_product = mult_a * mult_b;

    // Area-efficient logarithmic right shifter (replaces barrel shifter)
    function [INT_W-1:0] log_shr;
        input [INT_W-1:0] data;
        input [5:0] shamt;
        reg [INT_W-1:0] s;
        begin
            s = data;
            if (shamt[5]) s = s >> 6'd32;
            if (shamt[4]) s = s >> 6'd16;
            if (shamt[3]) s = s >> 6'd8;
            if (shamt[2]) s = s >> 6'd4;
            if (shamt[1]) s = s >> 6'd2;
            if (shamt[0]) s = s >> 6'd1;
            log_shr = s;
        end
    endfunction

    // Area-efficient logarithmic left shifter
    function [INT_W-1:0] log_shl;
        input [INT_W-1:0] data;
        input [5:0] shamt;
        reg [INT_W-1:0] s;
        begin
            s = data;
            if (shamt[5]) s = s << 6'd32;
            if (shamt[4]) s = s << 6'd16;
            if (shamt[3]) s = s << 6'd8;
            if (shamt[2]) s = s << 6'd4;
            if (shamt[1]) s = s << 6'd2;
            if (shamt[0]) s = s << 6'd1;
            log_shl = s;
        end
    endfunction

    // ============================================================
    // Stage 1: Unpack, Special Detect, Multiply, Alignment
    // ============================================================
    reg         s2_valid;
    reg  [2:0]  s2_special;           // special case encoding
    reg  [7:0]  s2_exp;               // anchor exponent for result
    reg  [INT_W-1:0] s2_term1;        // first term (signed magnitude)
    reg  [INT_W-1:0] s2_term2;        // second term
    reg  [INT_W-1:0] s2_term3;        // third term (dot mode only)
    reg  [1:0]  s2_sign1, s2_sign2, s2_sign3; // sign: 0=zero,1=pos,2=neg. s2_sign3!=0 => 3-term
    reg  [31:0] s2_special_result;    // pre-computed special result
    reg         dot_phase;             // Dot 2-phase control
    reg  [47:0] dot_held_prod;  reg  [7:0] dot_held_exp;
    reg         dot_held_sign, dot_held_dx_zero;
    reg  [23:0] dot_held_ps_mant, dot_held_py_mant;
    reg  [7:0]  dot_held_ps_exp, dot_held_py_exp;
    reg         dot_held_ps_sign, dot_held_ps_zero;
    reg         dot_held_py_sign, dot_held_py_zero;
    reg  [11:0] dot_held_dy;


    // Special encoding: 0=normal, 1=qNaN, 2=Inf(+), 3=Inf(-), 4=zero
    function [2:0] encode_special;
        input is_nan, is_inf, sign;
        begin
            if (is_nan)  encode_special = 3'd1;
            else if (is_inf && sign) encode_special = 3'd3;
            else if (is_inf)         encode_special = 3'd2;
            else                     encode_special = 3'd0;
        end
    endfunction

    // Unpack FP32 with input FTZ
    function [35:0] unpack_ftz;
        input [31:0] fp;
        reg is_nan, is_inf, is_zero;
        reg sign;
        reg [7:0] exp;
        reg [23:0] mant;
        begin
            sign  = fp[31];
            exp   = fp[30:23];
            is_nan  = (exp == 8'hFF) && (fp[22:0] != 0);
            is_inf  = (exp == 8'hFF) && (fp[22:0] == 0);
            is_zero = (exp == 8'h00);  // FTZ: any subnormal is flushed to zero
            if (is_zero || (exp == 8'h00)) begin
                mant = 24'd0;
                exp  = 8'd0;
            end else begin
                mant = {1'b1, fp[22:0]};
            end
            unpack_ftz = {is_nan, is_inf, is_zero, sign, exp[7:0], mant[23:0]};
        end
    endfunction

    // Unpack FP32 for Dot mode Px/Py (uses dot_p_msb_i for mantissa MSB)
    function [35:0] unpack_dot;
        input [31:0] fp;
        input        msb;
        reg is_nan, is_inf, is_zero;
        reg sign;
        reg [7:0] exp;
        reg [23:0] mant;
        begin
            sign  = fp[31];
            exp   = fp[30:23];
            is_nan  = (exp == 8'hFF) && (fp[22:0] != 0);
            is_inf  = (exp == 8'hFF) && (fp[22:0] == 0);
            is_zero = (exp == 8'h00);
            if (is_zero) begin
                mant = 24'd0;
                exp  = 8'd0;
            end else begin
                mant = {msb, fp[22:0]};
            end
            unpack_dot = {is_nan, is_inf, is_zero, sign, exp[7:0], mant[23:0]};
        end
    endfunction

    // Priority special case resolution
    function [31:0] resolve_special;
        input a_nan, a_inf, a_sign, b_nan, b_inf, b_sign, c_nan, c_inf, c_sign;
        input b_zero, c_zero, a_zero;
        input is_dot;
        reg any_nan, a_inf_bc_inf_opp, inf_times_zero, remaining_inf;
        reg res_sign;
        begin
            any_nan = a_nan || b_nan || c_nan;
            // Inf * 0 check
            inf_times_zero = (b_inf && c_zero) || (b_zero && c_inf);
            // A Inf + opposite sign B*C Inf
            a_inf_bc_inf_opp = a_inf && b_inf && c_inf && (a_sign != (b_sign ^ c_sign));
            // Remaining Inf
            remaining_inf = a_inf || b_inf || c_inf;

            // Determine result sign for Inf cases
            if (a_inf) res_sign = a_sign;
            else if (b_inf && c_inf) res_sign = b_sign ^ c_sign;
            else if (b_inf) res_sign = b_sign;
            else res_sign = c_sign;

            if (any_nan)
                resolve_special = 32'h7FC00000;  // quiet NaN
            else if (inf_times_zero || a_inf_bc_inf_opp)
                resolve_special = 32'h7FC00000;  // qNaN
            else if (remaining_inf)
                resolve_special = {res_sign, 8'hFF, 23'd0};  // signed Inf
            else if (a_zero && ((b_inf && c_zero) || (b_zero && c_inf)))
                resolve_special = 32'h7FC00000;
            else
                resolve_special = 32'h00000000;  // normal path marker
        end
    endfunction


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid    <= 1'b0;
            s2_special  <= 3'd0;
            s2_exp      <= 8'd0;
            s2_term1    <= 0;
            s2_term2    <= 0;
            s2_term3    <= 0;
            s2_sign1    <= 2'd0;
            s2_sign2    <= 2'd0;
            s2_sign3    <= 2'd0;
            s2_special_result <= 32'd0;
            dot_phase   <= 1'b0;
        end else begin
            s2_valid <= valid_i || dot_phase;

            if (valid_i || dot_phase) begin
                if (!mode_i && !dot_phase) begin
                    // ============================================
                    // FMA Mode: Y = A + B * C
                    // ============================================
                    reg a_nan, a_inf, a_zero, a_sign;
                    reg b_nan, b_inf, b_zero, b_sign;
                    reg c_nan, c_inf, c_zero, c_sign;
                    reg [7:0] a_exp, b_exp, c_exp;
                    reg [23:0] a_mant, b_mant, c_mant;
                    reg [7:0] prod_exp;
                    reg [47:0] prod_mant;
                    reg signed [8:0] align_diff;
                    reg [INT_W-1:0] addend_aligned;
                    reg [INT_W-1:0] prod_aligned;
                    reg prod_is_zero;
                    reg [46:0] prod_mant_adj;
                    reg [7:0] prod_exp_adj;
                    reg [31:0] special_result;
                    reg [7:0] anchor_exp;

                    {a_nan, a_inf, a_zero, a_sign, a_exp, a_mant} = unpack_ftz(a_i);
                    {b_nan, b_inf, b_zero, b_sign, b_exp, b_mant} = unpack_ftz(b_i);
                    {c_nan, c_inf, c_zero, c_sign, c_exp, c_mant} = unpack_ftz(c_i);
                    mult_a = b_mant; mult_b = c_mant;

                    special_result = resolve_special(
                        a_nan, a_inf, a_sign,
                        b_nan, b_inf, b_sign,
                        c_nan, c_inf, c_sign,
                        b_zero, c_zero, a_zero, 1'b0
                    );

                    // Use shared multiplier
                    prod_mant = shared_product;
                    prod_is_zero = b_zero || c_zero;
                    prod_exp = prod_is_zero ? 8'd0 : (b_exp + c_exp - BIAS);

                    if (prod_mant[47]) begin
                        prod_mant_adj = prod_mant[47:1];
                        prod_exp_adj = prod_exp + 8'd1;
                    end else begin
                        prod_mant_adj = prod_mant[46:0];
                        prod_exp_adj = prod_exp;
                    end

                    if (prod_exp_adj >= a_exp) begin
                        anchor_exp = prod_exp_adj;
                        prod_aligned = {1'b0, prod_mant_adj[46:20]};
                        align_diff = prod_exp_adj - a_exp;
                        addend_aligned = (a_zero || align_diff >= INT_W) ? 0 :
                            log_shr({1'b0, a_mant, {AD_PAD{1'b0}}}, align_diff[5:0]);
                    end else begin
                        anchor_exp = a_exp;
                        addend_aligned = {1'b0, a_mant, {AD_PAD{1'b0}}};
                        align_diff = a_exp - prod_exp_adj;
                        prod_aligned = (prod_is_zero || align_diff >= INT_W) ? 0 :
                            log_shr({1'b0, prod_mant_adj[46:20]}, align_diff[5:0]);
                    end

                    if (a_nan || b_nan || c_nan || a_inf || b_inf || c_inf ||
                        (b_inf && c_zero) || (b_zero && c_inf)) begin
                        s2_special <= encode_special(a_nan||b_nan||c_nan, a_inf||b_inf||c_inf, 1'b0);
                        s2_special_result <= special_result;
                        s2_sign1 <= 2'd0; s2_sign2 <= 2'd0; s2_sign3 <= 2'd0;
                    end else begin
                        s2_special <= 3'd0;
                        s2_special_result <= 32'd0;
                        s2_sign1 <= (a_sign && ~a_zero) ? 2'd2 : (a_zero ? 2'd0 : 2'd1);
                        s2_sign2 <= (b_zero || c_zero) ? 2'd0 : ((b_sign ^ c_sign) ? 2'd2 : 2'd1);
                        s2_sign3 <= 2'd0;
                    end

                    s2_exp   <= anchor_exp;
                    s2_term1 <= (a_nan||b_nan||c_nan||a_inf||b_inf||c_inf||(b_inf&&c_zero)||(b_zero&&c_inf)) ? 0 : addend_aligned;
                    s2_term2 <= (a_nan||b_nan||c_nan||a_inf||b_inf||c_inf||(b_inf&&c_zero)||(b_zero&&c_inf)) ? 0 : prod_aligned;
                    s2_term3 <= 0;

                end else begin
                    // ============================================
                    // Dot Mode: Y = Ps + Px*Dx + Py*Dy (2-phase)
                    // ============================================
                    reg ps_nan, ps_inf, ps_zero, ps_sign;
                    reg px_nan, px_inf, px_zero, px_sign;
                    reg py_nan, py_inf, py_zero, py_sign;
                    reg [7:0] ps_exp, px_exp, py_exp;
                    reg [23:0] ps_mant, px_mant, py_mant;
                    reg [47:0] prod_dx, prod_dy;
                    reg [46:0] prod_dx_adj, prod_dy_adj;
                    reg [7:0] prod_exp, prod_exp_adj;
                    reg [5:0] msb_pos;
                    integer j;
                    reg [INT_W-1:0] ps_aligned, dx_aligned, dy_aligned;
                    reg dx_is_zero, dy_is_zero;
                    reg [31:0] special_result;
                    reg [7:0] anchor_exp;

                    {ps_nan, ps_inf, ps_zero, ps_sign, ps_exp, ps_mant} = unpack_ftz(a_i);
                    {px_nan, px_inf, px_zero, px_sign, px_exp, px_mant} = unpack_dot(b_i, dot_p_msb_i[1]);
                    {py_nan, py_inf, py_zero, py_sign, py_exp, py_mant} = unpack_dot(c_i, dot_p_msb_i[0]);
                    if (!dot_phase) begin mult_a = px_mant; mult_b = {12'd0, dx_i[10:0]}; end
                    else        begin mult_a = dot_held_py_mant; mult_b = {12'd0, dot_held_dy[10:0]}; end

                    if (!dot_phase) begin
                        // === PHASE 0: compute Px*Dx, hold ===
                        if (ps_nan || px_nan || py_nan || ps_inf || px_inf || py_inf || (px_inf && (dx_i[10:0] == 11'd0))) begin
                            s2_special <= (ps_nan||px_nan||py_nan) ? 3'd1 : ps_inf ? (ps_sign?3'd3:3'd2) : px_inf ? (px_sign?3'd3:3'd2) : py_inf ? (py_sign?3'd3:3'd2) : 3'd1;
                            s2_special_result <= (ps_nan||px_nan||py_nan) ? 32'h7FC00000 : ps_inf ? {ps_sign,8'hFF,23'd0} : px_inf ? {px_sign,8'hFF,23'd0} : py_inf ? {py_sign,8'hFF,23'd0} : 32'h7FC00000;
                            s2_term1 <= 0; s2_term2 <= 0; s2_term3 <= 0;
                            dot_phase <= 1'b0;
                        end else begin
                            prod_dx = shared_product;
                            dx_is_zero = px_zero || (dx_i[10:0] == 11'd0);
                            msb_pos = 0;
                            if (!dx_is_zero) begin for (j=46;j>=0;j=j-1) if (prod_dx[j] && msb_pos==0) msb_pos=j[5:0]; end
                            prod_dx_adj = dx_is_zero ? 47'd0 : (prod_dx[46:0] << (6'd46 - msb_pos));
                            prod_exp = dx_is_zero ? 8'd0 : (px_exp + msb_pos - 8'd27);
                            dot_held_prod    <= {1'b0, prod_dx_adj};
                            dot_held_exp     <= prod_exp;
                            dot_held_sign    <= px_sign;
                            dot_held_dx_zero <= dx_is_zero;
                            dot_held_ps_mant <= ps_mant; dot_held_ps_exp <= ps_exp;
                            dot_held_ps_sign <= ps_sign; dot_held_ps_zero <= ps_zero;
                            dot_held_py_mant <= py_mant; dot_held_py_exp <= py_exp;
                            dot_held_py_sign <= py_sign; dot_held_py_zero <= py_zero;
                            dot_held_dy      <= dy_i;
                            dot_phase <= 1'b1;
                            s2_valid  <= 1'b0;
                        end
                    end else begin
                        // === PHASE 1: compute Py*Dy, align all 3 ===
                        dot_phase <= 1'b0;
                        prod_dy = shared_product;
                        dy_is_zero = dot_held_py_zero || (dot_held_dy[10:0] == 11'd0);
                        msb_pos = 0;
                        if (!dy_is_zero) begin for (j=46;j>=0;j=j-1) if (prod_dy[j] && msb_pos==0) msb_pos=j[5:0]; end
                        prod_dy_adj = dy_is_zero ? 47'd0 : (prod_dy[46:0] << (6'd46 - msb_pos));
                        prod_exp_adj = dy_is_zero ? 8'd0 : (dot_held_py_exp + msb_pos - 8'd27);
                        anchor_exp = dot_held_ps_exp;
                        if (dot_held_exp > anchor_exp) anchor_exp = dot_held_exp;
                        if (prod_exp_adj > anchor_exp) anchor_exp = prod_exp_adj;
                        if (anchor_exp >= dot_held_ps_exp) begin
                            reg [7:0] sh; sh = anchor_exp - dot_held_ps_exp;
                            ps_aligned = (dot_held_ps_zero || sh >= INT_W) ? 0 : log_shr({1'b0, dot_held_ps_mant, {AD_PAD{1'b0}}}, sh[5:0]);
                        end else ps_aligned = 0;
                        if (anchor_exp >= dot_held_exp) begin
                            reg [7:0] sh; sh = anchor_exp - dot_held_exp;
                            dx_aligned = (dot_held_dx_zero || sh >= INT_W) ? 0 : log_shr({1'b0, dot_held_prod[46:20]}, sh[5:0]);
                        end else dx_aligned = 0;
                        if (anchor_exp >= prod_exp_adj) begin
                            reg [7:0] sh; sh = anchor_exp - prod_exp_adj;
                            dy_aligned = (dy_is_zero || sh >= INT_W) ? 0 : log_shr({1'b0, prod_dy_adj[46:20]}, sh[5:0]);
                        end else dy_aligned = {1'b0, prod_dy_adj[46:20]};
                        s2_special <= 3'd0; s2_special_result <= 32'd0;
                        s2_exp   <= anchor_exp;
                        s2_term1 <= ps_aligned;
                        s2_term2 <= dx_aligned;
                        s2_term3 <= dy_aligned;
                        s2_sign1 <= dot_held_ps_zero ? 2'd0 : (dot_held_ps_sign ? 2'd2 : 2'd1);
                        s2_sign2 <= dot_held_dx_zero ? 2'd0 : (dot_held_sign ? 2'd2 : 2'd1);
                        s2_sign3 <= dy_is_zero ? 2'd0 : (dot_held_py_sign ? 2'd2 : 2'd1);
                    end
                end
            end
        end
    end

    // Stage 2: CPA Sum, Absolute Value, LOD, Sticky
    // ============================================================
    reg         s3_valid;
    reg  [2:0]  s3_special;
    reg  [31:0] s3_special_result;
    reg  [7:0]  s3_exp;
    reg         s3_result_sign;
    reg  [INT_W-1:0] s3_mant;         // absolute value of sum
    reg  [5:0]  s3_lod;               // leading-one detect shift amount
    reg         s3_result_is_zero;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid    <= 1'b0;
            s3_special  <= 3'd0;
            s3_special_result <= 32'd0;
            s3_exp      <= 8'd0;
            s3_result_sign <= 1'b0;
            s3_mant     <= 0;
            s3_lod      <= 6'd0;
            s3_result_is_zero <= 1'b0;
        end else begin
            s3_valid     <= s2_valid;
            s3_special   <= s2_special;
            s3_special_result <= s2_special_result;
            s3_exp       <= s2_exp;

            if (s2_valid && s2_special == 3'd0) begin
                reg [INT_W:0] sum_raw;  // one extra bit for carry
                reg result_sign;
                reg [INT_W-1:0] sum_abs;
                reg [5:0] lod;

                // Signed addition: convert sign-magnitude to 2's complement terms
                // Verilog '-' on unsigned produces 2's complement; assign to signed.
                if (|s2_sign3) begin
                    // Three-term addition (Dot mode)
                    reg signed [INT_W:0] t1, t2, t3;
                    t1 = (s2_sign1 == 2'd1) ? {1'b0, s2_term1} :
                         (s2_sign1 == 2'd2) ? -{1'b0, s2_term1} : 0;
                    t2 = (s2_sign2 == 2'd1) ? {1'b0, s2_term2} :
                         (s2_sign2 == 2'd2) ? -{1'b0, s2_term2} : 0;
                    t3 = (s2_sign3 == 2'd1) ? {1'b0, s2_term3} :
                         (s2_sign3 == 2'd2) ? -{1'b0, s2_term3} : 0;
                    sum_raw = $unsigned(t1 + t2 + t3);
                end else begin
                    // Two-term addition (FMA mode)
                    reg signed [INT_W:0] t1, t2;
                    t1 = (s2_sign1 == 2'd1) ? {1'b0, s2_term1} :
                         (s2_sign1 == 2'd2) ? -{1'b0, s2_term1} : 0;
                    t2 = (s2_sign2 == 2'd1) ? {1'b0, s2_term2} :
                         (s2_sign2 == 2'd2) ? -{1'b0, s2_term2} : 0;
                    sum_raw = $unsigned(t1 + t2);
                end

                result_sign = sum_raw[INT_W];
                sum_abs = result_sign ? (~sum_raw[INT_W-1:0] + 1'b1) : sum_raw[INT_W-1:0];

                // LOD: cascaded priority encoder (INT_W=28, range [27:0])
                lod = 0;
                if      (sum_abs[27]) lod = 0;
                else if (sum_abs[26]) lod = 1;
                else if (sum_abs[25]) lod = 2;
                else if (sum_abs[24]) lod = 3;
                else if (sum_abs[23]) lod = 4;
                else if (sum_abs[22]) lod = 5;
                else if (sum_abs[21]) lod = 6;
                else if (sum_abs[20]) lod = 7;
                else if (sum_abs[19]) lod = 8;
                else if (sum_abs[18]) lod = 9;
                else if (sum_abs[17]) lod = 10;
                else if (sum_abs[16]) lod = 11;
                else if (sum_abs[15]) lod = 12;
                else if (sum_abs[14]) lod = 13;
                else if (sum_abs[13]) lod = 14;
                else if (sum_abs[12]) lod = 15;
                else if (sum_abs[11]) lod = 16;
                else if (sum_abs[10]) lod = 17;
                else if (sum_abs[ 9]) lod = 18;
                else if (sum_abs[ 8]) lod = 19;
                else if (sum_abs[ 7]) lod = 20;
                else if (sum_abs[ 6]) lod = 21;
                else if (sum_abs[ 5]) lod = 22;
                else if (sum_abs[ 4]) lod = 23;
                else if (sum_abs[ 3]) lod = 24;
                else if (sum_abs[ 2]) lod = 25;
                else if (sum_abs[ 1]) lod = 26;
                else if (sum_abs[ 0]) lod = 27;

                s3_result_sign <= result_sign;
                s3_mant        <= sum_abs;
                s3_lod         <= lod[5:0];
                s3_result_is_zero <= (sum_abs == 0);
            end
        end
    end

    // ============================================================
    // Stage 3: Normalize, Round, Pack
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o <= 1'b0;
            y_o     <= 32'd0;
        end else begin
            valid_o <= s3_valid;

            if (s3_valid) begin
                if (s3_special != 3'd0) begin
                    // Special case: use pre-computed result from S1
                    y_o <= s3_special_result;
                end else if (s3_result_is_zero) begin
                    y_o <= 32'h00000000;
                end else begin
                    reg [8:0]  norm_exp_9;  // 9-bit to detect underflow
                    reg [7:0]  norm_exp;
                    reg [23:0] norm_mant;   // 1 hidden + 23 fraction
                    reg        guard, round, sticky;
                    reg [INT_W-1:0] shifted_mant;
                    reg [5:0]  shift_amt;

                    // Normalize: shift left by LOD to get 1.xxx format
                    shift_amt = s3_lod;
                    shifted_mant = log_shl(s3_mant, shift_amt);

                    // norm_mant: hidden bit at [57], fraction at [56:34]
                    norm_mant = shifted_mant[INT_W-1 -: 24];

                    // exponent: s3_exp - lod + 1 (1 leading zero)
                    norm_exp_9 = {1'b0, s3_exp} + 9'd1 - {2'b0, shift_amt};
                    norm_exp  = norm_exp_9[7:0];

                    // Guard, Round, Sticky: bits just below fraction LSB
                    guard  = shifted_mant[INT_W-25];
                    round  = shifted_mant[INT_W-26];
                    sticky = |(shifted_mant[INT_W-27:0]);

                    // RN-even rounding
                    if (guard && (round || sticky || norm_mant[0])) begin
                        norm_mant = norm_mant + 24'd1;
                        if (norm_mant[23]) begin
                            norm_mant = norm_mant >> 1;
                            norm_exp_9 = norm_exp_9 + 9'd1;
                            norm_exp   = norm_exp_9[7:0];
                        end
                    end

                    // Output FTZ: subnormal (exp <= 0) → flush to zero
                    // Underflow detected via bit 8 or norm_exp_9 == 0
                    if (norm_exp_9[8] || norm_exp_9 == 9'd0) begin
                        y_o <= 32'h00000000;
                    end else if (norm_exp_9 >= 9'hFF) begin
                        // Overflow → Inf
                        y_o <= {s3_result_sign, 8'hFF, 23'd0};
                    end else begin
                        y_o <= {s3_result_sign, norm_exp[7:0], norm_mant[22:0]};
                    end
                end
            end
        end
    end

endmodule
