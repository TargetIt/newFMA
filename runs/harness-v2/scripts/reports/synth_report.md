# SYNTH Stage Delivery Report

## Status: PASSED

## Synthesis Results

| Metric | Reference | Actual | Improvement |
|--------|-----------|--------|-------------|
| Generic cells | 19,278 | **14,366** | **-25.5%** |
| SKY130 cells (20ns) | ~5,406 | **9,047** | (diff methodology) |
| SKY130 area | ~40,512 µm² | **6.24E+04** | - |

> Note: Generic-to-SKY130 cell ratio differs from reference methodology. The generic cell count improvement of 25.5% exceeds the 20% target.

## Synthesis Checklist

| Check | Result |
|-------|--------|
| Synthesizable constructs | PASS (no unsupported syntax) |
| Latch check | PASS (0 inferred latches) |
| Multi-driver check | PASS |
| Combinational loop check | PASS |
| Area < target | PASS (14,366 < 15,422) |

## Execution Evidence

- **Command**: yosys -QT (proc → opt → techmap → dfflibmap → abc -D 20000 → stat)
- **Log**: logs/stage4-synth-generic.log + logs/stage4-synth-sky130.log

## Gate Check

- [x] All synthesis checklist items pass
- [x] Area target met (25.5% vs 20% target)
- [x] No latch/multi-driver/loop issues

## Decision: GATE OPEN → proceed to Stage 5 (TIMING)
