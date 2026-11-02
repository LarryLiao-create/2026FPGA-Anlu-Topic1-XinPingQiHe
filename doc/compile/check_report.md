# 编译检查报告 —— 图片切换淡入淡出转场

日期：2026-10-12　工程：med_screen（安路 EG4S20BG256B）
工具：Icarus Verilog 12.0（`iverilog -g2001 -tnull`，仅语法/elaboration 检查，未运行仿真、未生成 VCD）

## 1. 结论

**PASS**（exit code = 0，0 error）。

## 2. 检查分层与结果

| 层级 | 范围 | 命令 | 结果 |
|---|---|---|---|
| A | 3 个新增单模块 | `iverilog -g2001 -tnull -Wall xfd_ctrl.v / xfd_disp_pipe.v / xfd_line_fetch.v` | rc=0，**无告警** |
| A | `frame_fifo_read.v`（已改） | 单文件 `-tnull -Wall` | rc=0 |
| A | `video_timing_data.v`（已改） | 单文件 | 仅 Unknown module: color_bar（缺子模块，非语法错误） |
| A | `sd_card_bmp.v`（已改） | 单文件 | 仅 Unknown module: bmp_read/sd_card_top（同上） |
| A | 整个 `SD/*.v` 目录 | 联合 `-tnull` | 无语法错误（仅 timescale 提示 + 缺 FIFO IP） |
| B | 转场子系统 | `xfd_ctrl + xfd_disp_pipe + xfd_line_fetch + xfd_top + al_ip/RAM_0.v + EG_LOGIC_BRAM 桩` | rc=0 |
| C | **整设计顶层 `top`** | 全部可编译源码 + `al_ip/*.v` + 厂商原语桩 | **rc=0，0 error** |

层级 C 证明：`top_tf_hdmi_audio.v` 的全部例化端口与各子模块声明**完全匹配**，包括本次改动涉及的
`xfd_top`、`sd_card_bmp.xfd_busy`、`video_timing_data.xfd_en`、`video_delay` 输出改名、
`frame_read_write` 的 `App_rd_en/App_rd_addr/Sdr_rd_en/read_len`。

## 3. 语法/端口修复记录

| # | 文件 | 问题 | 修复 |
|---|---|---|---|
| 1 | `xfd_line_fetch.v` | `BURST_BITS = $clog2(BURST_SIZE+1)` = 9，导致 `burst_cnt+1` 在 256 处回绕，burst 永不终止、丢失 burst 间 drain 间隔 | 改为 `$clog2(BURST_SIZE)+2`（=10），保证计数不回绕 |
| 2 | `xfd_line_fetch.v` | F_DRAIN 期间新增 `app_rd_en_r` 未撤销，会重复发约 1280 个多余读请求 | 转入 F_DRAIN 时撤销 `app_rd_en_r`，并在请求条件中加 `fsm_state==F_REQ` 双重保险 |
| 3 | `xfd_line_fetch.v` | 收尾会多发 1 个越界请求（`addr_cnt` 256/512/768/1024/1280） | 请求条件加 `addr_cnt < TOTAL` |
| 4 | `xfd_line_fetch.v` | 缺超时保护，若丢脉冲 F_DRAIN 永久挂死 | 新增 `drain_tmo`，8191 拍（≈65us）后强制退出 |
| 5 | `xfd_disp_pipe.v` | 混合取字节错位：取的是 `dob[23:0]`，而 SDRAM 像素布局为 `{R[31:24],G[23:16],B[15:8],8'b0}`（依据 `sd_card_bmp` 写端与 `video_delay` 读端） | 改为取 `[31:24]/[23:16]/[15:8]` |
| 6 | `xfd_ctrl.v`、`xfd_line_fetch.v` | 缺 `timescale` 指令 | 补 `` `timescale 1ns / 1ps `` |

> 修复 1–4 属功能性缺陷（非语法错误），已一并定点修好；修复 5 若不加，画面会整体偏色/错位。

## 4. 剩余告警（全部为改动前既有，无行为影响）

12 条，均为**端口位宽剪裁**类：

- `top_tf_hdmi_audio.v`: `read_addr_0/1/3`、`write_addr_0/1/3`、`read_len`、`write_len` 传入 24 bit，端口为 21 bit（剪掉高 3 位）；
  `read_addr_2`/`write_addr_2` 传入 56 bit（`BUF2_ADDR = 2 * 24'd307200` 的乘法位宽），剪掉高 35 位。
- `frame_read_write.v`: `frame_fifo_write.rdusedw`（9→10）、`frame_fifo_read.wrusedw`（9→10）。

**均为既有代码的参数位宽声明风格**（`parameter BUF0_ADDR = 24'd0` 等），剪裁值均在 21 bit 有效范围内（最大 614400 < 2^21），不改变功能。本次未改动这些参数声明，保持最小改动。

## 5. 检查用临时桩文件（不入综合）

| 文件 | 用途 |
|---|---|
| `sim/eg_logic_bram_stub.v` | 安路原语 `EG_LOGIC_BRAM` 的行为桩（PDPW 语义，读延迟 1 拍），供 `RAM_0` 在 iverilog 下 elaborate |
| `sim/vendor_prim_stub.v` | `EG_PHY_PLL`/`EG_LOGIC_BUFG`/`EG_LOGIC_ODDR`/`EG_PHY_SDRAM_2M_32`/`sdr_as_ram`/`hdmi_1_4b_transmitter_core_wrapper` 的空实现桩 |

> 两者仅用于本次编译检查，**不在 TD 工程文件列表内，不参与综合**。

## 6. 未能覆盖的部分（属工具链模型缺失，非语法问题）

- 加密 IP：`hdmi_1_4b_transmitter_core_wrapper.enc.v`、`sdr_as_ram.enc.v`（及 `sdr_init_ref`、`sdr_wrrd`）—— iverilog 无法解析 `.enc.v`，已用端口一致的桩替代。
- 厂商原语：`EG_PHY_PLL`、`EG_PHY_SDRAM_2M_32`、`EG_LOGIC_ODDR/BUFG` —— 无 iverilog 模型，已用桩替代。
- 因此**功能正确性、时序收敛、资源占用**仍需在安路 TD 工具链中综合/布局布线后确认。

## 7. 下一步建议

- 在安路 TD 中把新增的 4 个文件（`xfd_ctrl.v`、`xfd_disp_pipe.v`、`xfd_line_fetch.v`、`xfd_top.v`）加入工程源文件列表后做综合。
- 上板验证：①不切图画面与改前一致；②切图有平滑淡入淡出、无黑屏；③字幕/时间戳/亮度/音频正常。
