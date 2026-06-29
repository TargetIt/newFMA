# VERIFY Stage Delivery Report

## Status: PASSED (22/22)

## Test Plan Results

| Test ID | SPEC Source | Category | Case | Result |
|---------|------------|----------|------|--------|
| TEST-001 | REQ-SPEC-001 | FMA same sign | 1.5+2.0*3.0=7.5 | PASS |
| TEST-002 | REQ-SPEC-001 | FMA same sign | 1.0+1.0*1.0=2.0 | PASS |
| TEST-003 | REQ-SPEC-001 | FMA same sign | -1.0+-2.0*3.0=-7.0 | PASS |
| TEST-004 | REQ-SPEC-001 | FMA diff sign | 5+-2*2=1 | PASS |
| TEST-005 | REQ-SPEC-001 | FMA diff sign | 0.5+5*5=25.5 | PASS |
| TEST-006 | REQ-SPEC-001 | FMA diff sign | 3+-1*3=0 (cancel) | PASS |
| TEST-007 | REQ-SPEC-008 | Round | 0.75+1.0*0.5=1.25 | PASS |
| TEST-008 | REQ-SPEC-008 | Round | 1+2^-20*1=1+8ULP | PASS |
| TEST-009 | REQ-SPEC-006,007 | Zero/FTZ | Addend zero | PASS |
| TEST-010 | REQ-SPEC-006,007 | Zero/FTZ | Product zero | PASS |
| TEST-011 | REQ-SPEC-006,007 | Zero/FTZ | Subnormal FTZ | PASS |
| TEST-012 | REQ-SPEC-010 | Special | NaN input → qNaN | PASS |
| TEST-013 | REQ-SPEC-011 | Special | Inf*0 → qNaN | PASS |
| TEST-014 | REQ-SPEC-013 | Special | Inf+normal → Inf | PASS |
| TEST-015 | REQ-SPEC-013 | Special | -Inf+normal → -Inf | PASS |
| TEST-016 | REQ-SPEC-006 | Special | Directed: subnormal FTZ | PASS |
| TEST-017 | REQ-SPEC-002 | Dot | 1+2*1+3*1=6 | PASS |
| TEST-018 | REQ-SPEC-002 | Dot | dx=0 → 1+0+3=4 | PASS |
| TEST-019 | REQ-SPEC-002 | Dot | dx max (127.94) | PASS |
| TEST-020 | REQ-SPEC-002 | Dot | dx min nonzero (0.0625) | PASS |
| TEST-021 | REQ-SPEC-002 | Dot | Opposite sign cancel | PASS |
| TEST-022 | REQ-SPEC-016 | Dot | dot_p_msb_i[1]=0 | PASS |

## Execution Evidence

- **Lint**: iverilog -g2012 -Wall: 0 errors (logs/stage3-lint.log)
- **Simulation**: vvp tb.out: 22 pass, 0 fail (logs/stage3-simulation.log)
- **Reference model**: Python bit-accurate (tb/ref_model.py)

## Gate Check

- [x] 22/22 tests pass
- [x] 0 failures
- [x] All SPEC verification entries (REQ-SPEC-023, CR-009) covered
- [x] Test categories match spec Section 8

## Decision: GATE OPEN → proceed to Stage 4 (SYNTH)
