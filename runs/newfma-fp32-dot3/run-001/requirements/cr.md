# Customer Requirements (CR)

## Source

IMA note "newFMA" — 用户笔记中的原始需求规格。

## Reference Baseline (IMPORTANT)

参考设计是**别人的独立实现**，不是我们的早期版本。我们只有其 PPA 数据，没有 RTL 源码。

| 指标 | 参考值（别人做的） | 来源 |
|------|-------------------|------|
| SKY130 总面积 (Hierarchy) | ~40,512 µm² | IMA 笔记 |
| SKY130 总面积 (Flatten) | ~39,660 µm² | IMA 笔记 |
| SKY130 总 cell 数 | ~5,406 | IMA 笔记 |
| Setup worst slack (20ns) | +4.0 ~ +6.6 ns | IMA 笔记 |
| Hold worst slack | +0.31 ns | IMA 笔记 |
| 综合工具 | Yosys + SKY130 HD | IMA 笔记 |
| RTL 源码 | **不持有** | — |

> **关键约束：我们不能看参考的 RTL。必须从零设计自己的实现，且 PPA 比参考好 >=20%。**

## Functional Requirements

### CR-001: 顶层功能

模块名：fma_fp32_dot3。支持两种模式（mode_i 选择）：
- mode_i=0: Y = A + B * C (FMA 模式)
- mode_i=1: Y = Ps + Px*Dx + Py*Dy (Dot 模式)

### CR-002: 端口定义

| 端口 | 方向 | 位宽 | FMA 语义 | Dot 语义 |
|------|------|------|---------|---------|
| clk | input | 1 | 时钟 | 时钟 |
| rst_n | input | 1 | 异步复位，低有效 | 异步复位，低有效 |
| valid_i | input | 1 | 输入有效 | 输入有效 |
| mode_i | input | 1 | 模式选择 | 模式选择 |
| a_i | input | 32 | A (FP32 addend) | Ps (FP32 addend) |
| b_i | input | 32 | B (FP32 乘数) | Px (FP32) |
| c_i | input | 32 | C (FP32 乘数) | Py (FP32) |
| dx_i | input | 12 | 忽略 | unsigned Q8.4，约束 dx_i[11]=0 |
| dy_i | input | 12 | 忽略 | unsigned Q8.4，约束 dy_i[11]=0 |
| dot_p_msb_i | input | 2 | 忽略 | [1]=Px mantissa MSB, [0]=Py mantissa MSB |
| valid_o | output reg | 1 | 输出有效 | 输出有效 |
| y_o | output reg | 32 | FP32 结果 | FP32 结果 |

### CR-003: 浮点语义

- 输入 FTZ: 有限且 exp==0 的输入视为零
- 输出 FTZ: 输出 subnormal 结果统一 flush-to-zero
- 舍入模式: Round-to-Nearest-Even (RN-even)
- 精度定位: 面积优先的近似 FMA/Dot 数据通路，在 FP32 边界上做 RN-even pack，不是 bit-exact fused FMA

### CR-004: 特殊值处理优先级

1. 任一输入 NaN → 输出 quiet NaN
2. Inf * 0 → 输出 quiet NaN
3. A 为 Inf 且 B*C 为相反符号 Inf → 输出 quiet NaN
4. 剩余 Inf → 输出对应符号 Inf
- Dot 模式下 A/B/C 的 Inf 视作独立项；Dx/Dy 不参与 NaN/Inf 生成

### CR-005: Dot 模式约束

- Px/Py exponent 必须相等，RTL 只用一个 product exponent anchor
- dx_i[11]=0、dy_i[11]=0
- dot_p_msb_i 显式给出 mantissa MSB（不等同于 FP32 hidden bit 自动置 1）

### CR-006: 流水线

- 3-stage pipeline
- 从 valid_i 采样边沿计，结果在第 N+2 个上升沿有效
- Stage1: FP32 unpack、特殊值检测、乘法、对齐、operand 编码
- Stage2: CPA 求和、取绝对值、leading-one 检测、sticky 归属
- Stage3: 归一化、RN-even 舍入、特殊值/直通/正常结果打包
- Valid 链路：valid_i → s2_valid → s3_valid → valid_o

### CR-007: 综合与 STA 目标

- 综合器: Yosys（与参考相同的工具链）
- 工艺库: SKY130 HD typical corner (sky130_fd_sc_hd__tt_025C_1v80.lib)
- STA: OpenSTA 或等价工具
- 时钟约束: 20.000 ns
- 保留子模块层级（不 flatten），便于面积归因

### CR-008: 验证要求

必须覆盖的测试类别：FMA 同号、FMA 异号、Sticky/Round、Zero/FTZ、Special(NaN/Inf)、Dot(dx/dy边界/dot_p_msb_i组合/Px/Py异号)

### CR-009: 优化目标

- 面积比参考（40,512 µm², 5,406 cells）好 ≥20% → 目标 < 32,410 µm², < 4,325 cells
- 时序比参考（slack +4.0~6.6ns @20ns）好 ≥20% → 目标 slack > +4.8ns @20ns
- 优化幅度以**同工具链下的综合结果**为准（Yosys + SKY130 HD + 20ns 约束）
