# fma_fp32_dot3 — Design Specification

## 1. Overview

| Field | Value |
|-------|-------|
| Module | `fma_fp32_dot3` |
| Language | SystemVerilog (synthesizable subset) |
| Top File | `rtl/fma_fp32_dot3.v` |
| Clock | Single clock domain (`clk`) |
| Reset | Asynchronous active-low (`rst_n`) |
| Pipeline | 3 stages (result at N+2 rising edge from valid_i) |

### 1.1 Functional Summary

Two modes selected by `mode_i`:

| mode_i | Formula | Description |
|--------|---------|-------------|
| 0 | `Y = A + B × C` | Fused Multiply-Add |
| 1 | `Y = Ps + Px × Dx + Py × Dy` | Dot Product |

## 2. Interface

| Port | Dir | Width | FMA Semantics | Dot Semantics |
|------|-----|-------|---------------|---------------|
| `clk` | in | 1 | Clock | Clock |
| `rst_n` | in | 1 | Async reset (active low) | Async reset (active low) |
| `valid_i` | in | 1 | Input valid | Input valid |
| `mode_i` | in | 1 | 0 = FMA | 1 = Dot |
| `a_i` | in | 32 | A: FP32 addend | Ps: FP32 addend |
| `b_i` | in | 32 | B: FP32 multiplier | Px: FP32 |
| `c_i` | in | 32 | C: FP32 multiplier | Py: FP32 |
| `dx_i` | in | 12 | Ignored | Dx: unsigned Q8.4 (bit 11 = 0) |
| `dy_i` | in | 12 | Ignored | Dy: unsigned Q8.4 (bit 11 = 0) |
| `dot_p_msb_i` | in | 2 | Ignored | [1]=Px mantissa MSB, [0]=Py mantissa MSB |
| `valid_o` | out | 1 | Output valid | Output valid |
| `y_o` | out | 32 | FP32 result | FP32 result |

### 2.1 Timing Contract

- valid_i sampled at rising edge N
- valid_o asserted at rising edge N+3
- y_o valid when valid_o = 1

## 3. Functional Description

### 3.1 FMA Mode (mode_i = 0)

```
Y = A + B × C
```

Processing steps per stage:

| Stage | Operations |
|-------|-----------|
| S1: Unpack/Multiply/Align | Unpack A, B, C (sign, exp, mant with hidden bit). Check FTZ. Detect NaN/Inf/Zero. Compute product B×C. Normalize product. Compute anchor exponent. Align smaller operand. |
| S2: Add/LOD | Signed addition (2-term CPA). Absolute value. Leading-one detection. |
| S3: Normalize/Round/Pack | Normalize (shift to 1.xxx). RN-even rounding (G/R/S). FTZ/overflow check. Pack FP32 result. |

### 3.2 Dot Mode (mode_i = 1)

```
Y = Ps + Px × Dx + Py × Dy
```

Processing steps per stage:

| Stage | Operations |
|-------|-----------|
| S1: Unpack/Multiply/Align | Unpack Ps (standard FP32), Px/Py (with dot_p_msb_i for hidden bit). Compute Px×Dx and Py×Dy (24×11 multipliers). LOD-normalize both products. Compute anchor as max(Ps_exp, prod_dx_exp, prod_dy_exp). Align all three terms independently. |
| S2: Add/LOD | Signed addition (3-term CPA when py×dy active). Absolute value. Leading-one detection. |
| S3: Normalize/Round/Pack | **Same as FMA** — mode-agnostic normalization, RN-even rounding, FTZ/overflow, FP32 pack. |

### 3.3 Hardware Reuse Strategy

The architecture explicitly separates mode-specific logic (Stage 1) from mode-agnostic logic (Stages 2/3):

| Logic | FMA | Dot | Reuse |
|-------|-----|-----|-------|
| Unpack A/Ps | `unpack_ftz` | `unpack_ftz` | Shared function |
| Unpack B,C / Px,Py | `unpack_ftz` | `unpack_dot` | Different: dot uses external MSB |
| Multiplier | 1 × 24×12 | 2 × 24×11 | Different width |
| Product normalize | Simple bit[47] check | LOD-based variable shift | Different method |
| Special value check | `resolve_special` (B,C coupled) | Inline (Px,Dx and Py,Dy independent) | Different: Dot Inf×0 is per-product |
| Align operands | 2 terms | 3 terms, each independently | Shared `log_shr` function |
| CPA adder | 2-term | 3-term (`\|s2_sign3` trigger) | Same hardware, term count varies |
| LOD | 40-bit cascaded | 40-bit cascaded | Shared hardware |
| Normalize | `log_shl` + GRS extract | `log_shl` + GRS extract | **Identical — zero mode awareness** |
| RN-even round | G/R/S logic | G/R/S logic | **Identical — zero mode awareness** |
| FTZ / Overflow | exp ≤ 0 or ≥ 255 | exp ≤ 0 or ≥ 255 | **Identical — zero mode awareness** |

## 4. Floating Point Semantics

### 4.1 FP32 Format
```
bit[31]: sign
bit[30:23]: biased exponent (actual = E - 127)
bit[22:0]: mantissa fraction (hidden bit = 1 for normal numbers)
```

### 4.2 FTZ (Flush To Zero)
- **Input FTZ**: subnormal inputs (exp = 0) are treated as zero (mantissa = 0)
- **Output FTZ**: subnormal results are flushed to 0x00000000

### 4.3 Rounding: RN-even (Round-to-Nearest, ties to Even)
- Guard (G), Round (R), Sticky (S) bits extracted below mantissa LSB
- G=0: truncate
- G=1, R=1 or S=1: round up
- G=1, R=0, S=0: tie — round to even (mantissa LSB = 0)

### 4.4 Special Value Priority

| Priority | Condition | Output |
|----------|-----------|--------|
| 1 | Any input is NaN | Quiet NaN (0x7FC00000) |
| 2 | Inf × 0 (any operand pair) | Quiet NaN |
| 3 | A=Inf and B×C = opposite-sign Inf (FMA) | Quiet NaN |
| 3' | Ps=Inf with conflicting Px×Dx + Py×Dy signs (Dot) | Quiet NaN |
| 4 | Remaining Inf in any operand | Signed Inf |

Dot-specific: Dx/Dy are unsigned finite fixed-point. They do not generate NaN/Inf.
Inf×0 check applies per-product: (Px_inf && Dx==0) or (Py_inf && Dy==0).

## 5. Dot Mode Fixed-Point Format

Dx, Dy: 12-bit unsigned Q8.4

```
bit[10:4]: integer part (7 bits, max 127)
bit[3:0]:  fractional part (4 bits, 1/16 resolution)
bit[11]:   constrained to 0
```

Value = (dx_i[10:0]) / 16. Range: 0 to 127.9375.

## 6. Pipeline Architecture

```
Stage 1 (combinational)       Stage 2 (combinational)       Stage 3 (combinational)
┌─────────────────────┐       ┌─────────────────────┐       ┌─────────────────────┐
│ Unpack ×3           │       │ Sign→2's Complement  │       │ log_shl (normalize) │
│ Special Detect      │  s2_* │ 2/3-term CPA         │  s3_* │ GRS Extract         │
│ Multiply (mode-spec)│──────►│ Absolute Value       │──────►│ RN-even Round       │
│ Normalize Product   │  regs │ LOD                  │  regs │ FTZ/Overflow Check  │
│ Align to Anchor     │       │                      │       │ Pack FP32           │
└─────────────────────┘       └─────────────────────┘       └─────────────────────┘
     mode_i-aware                  mode-agnostic                  mode-agnostic
```

Valid chain: `valid_i → s2_valid → s3_valid → valid_o`

## 7. Synthesis & PPA Targets

| Parameter | Value |
|-----------|-------|
| Synthesis tool | Yosys + ABC |
| Technology | SKY130 HD (sky130_fd_sc_hd__tt_025C_1v80) |
| Clock period | 20.000 ns (50 MHz) |
| STA tool | ABC timing-driven mapping / OpenSTA |
| Target area | ≥ 20% smaller than reference (~40,512 µm² → < 32,410 µm²) |
| Target timing | ≥ 20% better slack than reference (+4.0~6.6 ns → > +4.8 ns at 20ns) |

## 8. Verification Requirements

| Category | Test Cases | Priority |
|----------|-----------|----------|
| FMA same sign | A and B×C same sign, normal values | required |
| FMA different sign | Product larger, addend larger, near cancellation | required |
| Sticky/Round | Guard/round/sticky, tie-to-even, large exponent diff | required |
| Zero/FTZ | Product zero, addend zero, subnormal input | required |
| Special values | NaN input, Inf×0, Inf+normal, -Inf, Inf cancellation | required |
| Dot product | Dx/Dy = 0, max, min non-zero, Px/Py opposite signs, dot_p_msb_i combinations | required |
