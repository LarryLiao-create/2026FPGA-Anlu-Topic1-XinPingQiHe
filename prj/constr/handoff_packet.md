# 交接说明（handoff_packet）

## 本轮完成

- 修正 `src/user_source/constraints_source/pin.adc` 中 3 个按键端口的管脚分配：
  - `key1`  B2 → **A2**（板上 KEY_1）
  - `key2`  C1 → **B2**（板上 KEY_2）
  - `rst_n` A2 → **C1**（板上 KEY_4）
- 新增 2 行注释，记录板载按键↔引脚对应关系与各端口语义。
- 生成 `prj/constr/pin_summary.md`（本轮）。

## 生成方式

- **模板驱动**：沿用工程既有 `pin.adc` 的 `set_pin_assignment { port } { ... }` 风格与排版；
  未新建约束文件、未重命名，直接最小修改生效文件。
- 事实来源：`doc/hw/config.json` → `board_profile.signals`（与板卡手册 §⑯ 及原理图交叉核对）。
  本工程无 `doc/hw/extracted_facts.json`，按流程回退到 `config.json`。

## 产物路径

- 主约束（已修改）：`src/user_source/constraints_source/pin.adc`
- 时序约束（未改）：`src/user_source/constraints_source/timing.sdc`
- 摘要：`prj/constr/pin_summary.md`
- 交接：`prj/constr/handoff_packet.md`

## 下一步（建议，未自动执行）

1. 在 TD 6.2 中重新 Run（syn → phy）生成新的 `.bit`，再下载到板卡。
2. 复测 4 颗按键：KEY1(A2) 手动切图、KEY2(B2) 切自动轮播、KEY4(C1) 复位、KEY3(B1) 本版空置。
3. 若某颗键在重新编译后仍不动作，检查是否 RTL 消抖极性/触发条件问题（当前 `key_press_debounce` 为低有效、单拍脉冲，与板卡一致）。

## 验证命令（建议，均未执行）

- 重新跑 TD 工程（GUI 或 CLI）：
  - 工程：`src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/HDMI1.4b_Transmitter_v1.0.tcl`
- 核对实现结果里按键落位（实现后可在 `*_phy.area` 中确认）：
  - 期望：`key1 → A2`、`key2 → B2`、`rst_n → C1`

## 未解决 / 风险

- 顶层端口↔板上网络的完整映射尚未固化进 `config.json`，`constraint_ready` 仍为 `false`。
  本次为既有工程最小修正，不受该旗标阻塞；若后续要重生成全套约束，需先补该映射。
- 本次**未**改动任何 RTL，也未运行综合/实现/仿真。
