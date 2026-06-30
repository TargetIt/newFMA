#!/usr/bin/env python3
"""
Bit-accurate reference model and test generator for fma_fp32_dot3.

This model mirrors the RTL datapath EXACTLY (including the area-optimization
approximations): the 24x12 truncated FMA multiplier, the INT_W=40 internal
width, logarithmic shifters, 2-/3-term CPA, LOD, RN-even rounding and FTZ.
It is therefore a genuine golden model for differential verification of the
RTL, not merely a vector generator.

Vector file format (test_vectors.hex), one hex word per line, $readmemh-friendly:
    word 0          : N  (number of vectors)
    word 1..8       : vector 0  -> {mode, a, b, c, dx, dy, msb, expected}
    word 9..16      : vector 1
    ...
Each vector occupies 8 consecutive 32-bit words:
    [0] mode   (bit 0)
    [1] a      (32 bits)
    [2] b      (32 bits)
    [3] c      (32 bits)
    [4] dx     (low 12 bits)
    [5] dy     (low 12 bits)
    [6] msb    (low 2 bits)
    [7] expected (32 bits)
"""

import os
import math

# Vector file lives next to this script so the path is CWD-independent.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VEC_PATH = os.path.join(SCRIPT_DIR, "test_vectors.hex")

# RTL parameters (must match rtl/fma_fp32_dot3.v)
INT_W    = 40
MANT_W   = 23
MANT_FULL = 24
BIAS     = 127
AD_PAD   = INT_W - 1 - MANT_FULL   # 15
MASK40   = (1 << INT_W) - 1
MASK24   = (1 << MANT_FULL) - 1
MASK8    = 0xFF

def mask(x, w):
    return x & ((1 << w) - 1)

# ------------------------------------------------------------------
# Unpack FP32 with input FTZ (mirrors RTL unpack_ftz)
# ------------------------------------------------------------------
def unpack_ftz(fp):
    sign = (fp >> 31) & 1
    exp  = (fp >> 23) & 0xFF
    frac = fp & 0x7FFFFF
    is_nan  = (exp == 0xFF) and (frac != 0)
    is_inf  = (exp == 0xFF) and (frac == 0)
    is_zero = (exp == 0x00)            # FTZ: subnormal also flushed
    if is_zero or exp == 0x00:
        mant = 0
        exp  = 0
    else:
        mant = (1 << 23) | frac        # 24-bit with hidden bit
    return dict(nan=is_nan, inf=is_inf, zero=is_zero, sign=sign, exp=exp, mant=mant)

def unpack_dot(fp, msb):
    sign = (fp >> 31) & 1
    exp  = (fp >> 23) & 0xFF
    frac = fp & 0x7FFFFF
    is_nan  = (exp == 0xFF) and (frac != 0)
    is_inf  = (exp == 0xFF) and (frac == 0)
    is_zero = (exp == 0x00)
    if is_zero:
        mant = 0
        exp  = 0
    else:
        mant = (msb << 23) | frac      # hidden bit supplied externally
    return dict(nan=is_nan, inf=is_inf, zero=is_zero, sign=sign, exp=exp, mant=mant)

# ------------------------------------------------------------------
# Logarithmic shifters (equivalent to RTL log_shr / log_shl for 40-bit)
# ------------------------------------------------------------------
def log_shr(data, shamt):
    return mask(data >> (shamt & 0x3F), INT_W)

def log_shl(data, shamt):
    return mask(data << (shamt & 0x3F), INT_W)

# ------------------------------------------------------------------
# Special-case resolution (FMA) - mirrors RTL resolve_special
# ------------------------------------------------------------------
def resolve_special_fma(a, b, c, is_dot=False):
    any_nan = a['nan'] or b['nan'] or c['nan']
    inf_times_zero = (b['inf'] and c['zero']) or (b['zero'] and c['inf'])
    a_inf_bc_inf_opp = a['inf'] and b['inf'] and c['inf'] and (a['sign'] != (b['sign'] ^ c['sign']))
    remaining_inf = a['inf'] or b['inf'] or c['inf']
    if a['inf']:
        res_sign = a['sign']
    elif b['inf'] and c['inf']:
        res_sign = b['sign'] ^ c['sign']
    elif b['inf']:
        res_sign = b['sign']
    else:
        res_sign = c['sign']
    if any_nan:
        return 0x7FC00000, True
    if inf_times_zero or a_inf_bc_inf_opp:
        return 0x7FC00000, True
    if remaining_inf:
        return (res_sign << 31) | 0x7F800000, True
    if a['zero'] and inf_times_zero:
        return 0x7FC00000, True
    return 0x00000000, False

# ------------------------------------------------------------------
# Stage-3 normalization + RN-even + pack (shared by FMA and Dot)
# ------------------------------------------------------------------
def normalize_pack(anchor_exp, sum_abs, result_sign):
    # result_is_zero path
    if sum_abs == 0:
        return 0x00000000
    # LOD: position of MSB in 40-bit sum_abs; lod = 39 - idx
    lod = 0
    for k in range(INT_W):
        if (sum_abs >> (INT_W - 1 - k)) & 1:
            lod = k
            break
    shifted = log_shl(sum_abs, lod)
    norm_mant = (shifted >> (INT_W - MANT_FULL)) & MASK24      # [39:16]
    guard  = (shifted >> (INT_W - 25)) & 1                      # bit 15
    rnd    = (shifted >> (INT_W - 26)) & 1                      # bit 14
    sticky = 1 if (shifted & ((1 << (INT_W - 27)) - 1)) else 0  # bits[13:0]
    norm_exp = anchor_exp + 1 - lod                             # signed
    # RN-even
    if guard and (rnd or sticky or (norm_mant & 1)):
        norm_mant = (norm_mant + 1) & MASK24
        if norm_mant & (1 << (MANT_FULL - 1)):   # bit 23 set -> renormalize
            norm_mant = (norm_mant >> 1) & MASK24
            norm_exp += 1
    # Output FTZ / overflow / pack (RTL uses 9-bit norm_exp_9; in true arithmetic
    # bit-8 set == negative underflow -> FTZ; ==0 -> FTZ; >=255 -> Inf)
    if norm_exp <= 0:
        return 0x00000000
    if norm_exp >= 255:
        return (result_sign << 31) | 0x7F800000
    return (result_sign << 31) | ((norm_exp & 0xFF) << 23) | (norm_mant & 0x7FFFFF)

def cpa_sum(signs, terms):
    """2- or 3-term signed CPA. signs: list of 0/1/2; terms: list of 40-bit mags."""
    s = 0
    for sg, t in zip(signs, terms):
        if sg == 1:
            s += t
        elif sg == 2:
            s -= t
    s41 = mask(s, INT_W + 1)
    result_sign = (s41 >> INT_W) & 1
    sum40 = s41 & MASK40
    sum_abs = mask((-sum40) if result_sign else sum40, INT_W) if sum40 != 0 else 0
    # two's complement abs for 40-bit:
    return result_sign, (mask((~sum40 + 1), INT_W) if result_sign else sum40)

# ------------------------------------------------------------------
# Bit-accurate FMA: Y = A + B*C
# ------------------------------------------------------------------
def rtl_fma(a, b, c):
    A = unpack_ftz(a); B = unpack_ftz(b); C = unpack_ftz(c)
    # Special
    special_flag = (A['nan'] or B['nan'] or C['nan'] or A['inf'] or B['inf']
                    or C['inf'] or (B['inf'] and C['zero']) or (B['zero'] and C['inf']))
    if special_flag:
        res, _ = resolve_special_fma(A, B, C)
        return res

    # 24x12 truncated multiply: prod_mant = (b_mant * c_mant[23:12]) << 12
    c_hi12 = (C['mant'] >> 12) & 0xFFF
    prod_mant = mask((B['mant'] * c_hi12) << 12, 48)
    prod_is_zero = B['zero'] or C['zero']
    prod_exp = mask(0 if prod_is_zero else (B['exp'] + C['exp'] - BIAS), 8)

    if prod_mant & (1 << 47):
        prod_mant_adj = (prod_mant >> 1) & ((1 << 47) - 1)
        prod_exp_adj = mask(prod_exp + 1, 8)
    else:
        prod_mant_adj = prod_mant & ((1 << 47) - 1)
        prod_exp_adj = prod_exp

    a_exp = A['exp']
    if prod_exp_adj >= a_exp:
        anchor = prod_exp_adj
        prod_aligned = (prod_mant_adj >> 8) & ((1 << 39) - 1)   # {1'b0, [46:8]}
        prod_aligned = mask(prod_aligned, INT_W)
        align_diff = prod_exp_adj - a_exp
        if A['zero'] or align_diff >= INT_W:
            addend = 0
        else:
            data = mask(A['mant'] << AD_PAD, INT_W)             # {1'b0, a_mant, 15'b0}
            addend = log_shr(data, align_diff & 0x3F)
    else:
        anchor = a_exp
        addend = mask(A['mant'] << AD_PAD, INT_W)
        align_diff = a_exp - prod_exp_adj
        if prod_is_zero or align_diff >= INT_W:
            prod_aligned = 0
        else:
            data = mask(prod_mant_adj >> 8, INT_W)
            prod_aligned = log_shr(data, align_diff & 0x3F)

    sign1 = 2 if (A['sign'] and not A['zero']) else (0 if A['zero'] else 1)
    sign2 = 0 if (B['zero'] or C['zero']) else (2 if (B['sign'] ^ C['sign']) else 1)
    result_sign, sum_abs = cpa_sum([sign1, sign2], [addend, prod_aligned])
    return normalize_pack(anchor, sum_abs, result_sign)

# ------------------------------------------------------------------
# Bit-accurate Dot: Y = Ps + Px*Dx + Py*Dy
# dx/dy are 12-bit; dx[11] forced to 0, value = dx[10:0]/16 (Q8.4)
# ------------------------------------------------------------------
def rtl_dot(ps, px, py, dx, dy, msb):
    PS = unpack_ftz(ps)
    PX = unpack_dot(px, (msb >> 1) & 1)
    PY = unpack_dot(py, msb & 1)
    dx_raw = dx & 0x7FF
    dy_raw = dy & 0x7FF

    any_nan = PS['nan'] or PX['nan'] or PY['nan']
    px_infzero = PX['inf'] and (dx_raw == 0)
    py_infzero = PY['inf'] and (dy_raw == 0)
    inf_cancel = (PS['inf'] and PX['inf'] and PY['inf']
                  and (PS['sign'] != PX['sign'] or PS['sign'] != PY['sign']))
    dot_special = any_nan or PS['inf'] or PX['inf'] or PY['inf'] or px_infzero or py_infzero
    if dot_special:
        if any_nan or px_infzero or py_infzero or inf_cancel:
            return 0x7FC00000
        if PS['inf']:
            return (PS['sign'] << 31) | 0x7F800000
        if PX['inf']:
            return (PX['sign'] << 31) | 0x7F800000
        if PY['inf']:
            return (PY['sign'] << 31) | 0x7F800000

    # 24x11 multiply, normalize MSB to bit 46
    def norm_prod(mant, raw, is_zero, pexp):
        prod = mant * raw                      # up to 35 bits, reg[47:0]
        if is_zero:
            return 0, 0, True
        msb_pos = 0
        for j in range(46, -1, -1):
            if (prod >> j) & 1:
                msb_pos = j
                break
        prod47 = prod & ((1 << 47) - 1)
        prod_adj = mask(prod47 << (46 - msb_pos), 47)
        prod_exp = mask(pexp + msb_pos - 27, 8)
        return prod_adj, prod_exp, False

    dx_is_zero = PX['zero'] or (dx_raw == 0)
    dy_is_zero = PY['zero'] or (dy_raw == 0)
    prod_dx_adj, prod_exp_dx, _ = norm_prod(PX['mant'], dx_raw, dx_is_zero, PX['exp'])
    prod_dy_adj, prod_exp_dy, _ = norm_prod(PY['mant'], dy_raw, dy_is_zero, PY['exp'])

    anchor = PS['exp']
    if prod_exp_dx > anchor:
        anchor = prod_exp_dx
    if prod_exp_dy > anchor:
        anchor = prod_exp_dy

    def align_to(anchor, pexp, is_zero, adj):
        if anchor >= pexp:
            shift = anchor - pexp
            if is_zero or shift >= INT_W:
                return 0
            data = mask(adj >> 8, INT_W)
            return log_shr(data, shift & 0x3F)
        else:
            return mask(adj >> 8, INT_W)

    ps_aligned = 0
    if anchor >= PS['exp']:
        ps_shift = anchor - PS['exp']
        if PS['zero'] or ps_shift >= INT_W:
            ps_aligned = 0
        else:
            data = mask(PS['mant'] << AD_PAD, INT_W)
            ps_aligned = log_shr(data, ps_shift & 0x3F)
    dx_aligned = align_to(anchor, prod_exp_dx, dx_is_zero, prod_dx_adj)
    dy_aligned = align_to(anchor, prod_exp_dy, dy_is_zero, prod_dy_adj)

    sign1 = 0 if PS['zero'] else (2 if PS['sign'] else 1)
    sign2 = 0 if dx_is_zero else (2 if PX['sign'] else 1)
    sign3 = 0 if dy_is_zero else (2 if PY['sign'] else 1)
    result_sign, sum_abs = cpa_sum([sign1, sign2, sign3],
                                   [ps_aligned, dx_aligned, dy_aligned])
    return normalize_pack(anchor, sum_abs, result_sign)

# ------------------------------------------------------------------
# Golden expected for the 22 directed TB cases (for self-validation)
# ------------------------------------------------------------------
KNOWN = [
    ("FMA: 1.5+2.0*3.0=7.5",   0, 0x3FC00000, 0x40000000, 0x40400000, 0, 0, 0, 0x40F00000),
    ("FMA: 1.0+1.0*1.0=2.0",   0, 0x3F800000, 0x3F800000, 0x3F800000, 0, 0, 0, 0x40000000),
    ("FMA: -1.0+-2.0*3.0=-7.0",0, 0xBF800000, 0xC0000000, 0x40400000, 0, 0, 0, 0xC0E00000),
    ("FMA: 5+-2*2=1",          0, 0x40A00000, 0xC0000000, 0x40000000, 0, 0, 0, 0x3F800000),
    ("FMA: 0.5+5*5=25.5",      0, 0x3F000000, 0x40A00000, 0x40A00000, 0, 0, 0, 0x41CC0000),
    ("FMA: 3+-1*3=0",          0, 0x40400000, 0xBF800000, 0x40400000, 0, 0, 0, 0x00000000),
    ("FMA: 0.75+1.0*0.5=1.25", 0, 0x3F400000, 0x3F800000, 0x3F000000, 0, 0, 0, 0x3FA00000),
    ("FMA: 1+2^-20*1",         0, 0x3F800000, 0x35800000, 0x3F800000, 0, 0, 0, 0x3F800008),
    ("FMA: 5+0*3=5",           0, 0x40A00000, 0x00000000, 0x40400000, 0, 0, 0, 0x40A00000),
    ("FMA: 0+2*3=6",           0, 0x00000000, 0x40000000, 0x40400000, 0, 0, 0, 0x40C00000),
    ("FMA: subnorm+1*2=2",     0, 0x00000001, 0x3F800000, 0x40000000, 0, 0, 0, 0x40000000),
    ("FMA: NaN+1*2=qNaN",      0, 0x7FC00000, 0x3F800000, 0x40000000, 0, 0, 0, 0x7FC00000),
    ("FMA: 1+Inf*0=qNaN",      0, 0x3F800000, 0x7F800000, 0x00000000, 0, 0, 0, 0x7FC00000),
    ("FMA: Inf+1*2=Inf",       0, 0x7F800000, 0x3F800000, 0x40000000, 0, 0, 0, 0x7F800000),
    ("FMA: -Inf+1*2=-Inf",     0, 0xFF800000, 0x3F800000, 0x40000000, 0, 0, 0, 0xFF800000),
    ("FMA: directed (subnorm)",0, 0x00000001, 0x80000001, 0x7F7FFFFF, 0, 0, 0, 0x00000000),
    ("Dot: 1+2*1+3*1=6",       1, 0x3F800000, 0x40000000, 0x40400000, 0x010, 0x010, 0x3, 0x40C00000),
    ("Dot: dx=0 -> 1+0+3=4",   1, 0x3F800000, 0x40000000, 0x40400000, 0x000, 0x010, 0x3, 0x40800000),
    ("Dot: 0+1*127.94+0",      1, 0x00000000, 0x3F800000, 0x00000000, 0x7FF, 0x000, 0x2, 0x42FFE000),
    ("Dot: 2*0.0625=0.125",    1, 0x00000000, 0x40000000, 0x00000000, 0x001, 0x000, 0x2, 0x3E000000),
    ("Dot: 2*1+-2*1=0",        1, 0x00000000, 0x40000000, 0xC0000000, 0x010, 0x010, 0x3, 0x00000000),
    ("Dot: dot_p_msb_i[1]=0",  1, 0x00000000, 0x3F000000, 0x00000000, 0x010, 0x000, 0x2, 0x3F000000),
]

# ------------------------------------------------------------------
# Additional dirty-mantissa vectors (exercise 24x12 truncation + sticky).
# Expected values are computed by rtl_fma/rtl_dot (the bit-accurate model),
# then validated against the RTL by the $readmemh TB.
# ------------------------------------------------------------------
DIRTY = [
    # (name, mode, a, b, c, dx, dy, msb)
    # dirty FMA: mantissas with non-zero low bits (c low 12 bits dropped by truncation)
    ("FMA: dirty 1.3+1.7*1.9",     0, 0x3FA66666, 0x3FD9999A, 0x3FF33333, 0, 0, 0),
    ("FMA: dirty 1.1+1.1*1.1",     0, 0x3F8CCCCD, 0x3F8CCCCD, 0x3F8CCCCD, 0, 0, 0),
    ("FMA: dirty near-cancellation",0, 0x3F99999A, 0xBF99999A, 0x3F800000, 0, 0, 0),
    ("FMA: dirty large exp diff",  0, 0x3F800000, 0x3FA00000, 0x36666666, 0, 0, 0),
    ("FMA: dirty negative product",0, 0x40000000, 0xC0CCCCCD, 0x40000000, 0, 0, 0),
    ("FMA: dirty all-mantissa-bits",0, 0x3F7FFFFF, 0x3F7FFFFF, 0x3F7FFFFF, 0, 0, 0),
    ("FMA: dirty 0.333*3.0",       0, 0x3F800000, 0x3EAAAAAB, 0x40400000, 0, 0, 0),
    # dirty Dot: fractional dx/dy with non-trivial mantissas
    ("Dot: dirty 1.3 + 2.7*3.2",   1, 0x3FA66666, 0x402CCCCD, 0x404CCCCD, 0x020, 0x020, 0x3),
    ("Dot: dirty Pi-ish",          1, 0x3F800000, 0x40490FDB, 0x40000000, 0x00A, 0x007, 0x3),
    ("Dot: dirty mixed signs",     1, 0x3F99999A, 0x40000000, 0xC0666666, 0x010, 0x010, 0x3),
]

def compute_expected(mode, a, b, c, dx, dy, msb):
    if mode == 0:
        return rtl_fma(a, b, c)
    return rtl_dot(a, b, c, dx, dy, msb)

def self_test():
    """Validate the bit-accurate model against the 22 known directed results."""
    ok = 0
    fail = 0
    for name, mode, a, b, c, dx, dy, msb, expected in KNOWN:
        got = compute_expected(mode, a, b, c, dx, dy, msb)
        if got == expected:
            print(f"[PASS] {name}: 0x{got:08X}")
            ok += 1
        else:
            print(f"[FAIL] {name}: expected 0x{expected:08X}, model 0x{got:08X}")
            fail += 1
    print(f"\nSelf-test: {ok} pass, {fail} fail (model vs known directed)")
    return fail == 0

def generate_vectors(path, vec_cap=64):
    """Write test_vectors.hex: word0=N, then 8 words per vector (model-driven).

    The file is zero-padded to a fixed capacity (1 + 8*vec_cap words) so the
    TB can declare a matching memory without $readmemh range warnings.
    """
    vectors = list(KNOWN) + DIRTY  # KNOWN: 9-tuple, DIRTY: 8-tuple
    # Recompute expected for ALL vectors from the bit-accurate model (single source of truth)
    rec = []
    for v in vectors:
        name, mode, a, b, c, dx, dy, msb = v[:8]
        exp = compute_expected(mode, a, b, c, dx, dy, msb)
        rec.append((name, mode, a, b, c, dx, dy, msb, exp))
    assert len(rec) <= vec_cap, "too many vectors for vec_cap"

    total_words = 1 + 8 * vec_cap
    with open(path, "w") as f:
        f.write(f"{len(rec):08X}\n")
        for name, mode, a, b, c, dx, dy, msb, exp in rec:
            f.write(f"{mode & 1:08X}\n")
            f.write(f"{a & 0xFFFFFFFF:08X}\n")
            f.write(f"{b & 0xFFFFFFFF:08X}\n")
            f.write(f"{c & 0xFFFFFFFF:08X}\n")
            f.write(f"{dx & 0xFFF:08X}\n")
            f.write(f"{dy & 0xFFF:08X}\n")
            f.write(f"{msb & 0x3:08X}\n")
            f.write(f"{exp & 0xFFFFFFFF:08X}\n")
        # zero-pad to fixed capacity
        for _ in range(total_words - (1 + 8 * len(rec))):
            f.write("00000000\n")
    print(f"\nWrote {len(rec)} vectors to {path}")
    print("  (22 directed + %d dirty-mantissa, expected from bit-accurate model)" % len(DIRTY))

def run_tests():
    print("=" * 60)
    print("  fma_fp32_dot3 bit-accurate reference model")
    print("=" * 60)
    ok = self_test()
    generate_vectors(VEC_PATH)
    print("\nNext: run the RTL against these vectors via 'make sim' (the TB")
    print("loads test_vectors.hex through $readmemh and checks each vector).")
    return 0 if ok else 1

if __name__ == "__main__":
    import sys
    sys.exit(run_tests())
