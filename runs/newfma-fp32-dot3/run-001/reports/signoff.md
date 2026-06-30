# Project Sign-Off Report

**Date:** 2026-06-30 13:21 UTC

**Overall:** ❌ FAIL — {failed_count} requirement(s) not met

**Verdict:** 6/10 passed, 2 partial, 2 failed
**Project:** run-001

---

## Requirement-by-Requirement Verification

### CR-001: 顶层功能 FMA+Dot

**需求:** 顶层功能
> 模块名：fma_fp32_dot3。支持两种模式（mode_i 选择）：
> - mode_i=0: Y = A + B * C (FMA 模式)
> - mode_i=1: Y = Ps + Px*Dx + Py*Dy (D...

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-001, REQ-SPEC-002 |
| rtl | FEAT-001 |
| verify | 12 tests |
| synth | — |
| timing | — |

**判定: ✅ PASS** — 需求已达成

---

### CR-002: 端口定义 12 ports

**需求:** 端口定义
| 端口 | 方向 | 位宽 | FMA 语义 | Dot 语义 |
|------|------|------|---------|---------|
| clk | input | 1 | 时钟 | 时钟 |
| rst_n...

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-003~005 |
| rtl | FEAT-002 |
| verify | implicit via all tests |
| synth | — |
| timing | — |

**判定: ✅ PASS** — 需求已达成

---

### CR-003: 浮点语义 FTZ/RN-even

**需求:** 浮点语义
- 输入 FTZ (Flush-To-Zero): 有限且 exp==0 的输入视为零
- 输出 FTZ: 输出 subnormal 结果统一 flush-to-zero
- 舍入模式: Round-to-Nearest-Even...

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-006~009 |
| rtl | FEAT-003, FEAT-004 |
| verify | 6 tests |
| synth | — |
| timing | — |

**判定: ✅ PASS** — 需求已达成

---

### CR-004: 特殊值优先级

**需求:** 特殊值处理优先级
1. 任一输入 NaN → 输出 quiet NaN
2. Inf * 0 → 输出 quiet NaN
3. A 为 Inf 且 B*C 为相反符号 Inf → 输出 quiet NaN
4. 剩余 Inf → 输出对应...

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-010~014 |
| rtl | FEAT-005a, FEAT-005b |
| verify | 5 tests |
| synth | — |
| timing | — |

**判定: ✅ PASS** — 需求已达成

---

### CR-005: Dot 约束 Q8.4/MSB

**需求:** Dot 模式约束
- Px/Py exponent 必须相等，RTL 只用一个 product exponent anchor
- dx_i[11]=0、dy_i[11]=0
- dot_p_msb_i 显式给出 mantissa MSB（...

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-015, REQ-SPEC-016 |
| rtl | FEAT-006a, FEAT-006b |
| verify | 6 tests |
| synth | — |
| timing | — |

**判定: ✅ PASS** — 需求已达成

---

### CR-006: 流水线 3-stage

**需求:** 流水线
- 3-stage pipeline
- 从 valid_i 采样边沿计，结果在第 N+2 个上升沿有效
- Stage1: FP32 unpack、特殊值检测、乘法、对齐、operand 编码
- Stage2: CPA 求和、取...

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-017~019 |
| rtl | FEAT-007a, FEAT-007b |
| verify | 无独立延迟测试 |
| synth | — |
| timing | — |

**判定: ⚠️ PARTIAL** — 部分达成
**遗留:** 缺少显式 3-cycle 延迟测试（功能正确，低优先级）

---

### CR-007: 综合/STA 工具

**需求:** 综合与 STA 目标
- RTL: fma_fp32_dot3.v（单文件）
- 综合器: Yosys
- 工艺库: SKY130 HD typical corner (sky130_fd_sc_hd__tt_025C_1v80.lib)
...

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-020, REQ-SPEC-021 |
| rtl | FEAT-008 |
| verify | — |
| synth | Yosys+ABC+SKY130, synth-top flow |
| timing | ABC替代OpenSTA |

**判定: ⚠️ PARTIAL** — 部分达成
**遗留:** OpenSTA 不可用，用 ABC 时序驱动综合替代；flatten 代替 hierarchy

---

### CR-008: 验证要求

**需求:** 参考 PPA 基线
| 指标 | 值 |
|------|-----|
| Hierarchy 总面积 | ~40,512 µm² |
| Flatten 总面积 | ~39,660 µm² |
| 总 cell 数 | ~5,406 |
...

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-023 |
| rtl | — |
| verify | 22/22 (6 类别) |
| synth | — |
| timing | — |

**判定: ✅ PASS** — 需求已达成

---

### CR-009: 优化目标 vs 参考

**需求:** 验证要求
必须覆盖的测试类别：FMA 同号、FMA 异号、Sticky/Round、Zero/FTZ、Special(NaN/Inf)、Dot(dx/dy边界/dot_p_msb_i组合/Px/Py异号)

| Stage | Coverage |
|-------|----------|
| spec | REQ-SPEC-024, REQ-SPEC-025 |
| rtl | FEAT-009a~e (INT_W=28, 24x12, 24x11, log shifter, dead regs) |
| verify | — |
| synth | 面积 52,100 um2 (参考 40,512), cells 7,560 (参考 5,406) |
| timing | >60% faster (8ns MET) |

**判定: ❌ FAIL** — 未达成
**原因:** 面积 +28.6%, cells +39.8% vs 参考。时序达标但面积未达标。需进一步优化或重新设计架构。

---

### CR-010: CR-010

**需求:** 优化目标
- 面积比参考好 ≥20%
- 时序比参考好 ≥20%

| Stage | Coverage |
|-------|----------|
| spec | — |
| rtl | — |
| verify | — |
| synth | — |
| timing | — |

**判定: ❌ FAIL** — 未达成
**原因:** 

---

## Action Items (Partial Requirements)

- **CR-006** (流水线 3-stage): 缺少显式 3-cycle 延迟测试（功能正确，低优先级）
- **CR-007** (综合/STA 工具): OpenSTA 不可用，用 ABC 时序驱动综合替代；flatten 代替 hierarchy

## Evidence Inventory

- ✅ `spec/spec.md`
- ✅ `spec/reports/spec_report.md`
- ✅ `rtl/fma_fp32_dot3.v`
- ✅ `rtl/reports/rtl_report.md`
- ✅ `tb/reports/verify_report.md`
- ✅ `logs/stage3-simulation.log`
- ✅ `scripts/reports/synth_report.md`
- ✅ `logs/stage4-synth-sky130.log`
- ✅ `scripts/sta/reports/sta_report.md`
- ✅ `logs/stage5-sta.log`
- ✅ `reports/final.md`