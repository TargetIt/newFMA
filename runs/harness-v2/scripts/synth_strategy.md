# SYNTH Strategy

## 1. 上下文
- **输入**: RTL + CONSTRAINTS (SDC) + PPA targets from spec
- **上游**: Stage 3 VERIFY — passed

## 2. 方法论
- **综合工具**: Yosys 0.66 + ABC
- **工艺库**: SKY130 HD (sky130_fd_sc_hd__tt_025C_1v80)
- **优化目标**: Area-first (面积优先)，满足 20ns 时序约束
- **流程**: proc → opt → techmap → dfflibmap → abc -D 20000

## 3. PPA 对照

| Metric | Reference | Target (20% better) |
|--------|-----------|---------------------|
| Generic cells | 19,278 | < 15,422 |
| SKY130 cells | ~5,406 | < 4,325 |
| Area | ~40,512 µm² | < 32,410 µm² |
