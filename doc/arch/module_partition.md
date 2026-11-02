# 模块划分 —— 图片切换淡入淡出转场

工程：med_screen（安路 EG4S20BG256B）　顶层：`top_tf_hdmi_audio.v`

## 1. 设计原则

1. **不破坏既有功能**：字幕（`osd_overlay`/`char_rom`）、时间戳、亮度（`brightness_ctrl`）、音频、TF 写图链路保持原样，改动只增加端口/门控。
2. **转场路径与非转场路径分离**：非转场期间沿用既有 `frame_read_write → 读FIFO → video_delay` 显示通路；转场期间启用全新的“逐行双取数 + 行缓存 + Alpha 混合”通路。两条通路在帧边界二选一。
3. **单时钟域模块**：每个新模块只在其所属时钟域内工作；跨域只通过明确的电平同步 / toggle 同步 / 双口 BRAM 完成。
4. **可综合、工具无关**：新增 RTL 均为纯 Verilog，不依赖 TD IP（除复用的 `RAM_0`），可在 iverilog 下做语法/编译检查。

## 2. 模块清单

### 2.1 新增模块

| 模块 | 文件 | 时钟域 | 职责 | 状态/存储 | 备注 |
|---|---|---|---|---|---|
| `xfd_line_fetch` | `src/user_source/hdl_source/xfd_line_fetch.v` | `ext_mem_clk` | 转场期间独占 SDRAM 读端口；按显示行号 y 依次取 `old_base+y*640` 与 `new_base+y*640` 各 640 词，边取边写两块行缓存 | 行号计数器、取数 FSM、地址计数器 | 领先显示一行；不持有缓冲 |
| `xfd_disp_pipe` | `src/user_source/hdl_source/xfd_disp_pipe.v` | `video_clk` | 按 de 计数像素 x，读行缓存，做 `out=(old*(256-a)+new*a)>>8` 混合；输出与 hs/vs/de 对齐的 rgb | 像素计数、行号计数、20 拍延时链 | 结构对齐既有 `video_delay` |
| `xfd_ctrl` | `src/user_source/hdl_source/xfd_ctrl.v` | `video_clk` | 同步 `disp_buf_idx`、检测变化、帧边界启停转场、alpha 斜坡、产生 `xfd_en`/`xfd_busy`/`old_idx`/`new_idx`/`vs_tgl`/`line_tgl` | prev_disp、alpha、pending | 唯一的转场决策点 |

### 2.2 修改模块

| 模块 | 文件 | 改动 | 原因 |
|---|---|---|---|
| `top` | `src/user_source/hdl_source/top_tf_hdmi_audio.v` | 例化 3 个新模块与 4 个 `RAM_0`；新增读端口仲裁、显示二选一、5 处 CDC 同步器；补齐 `ram_*` 信号声明 | 接线与仲裁 |
| `video_timing_data` | `src/user_source/hdl_source/SD/video_timing_data.v` | 新增 `xfd_en` 输入；`read_req` 改回“每帧一次”，并在 `xfd_en` 时强制清零 | 见 interface_contract 第 5 节 |
| `sd_card_bmp` | `src/user_source/hdl_source/SD/sd_card_bmp.v` | 新增 `xfd_busy` 输入；三处 load_start 追加 `&& !xfd_busy` | 防止转场期间覆盖旧图 |
| `frame_fifo_read` | `src/user_source/hdl_source/SD/frame_fifo_read.v` | 删除 `rd_toggle` 交替逻辑，地址选择回到 `read_addr_index_d1` | 消除隔行撕裂 |

### 2.3 复用（不改动）

| 模块/IP | 用途 |
|---|---|
| `RAM_0`（`src/td_project/al_ip/RAM_0.v`） | 行缓存，例化 4 次（old/new × 页0/页1） |
| `frame_read_write` / `rfifo_32_32_512` / `video_delay` | 非转场通路，保持原样 |
| `brightness_ctrl` / `osd_overlay` / `char_rom` | 转场输出接入其上游，功能不受影响 |
| `sdram`（嵌入式 SDRAM 控制器） | 读/写端口不变 |
| HDMI 1.4b 发射 / PHY / 音频链路 | 完全不动 |

## 3. 所有权边界

| 资源 | 拥有者 | 说明 |
|---|---|---|
| SDRAM 读端口（`App_rd_en/Addr`） | `top` 仲裁 → 二选一交给 `frame_fifo_read` 或 `xfd_line_fetch` | 二者不同时驱动 |
| SDRAM 写端口 | `frame_fifo_write`（既有） | 本次不改 |
| 行缓存 4 块 BRAM 的写端口 | `xfd_line_fetch` | 仅转场期间有效 |
| 行缓存 4 块 BRAM 的读端口 | `xfd_disp_pipe` | 仅转场期间被顶层选用 |
| 帧缓冲 0/1/2 的基址映射 | `top`（常量） | BUF2 保留未用 |
| 转场状态（alpha/xfd_en/prevd） | `xfd_ctrl` | 唯一写入者 |
| 缓冲 idx（disp/write） | `sd_card_bmp`（既有） | 本次仅加门控 |

## 4. 黑盒

| 黑盒 | 说明 |
|---|---|
| `EG_LOGIC_BRAM`（RAM_0 内部） | 安路原语，Simple Dual Port BRAM，不用改动 |
| `hdmi_1_4b_transmitter_core_wrapper` | 加密 IP（`.enc.v`），黑盒 |
| `EG_PHY_*` / `lane_lvds_10_1` | PHY 原语，黑盒 |
| `sys_pll` / `video_pll` / `PLL_HDMI_AUDIO` | PLL 包装，黑盒 |

## 5. 数据流总览

```
                       ┌──────────────── 非转场（xfd_en=0）───────────────┐
TF卡→sd_card_bmp→写FIFO→frame_fifo_write→ [SDRAM] →frame_fifo_read→读FIFO→video_delay→┐
                       └──────────────────────────────────────────────────────────────┘
                                                                                       ├─→ 二选一 → brightness_ctrl → osd_overlay → rgb2axis → HDMI
                       ┌──────────────── 转场（xfd_en=1）────────────────────────────┐   │
xfd_ctrl(alpha/idx/脉冲) → xfd_line_fetch → [SDRAM 读] → RAM_0 ×4(行缓存) → xfd_disp_pipe ─┘
```

- `xfd_ctrl` 同时向 `sd_card_bmp` 提供 `xfd_busy`（禁止新写图任务），向 `video_timing_data` 提供 `xfd_en`（门控 `read_req`）。
