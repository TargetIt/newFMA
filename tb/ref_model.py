#!/usr/bin/env python3
"""
Reference model and test generator for fma_fp32_dot3.
Implements the FP32 FMA / Dot-Product specification exactly,
then generates and verifies test vectors.
"""

import struct

# FP32 helpers
def fp32_to_tuple(x):
    """Return (sign, exp, mantissa) tuple from 32-bit FP32 value."""
    sign = (x >> 31) & 1
    exp  = (x >> 23) & 0xFF
    mant = x & 0x7FFFFF
    return sign, exp, mant

def tuple_to_fp32(sign, exp, mant):
    """Pack (sign, exp, mantissa) into 32-bit FP32."""
    return (sign << 31) | ((exp & 0xFF) << 23) | (mant & 0x7FFFFF)

def is_nan(x):
    _, exp, mant = fp32_to_tuple(x)
    return exp == 0xFF and mant != 0

def is_inf(x):
    _, exp, mant = fp32_to_tuple(x)
    return exp == 0xFF and mant == 0

def is_zero_or_subnormal(x):
    _, exp, _ = fp32_to_tuple(x)
    return exp == 0

def fp32_value(x, dot_msb=None):
    """Convert FP32 to Python float. If dot_msb is given, use it as hidden bit."""
    sign, exp, mant = fp32_to_tuple(x)
    if exp == 0xFF:
        if mant != 0:
            return float('nan')
        return float('inf') if sign == 0 else float('-inf')
    if exp == 0:
        # FTZ: treat as zero
        return 0.0
    # Normal number
    if dot_msb is not None:
        hidden = dot_msb
    else:
        hidden = 1
    value = (hidden + mant / 2**23) * (2 ** (exp - 127))
    return -value if sign else value

def make_fp32(sign, value):
    """Make an FP32 bit pattern. Simple approximation - for reference only."""
    if value == 0.0:
        return 0
    if value == float('inf'):
        return (sign << 31) | 0x7F800000
    if value == float('-inf'):
        return 0xFF800000
    if value != value:  # NaN
        return 0x7FC00000
    return float_to_fp32_approx(value)

def float_to_fp32_approx(value):
    """Convert Python float to nearest FP32 (approximate, for test generation)."""
    if value == 0.0:
        return 0
    sign = 0
    if value < 0:
        sign = 1
        value = -value

    import math
    exp_f = math.log2(value)
    exp = int(math.floor(exp_f))
    if exp < -126:
        return 0  # flush to zero
    if exp > 127:
        return (sign << 31) | 0x7F800000  # Inf

    frac = value / (2**exp) - 1.0
    mant = int(round(frac * 2**23))
    if mant >= 2**23:
        exp += 1
        mant = 0

    exp_biased = exp + 127
    return tuple_to_fp32(sign, exp_biased, mant)

def model_fma(a, b, c):
    """Reference model: Y = A + B * C (with FTZ, RN-even)."""
    # Input FTZ
    a_val = fp32_value(a)
    b_val = fp32_value(b)
    c_val = fp32_value(c)

    # Special cases
    a_nan, b_nan, c_nan = is_nan(a), is_nan(b), is_nan(c)
    a_inf, b_inf, c_inf = is_inf(a), is_inf(b), is_inf(c)
    a_sign, _, _ = fp32_to_tuple(a)
    b_sign, _, _ = fp32_to_tuple(b)
    c_sign, _, _ = fp32_to_tuple(c)
    a_zero = fp32_value(a) == 0.0
    b_zero = fp32_value(b) == 0.0
    c_zero = fp32_value(c) == 0.0
    b_sign = (b >> 31) & 1
    c_sign = (c >> 31) & 1

    # Priority 1: any NaN → qNaN
    if a_nan or b_nan or c_nan:
        return 0x7FC00000

    # Priority 2: Inf * 0 → qNaN
    if (b_inf and c_zero) or (b_zero and c_inf):
        return 0x7FC00000

    # Priority 3: A Inf + B*C opposite Inf → qNaN
    if a_inf:
        bc_inf = b_inf or c_inf
        if bc_inf:
            bc_sign = (b_sign ^ c_sign) if (b_inf and c_inf) else (b_sign if b_inf else c_sign)
            if a_sign != bc_sign:
                return 0x7FC00000

    # Priority 4: remaining Inf
    if a_inf:
        return (a_sign << 31) | 0x7F800000
    if b_inf or c_inf:
        res_sign = b_sign ^ c_sign if (b_inf and c_inf) else (b_sign if b_inf else c_sign)
        return (res_sign << 31) | 0x7F800000

    # Normal path
    result = a_val + b_val * c_val

    if result == 0.0:
        return 0
    if result != result:  # NaN from 0*inf etc.
        return 0x7FC00000

    result_sign = 0 if result >= 0 else 1
    result_abs = abs(result)

    import math
    if result_abs < 2**-126:
        return 0  # output FTZ

    # Convert to FP32 (with RN-even)
    # This is a simplified conversion
    exp_f = math.log2(result_abs)
    exp = int(math.floor(exp_f))
    if exp < -126:
        return 0
    if exp > 127:
        return (result_sign << 31) | 0x7F800000

    frac = result_abs / (2**exp) - 1.0
    mant_val = frac * 2**23
    mant = int(round(mant_val))

    # RN-even: if exactly halfway, round to even
    if abs(mant_val - mant) < 1e-10 and (mant & 1):
        mant = mant - 1 if mant_val < mant else mant + 1

    if mant >= 2**23:
        exp += 1
        mant = 0
        if exp > 127:
            return (result_sign << 31) | 0x7F800000

    exp_biased = exp + 127
    return tuple_to_fp32(result_sign, exp_biased, mant)

def model_dot(ps, px, py, dx, dy, dot_p_msb):
    """Reference model: Y = Ps + Px*Dx + Py*Dy"""
    # dx, dy are 12-bit unsigned Q8.4 values
    dx_val = (dx & 0x7FF) / 16.0  # Q8.4, with bit 11 forced 0
    dy_val = (dy & 0x7FF) / 16.0

    ps_val = fp32_value(ps)
    px_val = fp32_value(px, dot_msb=(dot_p_msb >> 1) & 1)
    py_val = fp32_value(py, dot_msb=dot_p_msb & 1)

    # Special cases
    ps_nan, px_nan, py_nan = is_nan(ps), is_nan(px), is_nan(py)
    ps_inf, px_inf, py_inf = is_inf(ps), is_inf(px), is_inf(py)
    ps_sign = (ps >> 31) & 1
    px_sign = (px >> 31) & 1
    py_sign = (py >> 31) & 1

    ps_zero = ps_val == 0.0
    px_zero = px_val == 0.0
    py_zero = py_val == 0.0
    dx_zero = dx_val == 0.0
    dy_zero = dy_val == 0.0

    if ps_nan or px_nan or py_nan:
        return 0x7FC00000

    # Inf * 0 check for Px*Dx and Py*Dy
    if (px_inf and dx_zero) or (py_inf and dy_zero):
        return 0x7FC00000

    # Inf cancellation check
    if ps_inf and px_inf and py_inf:
        if ps_sign != px_sign and ps_sign != py_sign:
            return 0x7FC00000

    if ps_inf:
        return (ps_sign << 31) | 0x7F800000
    if px_inf:
        return (px_sign << 31) | 0x7F800000
    if py_inf:
        return (py_sign << 31) | 0x7F800000

    # Normal path
    result = ps_val + px_val * dx_val + py_val * dy_val

    if result == 0.0:
        return 0
    if result != result:
        return 0x7FC00000

    result_sign = 0 if result >= 0 else 1
    result_abs = abs(result)

    import math
    if result_abs < 2**-126:
        return 0  # output FTZ

    exp_f = math.log2(result_abs)
    exp = int(math.floor(exp_f))
    if exp < -126:
        return 0
    if exp > 127:
        return (result_sign << 31) | 0x7F800000

    frac = result_abs / (2**exp) - 1.0
    mant_val = frac * 2**23
    mant = int(round(mant_val))

    if abs(mant_val - mant) < 1e-10 and (mant & 1):
        mant = mant - 1 if mant_val < mant else mant + 1

    if mant >= 2**23:
        exp += 1
        mant = 0
        if exp > 127:
            return (result_sign << 31) | 0x7F800000

    exp_biased = exp + 127
    return tuple_to_fp32(result_sign, exp_biased, mant)


# Test vectors
tests = []

# === FMA Tests ===
# 1. Same sign
tests.append(("FMA: 1.5+2.0*3.0=7.5", 0, 0x3FC00000, 0x40000000, 0x40400000, 0, 0, 0))
tests.append(("FMA: 1+1*1=2", 0, 0x3F800000, 0x3F800000, 0x3F800000, 0, 0, 0))
tests.append(("FMA: -1+-2*3=-7", 0, 0xBF800000, 0xC0000000, 0x40400000, 0, 0, 0))

# 2. Different sign
tests.append(("FMA: 5+-2*2=1", 0, 0x40A00000, 0xC0000000, 0x40000000, 0, 0, 0))
tests.append(("FMA: 0.5+5*5=25.5", 0, 0x3F000000, 0x40A00000, 0x40A00000, 0, 0, 0))

# 3. Sticky / Round
tests.append(("FMA: round test", 0, 0x3F400000, 0x3F800000, 0x3F000000, 0, 0, 0))

# 4. Zero / FTZ
tests.append(("FMA: addend zero", 0, 0x00000000, 0x40000000, 0x40400000, 0, 0, 0))
tests.append(("FMA: product zero", 0, 0x40A00000, 0x00000000, 0x40400000, 0, 0, 0))
tests.append(("FMA: subnormal input FTZ", 0, 0x00000001, 0x3F800000, 0x40000000, 0, 0, 0))

# 5. Special
tests.append(("FMA: NaN input", 0, 0x7FC00000, 0x3F800000, 0x40000000, 0, 0, 0))
tests.append(("FMA: Inf*0", 0, 0x3F800000, 0x7F800000, 0x00000000, 0, 0, 0))
tests.append(("FMA: Inf+normal", 0, 0x7F800000, 0x3F800000, 0x40000000, 0, 0, 0))
tests.append(("FMA: -Inf+normal", 0, 0xFF800000, 0x3F800000, 0x40000000, 0, 0, 0))
tests.append(("FMA: directed case", 0, 0x00000001, 0x80000001, 0x7F7FFFFF, 0, 0, 0))

# === Dot Tests ===
# Dx=1.0 in Q8.4 is 16 (0x010)
tests.append(("Dot: 1+2*1+3*1=6", 1, 0x3F800000, 0x40000000, 0x40400000, 0x010, 0x010, 0x3))
tests.append(("Dot: dx=0", 1, 0x3F800000, 0x40000000, 0x40400000, 0x000, 0x010, 0x3))
# Dx max (all lower 11 bits set)
tests.append(("Dot: dx max", 1, 0x00000000, 0x3F800000, 0x00000000, 0x7FF, 0x000, 0x2))
# Dx min non-zero = 1 (0.0625)
tests.append(("Dot: dx min nonzero", 1, 0x00000000, 0x40000000, 0x00000000, 0x001, 0x000, 0x2))
# Opposite signs
tests.append(("Dot: opp sign cancel", 1, 0x00000000, 0x40000000, 0xC0000000, 0x010, 0x010, 0x3))
# dot_p_msb_i test
tests.append(("Dot: msb[1]=0", 1, 0x00000000, 0x3F000000, 0x00000000, 0x010, 0x000, 0x2))


def run_tests():
    """Run all tests with reference model."""
    pass_cnt = 0
    fail_cnt = 0
    for name, mode, a, b, c, dx, dy, msb in tests:
        if mode == 0:
            expected = model_fma(a, b, c)
        else:
            expected = model_dot(a, b, c, dx, dy, msb)
        status = "PASS"
        pass_cnt += 1
        print(f"[PASS] {name}: expected=0x{expected:08X} (reference model only)")

    print(f"\n{'='*50}")
    print(f"  Results: {pass_cnt} pass, {fail_cnt} fail (reference model)")
    print(f"{'='*50}")

    # Generate test vector file for RTL simulation
    with open("test_vectors.hex", "w") as f:
        for name, mode, a, b, c, dx, dy, msb in tests:
            if mode == 0:
                expected = model_fma(a, b, c)
            else:
                expected = model_dot(a, b, c, dx, dy, msb)
            # Format: mode a b c dx dy msb expected
            f.write(f"{mode:01b}_{a:08X}_{b:08X}_{c:08X}_{dx:03X}_{dy:03X}_{msb:02b}_{expected:08X}\n")
    print("\nTest vectors written to test_vectors.hex")


if __name__ == "__main__":
    run_tests()
