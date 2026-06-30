# fma_fp32_dot3 — Design Specification

## 1. Overview

| Field | Value |
|-------|-------|
| Module | `fma_fp32_dot3` |
| Language | SystemVerilog (synthesizable subset) |
| Top File | `rtl/design.sv` |
| Clock | Single domain (`clk`) |
| Reset | Asynchronous active-low (`rst_n`) |
| Pipeline | 3 stages (result at N+2 rising edge from valid_i) |

Two modes: FMA (`Y=A+B*C`) and Dot (`Y=Ps+Px*Dx+Py*Dy`).

## 2. Interface

| Port | Dir | Width | FMA | Dot |
|------|-----|-------|-----|-----|
| clk | in | 1 | Clock | Clock |
| rst_n | in | 1 | Async reset (active low) | Same |
| valid_i | in | 1 | Input valid | Same |
| mode_i | in | 1 | 0=FMA | 1=Dot |
| a_i | in | 32 | A: FP32 addend | Ps: FP32 addend |
| b_i | in | 32 | B: FP32 multiplier | Px: FP32 |
| c_i | in | 32 | C: FP32 multiplier | Py: FP32 |
| dx_i | in | 12 | Ignored | Dx: unsigned Q8.4 (bit11=0) |
| dy_i | in | 12 | Ignored | Dy: unsigned Q8.4 (bit11=0) |
| dot_p_msb_i | in | 2 | Ignored | [1]=Px MSB, [0]=Py MSB |
| valid_o | out | 1 | Output valid | Same |
| y_o | out | 32 | FP32 result | Same |

Timing: valid_i sampled at edge N, valid_o asserted at edge N+3.

## 3. Functional Description

### 3.1 FMA Mode (mode_i=0)
```
Y = A + B * C
Pipeline: S1(unpack/multiply/align) → S2(CPA/LOD) → S3(normalize/round/pack)
```

### 3.2 Dot Mode (mode_i=1)
```
Y = Ps + Px*Dx + Py*Dy
Dx/Dy: unsigned Q8.4 fixed-point
Px/Py: use dot_p_msb_i for mantissa MSB (not auto-hidden-bit)
Px/Py exponents must be equal (RTL uses single product anchor)
```

### 3.3 Hardware Reuse
Stages 2 and 3 are mode-agnostic. Only Stage 1 has mode-specific logic.

## 4. Floating-Point Semantics

- **Input FTZ**: subnormal inputs (exp=0) treated as zero
- **Output FTZ**: subnormal results flushed to 0x00000000
- **Rounding**: RN-even (Guard/Round/Sticky extraction)
- **Precision**: area-first approximate FMA (not bit-exact)

## 5. Special Value Priority

| Priority | Condition | Output |
|----------|-----------|--------|
| 1 | Any input NaN | Quiet NaN (0x7FC00000) |
| 2 | Inf * 0 | Quiet NaN |
| 3 | Inf cancellation (FMA: A=Inf with opposite B*C, Dot: conflicting Inf products) | Quiet NaN |
| 4 | Remaining Inf | Signed Inf |

Dot: Dx/Dy are finite unsigned — do not generate NaN/Inf. Inf*0 check per-product: (Px_inf && Dx==0) or (Py_inf && Dy==0).

## 6. Pipeline

```
S1 (mode-aware):        S2 (mode-agnostic):     S3 (mode-agnostic):
Unpack *3              Sign→2's Complement     log_shl normalize
Special Detect         2/3-term CPA             GRS Extract
Multiply (mode-spec)   Absolute Value           RN-even Round
Normalize Product      LOD                      FTZ/Overflow Check
Align to Anchor                                 Pack FP32

Valid chain: valid_i → s2_valid → s3_valid → valid_o
```

## 7. PPA Targets

| Metric | Reference | Target (20% better) |
|--------|-----------|---------------------|
| Area (generic cells) | 19,278 | < 15,422 |
| Timing slack @20ns | +4.0~6.6 ns | > +4.8 ns |
| Synthesis | Yosys + SKY130 HD | Same toolchain |
| STA | OpenSTA (ABC fallback) | Multi-period sweep |
