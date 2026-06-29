# VERIFY Strategy

## 1. 上下文
- **输入**: spec.md (25 SPEC 条目) + RTL
- **上游状态**: Stage 2 RTL — passed

## 2. 方法论
- **验证方法**: Directed test (直接测试), 22 个测试用例覆盖所有 SPEC 验证需求
- **工具**: Icarus Verilog (iverilog + vvp), Python3 参考模型
- **参考模型**: bit-accurate Python ref_model.py (mirrors RTL datapath exactly: INT_W=40, 24×12 FMA, 24×11 Dot, RN-even, FTZ)

## 3. 测试分解 (SPEC → Test Plan)

| Category | Tests | SPEC Source |
|----------|-------|-------------|
| FMA same sign | 3 | REQ-SPEC-001 |
| FMA different sign | 3 | REQ-SPEC-001 |
| Sticky/Round | 2 | REQ-SPEC-008 |
| Zero/FTZ | 3 | REQ-SPEC-006, 007 |
| Special (NaN/Inf) | 5 | REQ-SPEC-010~014 |
| Dot product | 6 | REQ-SPEC-002, 015, 016 |

## 4. 进入 Stage 4 的条件
- 22/22 测试通过
- 0 fail
