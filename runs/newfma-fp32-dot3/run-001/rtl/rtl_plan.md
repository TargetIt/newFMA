# RTL Plan

## 1. Feature List (SPEC → RTL)

| Feature | SPEC Source | Description |
|---------|------------|-------------|
| FEAT-001 | REQ-SPEC-001,002 | Module fma_fp32_dot3 with mode_i select |
| FEAT-002 | REQ-SPEC-003~005 | 12-port interface with dual semantics |
| FEAT-003 | REQ-SPEC-006,007 | FTZ logic (input + output) |
| FEAT-004 | REQ-SPEC-008 | RN-even rounding (G/R/S extraction) |
| FEAT-005a | REQ-SPEC-010~013 | FMA special values (resolve_special) |
| FEAT-005b | REQ-SPEC-014 | Dot special values (per-product Inf*0) |
| FEAT-006a | REQ-SPEC-015 | Dot Q8.4 handling |
| FEAT-006b | REQ-SPEC-016 | dot_p_msb_i external hidden bit |
| FEAT-007a | REQ-SPEC-017,018 | 3-stage pipeline registers |
| FEAT-007b | REQ-SPEC-019 | Valid chain |
| FEAT-008 | REQ-SPEC-020,021 | Synthesizable RTL |
| FEAT-009a-e | REQ-SPEC-024,025 | Optimizations: INT_W=28, 24x12, 24x11, log shifter, dead regs |

## 2. Execution Steps
1. Define parameters (INT_W=28, MANT_FULL=24, BIAS=127)
2. Implement unpack_ftz, unpack_dot, resolve_special, log_shr, log_shl
3. Implement Stage 1: FMA path + Dot path
4. Implement Stage 2: signed CPA (2/3-term) + LOD
5. Implement Stage 3: normalize + RN-even + pack
6. Lint: iverilog -g2012 -Wall
7. Verify: run tb/

## 3. Deliverables
- rtl/design.sv (~593 lines)
- rtl/rtl_strategy.md, rtl/rtl_plan.md
- rtl/reports/rtl_report.md
