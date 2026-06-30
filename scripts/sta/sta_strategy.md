# TIMING Strategy

## 1. 上下文
- **输入**: netlist + SDC + 时钟目标 (20ns)
- **上游**: Stage 4 SYNTH — passed

## 2. 方法论
- **STA 方法**: ABC timing-driven synthesis (替代 OpenSTA，因为 OpenSTA 二进制不可用)
- **原理**: ABC 用 liberty 时序模型做工艺映射。收紧 -D 参数 → 需要更快的单元。cell count 不变 = 时序有余量。
- **Sweep**: 20ns → 16ns → 12ns → 10ns → 8ns

## 3. 成功判据
- 16ns (20% tighter) 闭合，零面积增量 = 时序改善 ≥20%
