# fma_fp32_dot3 Specification

## Overview

FP32 Fused Multiply-Add / Dot-Product with 3-stage pipeline.
Area-optimized approximate FMA (not bit-exact fused FMA).
RN-even rounding, input/output FTZ.

## Module Interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| clk | in | 1 | Clock |
| rst_n | in | 1 | Async reset, active low |
| valid_i | in | 1 | Input valid |
| mode_i | in | 1 | 0=FMA (Y=A+B*C), 1=Dot (Y=Ps+Px*Dx+Py*Dy) |
| a_i | in | 32 | FMA: A (addend), Dot: Ps |
| b_i | in | 32 | FMA: B (multiplier), Dot: Px |
| c_i | in | 32 | FMA: C (multiplier), Dot: Py |
| dx_i | in | 12 | Dot: unsigned Q8.4, dx_i[11]=0 |
| dy_i | in | 12 | Dot: unsigned Q8.4, dy_i[11]=0 |
| dot_p_msb_i | in | 2 | Dot: [1]=Px mant MSB, [0]=Py mant MSB |
| valid_o | out | 1 | Output valid |
| y_o | out | 32 | FP32 result |

## Floating Point Semantics

- Input FTZ: subnormal inputs flushed to zero
- Output FTZ: subnormal results flushed to zero
- Rounding: Round-to-Nearest-Even (RN-even)
- Special value priority: NaN > Inf*0 > Inf cancellation > remaining Inf

## Pipeline

3 stages, result at N+2 rising edge from valid_i sample:
- S1: Unpack, special detect, multiply, alignment, operand encoding
- S2: CPA sum, absolute value, LOD, sticky attribution
- S3: Normalize, RN-even round, pack

## Dot Mode Constraints

- Px/Py exponents must be equal
- dx_i[11]=0, dy_i[11]=0
- dot_p_msb_i explicitly gives mantissa MSB (not auto-set to 1)

## Synthesis Target

- Yosys + ABC, SKY130 HD tt_025C_1v80
- Clock: 20.000 ns (50 MHz)
- Reference area: ~40,512 um2, ~5,406 cells
- Reference slack: +4.0 ~ +6.6 ns

## Optimization Targets

- Area: >= 20% smaller than reference
- Timing: >= 20% better slack than reference
- All 22 functional tests must pass
