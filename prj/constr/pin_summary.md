# 管脚约束摘要（pin_summary）

- 工程：med_screen
- 顶层模块：`top`（`src/user_source/hdl_source/top_tf_hdmi_audio.v`）
- 芯片 / 板卡：Anlogic EG4S20BG256B / 康芯 HX4S20（LFBGA256）
- 工具链：Tang Dynasty (TD) 6.2.168116
- 生效约束文件：`src/user_source/constraints_source/pin.adc`
  - 被 `src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/syn_1/HDMI1.4b_Transmitter_v1.0.prj`
    与 `.../phy_1/HDMI1.4b_Transmitter_v1.0.prj` 以 `ADC_FILE` 引用，属当前实际生效的引脚约束。
- 时序约束：`src/user_source/constraints_source/timing.sdc`（`SDC_FILE`），本次未改动。
- 事实来源：`doc/hw/config.json` → `board_profile.signals`（`constraint_status = manual_and_schematic_cross_checked`）
  - 交叉核对：板卡手册《HX4S20 开发板手册-HDL 版 2410》第 ⑯ 节「4 组按键」+ 按键原理图。
- 模板：本次为**模板驱动**——直接沿用 `pin.adc` 既有的 `set_pin_assignment { <port> } { LOCATION=..; IOSTANDARD=..; PULLTYPE=..; }` 写法与排版，未新建文件、未改文件名。

> 说明：`doc/hw/extracted_facts.json` 在本工程不存在，故按流程回退使用 `doc/hw/config.json` 的板级事实。
> `config.json` 中 `constraint_ready = false`，其 blocking reason `project_top_ports_not_confirmed`
> 针对的是“从头生成整套约束”的场景；本次是**既有工程按键约束的最小修正**，端口↔板上网络映射已由用户确认，故不受该旗标阻塞。

## 本次变更（仅 3 行 LOCATION）

| RTL 顶层端口 | 变更前 LOCATION | 变更后 LOCATION | 板上网络 | 板载丝印 | 有效电平 | IOSTANDARD | PULLTYPE | source_ref |
|---|---|---|---|---|---|---|---|---|
| `key1`  | B2 | **A2** | KEY_1 | KEY1 | 低有效 | LVCMOS33 | NONE | config.json sign.4 / 手册 §⑯ |
| `key2`  | C1 | **B2** | KEY_2 | KEY2 | 低有效 | LVCMOS33 | NONE | config.json sign.5 / 手册 §⑯ |
| `rst_n` | A2 | **C1** | KEY_4 | KEY4 | 低有效 | LVCMOS33 | NONE | config.json sign.7 / 手册 §⑯ |

变更前的问题：`key1/key2/rst_n` 分别落在板上 KEY2/KEY4/KEY1，与端口语义串位，且板上 KEY3(B1) 未使用。
（旧映射可在 `syn_1/run.log:270-272` 与 `phy_1/*_phy.area:34-36` 中复现。）

## 未使用但仍被消费的 PULLTYPE 取值说明

- `PULLTYPE = NONE`：保持与文件既有风格一致，且最小改动。
  依据：手册明确「按键按下为低电平，松开为高电平」，说明板上已有外部上拉电阻，无需启用 FPFA 内部上拉。
- 若后续发现某颗按键悬空或上拉不足，可将对应行改为 `PULLTYPE = PULLUP`（内部上拉，与外部上拉并联、无副作用）。

## 本次未涉及 / 未改动

- 板上 KEY3（B1）：本次不使用，**未分配约束**（避免占用未使用的 I/O）。
- `clk`(R7)、`sd_*`(A12/A13/A14/B14)、`seg_*`、`HDMI_*`(C3/E1/F1/G5/P2/R2) 等其余端口：LOCATION/IOSTANDARD 保持不变。
- 时序约束 `timing.sdc`：未改动（本次问题与时钟无关）。

## 缺口 / 待确认

- `pin.adc` 中存在若干**已注释**的历史端口（如 `I_key_in`=A2、`vga_*`、`I_sys_clk`、`O_tmds_*`），本次未触碰。
  注意：被注释的 `I_key_in { LOCATION = A2 }` 与本次 `key1=A2` 指向同一颗物理按键，属历史遗留，无冲突。
- 顶层端口与板上网络的**完整**映射表（用于从头再生成整套约束）仍未在 `config.json` 中固化；
  若后续要重生成全套约束，需要先把该映射确认写回，解除 `constraint_ready=false`。
