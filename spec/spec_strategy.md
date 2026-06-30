# SPEC Strategy

## 1. 上下文

- **输入**: `requirements/stage_inputs/spec_input.md` — 10 条 Customer Requirements
- **上游**: 无（Stage 1 是起点）
- **目标**: 将自然语言 CR 分解为结构化的、可验证的 SPEC 条目

## 2. 方法论

**分解策略**: 按功能域分解 CR：
- 功能需求 (functional) → 数学公式、运算模式、数据流
- 接口需求 (interface) → 端口定义、时序合约
- 浮点语义 (semantic) → FTZ、舍入、特殊值
- 时序约束 (timing) → 流水线深度、延迟、时钟
- 物理约束 (constraint) → PPA 目标、工艺库、综合工具
- 验证需求 (verification) → 测试类别

**结构化层次**: spec.md 按自顶向下组织：
1. 概述与模块标识
2. 接口定义
3. 功能描述（FMA + Dot 分别描述，突出共享/分叉）
4. 浮点语义
5. 流水线架构
6. 综合与 PPA 目标

## 3. 关键决策

- **DEC-01**: FMA 和 Dot 在 spec 中分别描述其独有逻辑，但明确标注共享部分（Stage 2/3 复用）
- **DEC-02**: 特殊值优先级作为独立章节，因为两个模式都涉及
- **DEC-03**: PPA 目标从 CR 直接引用，不在此阶段设定具体优化方案（那是 Stage 2 的决策）
- **DEC-04**: spec 不规定微架构细节（如位宽、乘法器大小），只规定功能正确性和 PPA 目标

## 4. 风险评估

- **RISK-01**: Dot 模式的 Q8.4 定点数语义可能被误解 → 在 spec 中显式给出 Q8.4 的定义和数值示例
- **RISK-02**: 特殊值优先级中的 "Inf 抵消" 条件可能不完整 → 在 spec 中给出所有组合的真值表

## 5. 进入 Stage 2 的条件

- 10 条 CR 全部在 spec.md 中有对应章节
- spec.md 的所有必填字段完整（模块名、端口、功能、语义、流水线、PPA）
- RTM 映射无 orphan
