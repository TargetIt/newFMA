# RTL Strategy

## 1. 上下文
- **输入**: spec.md (25 SPEC entries)
- **目标**: 实现满足所有 SPEC 条目的 synthesizable RTL，面积和时序优化 >=20% vs 参考

## 2. 核心决策

| ID | Decision | Rationale |
|----|----------|-----------|
| DEC-01 | INT_W=28 | Hard minimum: INT_W-27>=0 for GRS bits. -52% vs reference 58-bit |
| DEC-02 | FMA multiplier 24x12 | 24x24→24x12: -50% partial products. c_mant[23:12] with <<12 compensation |
| DEC-03 | Dot multiplier 24x11 | dx_i/dy_i are 11-bit effective. Direct multiply, not 24x24 padded |
| DEC-04 | Logarithmic shifters | 6-stage log_shr/log_shl: ~240 cells vs ~1600 for barrel |
| DEC-05 | S2 mode-agnostic via |s2_sign3| | FMA sets sign3=0, Dot may set it non-zero. S2 checks |s2_sign3|
| DEC-06 | S3 zero mode awareness | Normalize/round/pack identical for both modes |
| DEC-07 | Dead register elimination | s2_mode, s3_mode, s2_sign_eff, prod_sign_bit removed |

## 3. Gate 条件
- Lint: iverilog -g2012 -Wall exit 0
- All SPEC→RTL features covered in design.sv
- `traceability-check.py --stage rtl` exit 0
