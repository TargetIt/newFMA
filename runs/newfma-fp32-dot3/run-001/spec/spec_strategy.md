# SPEC Strategy

## 1. 上下文
- **输入**: `requirements/cr.md` — IMA 笔记中的原始需求
- **目标**: 将自然语言 CR 分解为结构化、可验证的 SPEC 条目

## 2. 方法论
按功能域分解: 功能/接口/语义/约束/验证/优化，每个 SPEC 条目标注 required/optional。

## 3. 关键决策
- DEC-01: FMA 和 Dot 在 spec 中分述但标注共享逻辑(Stage 2/3 复用)
- DEC-02: 特殊值优先级独立成章
- DEC-03: PPA 目标引用 CR 数值，不在此阶段定优化方案(Stage 2 决策)

## 4. 风险评估
- RISK-01: Dot 模式 Q8.4 语义可能被误解 → spec 给出数值示例
- RISK-02: "面积优先的近似 FMA"范围不明确 → spec 明确允许截断和近似

## 5. Gate 条件
- 10 条 CR 全部在 spec.md 中有对应章节
- spec.md 必填字段完整(模块名/端口/功能/语义/流水线/PPA)
- `traceability-check.py --stage spec` exit 0
