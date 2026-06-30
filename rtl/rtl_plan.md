# RTL Plan

## 1. 分解后的需求清单

来源：`requirements/stage_inputs/rtl_input.md` (SPEC → RTL Feature List)

| Feature ID | SPEC Source | Description |
|-----------|-------------|-------------|
| FEAT-001 | REQ-SPEC-001/002 | 顶层模块 fma_fp32_dot3，mode_i 选择 FMA/Dot |
| FEAT-002 | REQ-SPEC-003/004/005 | 12 端口接口，含双语义映射 |
| FEAT-003 | REQ-SPEC-006/007 | FTZ 逻辑：输入检测 exp=0，输出检测 norm_exp≤0 |
| FEAT-004 | REQ-SPEC-008 | RN-even 舍入：G/R/S 提取，tie-to-even |
| FEAT-005 | REQ-SPEC-010~014 | 特殊值检测：NaN, Inf, Inf×0, Inf 抵消 (FMA + Dot) |
| FEAT-006 | REQ-SPEC-015/016 | Dot 模式：Q8.4 处理，dot_p_msb_i 隐藏位 |
| FEAT-007 | REQ-SPEC-017/018/019 | 3 级流水线 + valid 链 |
| FEAT-008 | REQ-SPEC-020/021 | 可综合 RTL (无 initial/forever/system functions) |
| FEAT-009 | REQ-SPEC-024/025 | 面积/时序优化 (40-bit, 24×12, log shifter, dead reg elimination) |

## 2. 执行步骤

1. 定义模块接口和参数 (INT_W, MANT_FULL, etc.)
2. 实现辅助函数: unpack_ftz, unpack_dot, resolve_special, log_shr, log_shl
3. 实现 Stage 1 (FMA 分支): unpack → 24×12 mul → normalize → align
4. 实现 Stage 1 (Dot 分支): unpack → 24×11 mul ×2 → LOD normalize → 3-term align
5. 实现 Stage 2: signed term conversion → CPA (2/3-term) → abs → LOD
6. 实现 Stage 3: log_shl normalize → GRS extract → RN-even → FTZ/pack
7. Lint check (iverilog -g2012 -Wall)
8. Simulation verification (22 test cases)

## 3. 产物清单

- `rtl/fma_fp32_dot3.v` (591 lines)
- `rtl/rtl_strategy.md`
- `rtl/rtl_plan.md`
- `rtl/reports/rtl_report.md`

## 4. 验证方法

- **语法**: iverilog -g2012 -Wall (0 error)
- **功能**: 22 项测试 (FMA×11, Dot×6, 特殊值×5)
- **覆盖率**: 所有 SPEC 功能条目有对应测试
