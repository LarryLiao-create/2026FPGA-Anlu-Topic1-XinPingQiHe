# 时钟、复位与跨时钟域（CDC）策略 —— 图片切换淡入淡出转场

工程：med_screen（安路 EG4S20BG256B）
顶层：`src/user_source/hdl_source/top_tf_hdmi_audio.v`（module top）

## 1. 时钟域清单

| 时钟 | 频率 | 来源 | 主要负载 |
|---|---|---|---|
| `refclk` | 50 MHz | 板载晶振 → `clk` | 三个 PLL 的参考输入 |
| `sd_card_clk` | 100 MHz | `sys_pll` C0 | TF 卡 SPI、bmp_read、sd_card_bmp、写 FIFO 写侧 |
| `ext_mem_clk` | 125 MHz | `sys_pll` C1 | 嵌入式 SDRAM 用户接口、frame_fifo_read/write、**xfd_line_fetch（新）**、行缓存写端口 |
| `ext_mem_clk_sft` | 125 MHz (180°) | `sys_pll` C2 | SDRAM 控制器内部 |
| `video_clk` | 25 MHz | `video_pll` C0 | 视频时序、video_delay、**xfd_disp_pipe（新）**、**xfd_ctrl（新）**、行缓存读端口、brightness_ctrl、osd_overlay、HDMI 像素域 |
| `hdmi_5x_clk` | 125 MHz | `video_pll` C1 | TMDS 5x 串行 |
| `audio_mclk` | 12.288 MHz | `PLL_HDMI_AUDIO` | I2S 音频 |

`mem_clk : video_clk = 125 : 25 = 5 : 1`。这是本设计所有带宽/时序预算的基础比例。

## 2. 复位策略

- 唯一全局复位 `rst_all = ~rst_n | ~audio_pll_lock`，异步高有效。
- 现有各模块均以 `posedge clk or posedge rst` 异步复位到各自时钟域，未做独立复位同步器（沿用工程现状，不在本次改动范围）。
- 新增模块沿用同一约定：`rst` 为 `rst_all` 的异步高有效复位，在其自身时钟域内异步有效、同步释放（由 TD 的复位布线保证；如需严格同步释放，后续可在 `xfd_ctrl`/`xfd_line_fetch` 内各加一级同步器，不影响接口契约）。
- 新增逻辑不得产生“只在某个域复位、另一域不复位”的隐含依赖：所有新增寄存器的复位条件均为 `rst`。

## 3. 行缓存的结构性 CDC（关键）

两块行缓存（old/new）× 每块 2 页 = 4 个 `RAM_0` 实例，均为 Simple Dual Port 双时钟 BRAM：

- 端口 A（写）：`clka = ext_mem_clk`，由 `xfd_line_fetch` 驱动。
- 端口 B（读）：`clkb = video_clk`，由 `xfd_disp_pipe` 驱动。
- BRAM 本身完成数据跨域（写侧 125 MHz、读侧 25 MHz），这是**结构性 CDC**，不需要额外的数据同步器（真双口存储本身就是标准跨时钟域数据通道）。

**“写页/读页不冲突”证明（必须成立，否则会撕裂）：**

- 行缓存按“显示行号 y 的奇偶”分页：写侧写 `row[0]` 页，读侧读 `y[0]` 页。
- 取数引擎**领先一行**：在显示第 y 行的有效期内，取数引擎取的是第 y+1 行（写进页 (y+1)[0] = ~y[0]），而显示侧正在读页 y[0]。
- 因此任一瞬间：写页 = ~读页，物理上不可能同页读写。下一行 y+1 显示时，其数据已在本行有效期内取完并写入页 (y+1)[0]。
- 时序预算：单行取数 2×640 词 @125 MHz，按突发效率 60% 估算约 17 µs，小于 32 µs 行周期（800 像素 @25 MHz）；留有余量。

**为什么取数必须领先一行（不能用 de 下降沿触发）：** 若在某行有效结束后才去取下一行，则仅有 160 像素（6.4 µs）水平消隐时间可用，不足以完成 17 µs 的取数，下一行前半段会读到上一帧的残行。故触发点取**行起始（de 上升沿）**，把整个行有效期（32 µs）都留给取数。

## 4. 新增控制信号的 CDC 清单

| 信号 | 源域 | 目标域 | 宽度 | 同步方法 | 说明 |
|---|---|---|---|---|---|
| `disp_buf_idx` | sd_card_clk | video_clk | 2 | 每位 2-FF | 仅在帧边界（write_finish）变化，变化后稳定 ≥1 整帧；`xfd_ctrl` 内部同步并做边沿检测 |
| `xfd_en` | video_clk | ext_mem_clk | 1 | 2-FF | 电平信号，仅在帧边界变化；同步后驱动取数引擎与读端口仲裁 |
| `xfd_busy`（= `xfd_en`） | video_clk | sd_card_clk | 1 | 2-FF | 电平信号，仅在帧边界变化；送入 `sd_card_bmp` |
| `old_idx`, `new_idx` | video_clk | ext_mem_clk | 2 | 每位 2-FF | 与 `xfd_en` 同拍更新，稳定 ≥1 整帧；驱动帧缓冲基址选择 |
| `vs_tgl` | video_clk | ext_mem_clk | 1 | 2-FF + 边沿检测（toggle 同步） | 一帧一次翻转，脉冲间隔 ≥16.7 ms |
| `line_tgl` | video_clk | ext_mem_clk | 1 | 2-FF + 边沿检测（toggle 同步） | 一行一次翻转，脉冲间隔 ≈32 µs，远大于同步延迟（ns 级） |
| `App_rd_en/Addr` ② | ext_mem_clk | ext_mem_clk | - | 同域二选一 | 见第 5 节 |
| `Sdr_rd_en/Dout` | ext_mem_clk | video_clk | - | 经异步读 FIFO（既有） | 转场期间该通路被门控，不参与显示 |

> `vs_tgl`/`line_tgl` 采用“toggle + 边沿检测”而非电平：video 域的 vs/de 是 25 MHz 域的信号，直接用多位计数器跨域会有多比特亚稳态风险；toggle 是单比特、每帧/每行翻转一次，被采样的窗口极长（≥32 µs），2-FF 同步后可无歧义地还原出“发生了一次”的语义。这与工程既有的 `frame_write_toggle_mem` 用法完全一致。

## 5. SDRAM 读端口仲裁（同域，ext_mem_clk）

单读端口，两个请求方：

- `frame_fifo_read`（既有，整帧顺序读）
- `xfd_line_fetch`（新，逐行双取数）

仲裁规则（`ext_mem_clk` 域，纯组合二选一）：

```
App_rd_en   = xfd_en_mem ? xfd_App_rd_en   : fifo_App_rd_en;
App_rd_addr = xfd_en_mem ? xfd_App_rd_addr : fifo_App_rd_addr;
```

- 切换安全性：`xfd_en_mem` 的上升沿发生在帧边界附近，此刻 `frame_fifo_read` 已收到 `read_req=0`（由 `video_timing_data` 的 `xfd_en` 门控），处于 `S_IDLE`，未持有读突发；因此不会出现“突发中途换主”。下降沿同理发生在帧边界，`xfd_line_fetch` 已停止取数。
- 写端口不受影响：TF 写图通路只受 `sd_card_bmp` 的 `xfd_busy` 门控（禁止启动新任务），已在途的写任务仍可完成——但按第 6 节论证，转场期间不存在在途写任务。

## 6. 转场期间“无在途写任务”的论证

- `sd_card_bmp` 只在 `write_finish` 时更新 `disp_buf_idx`，而 `xfd_ctrl` 正是靠 `disp_buf_idx` 变化启动转场。因此**转场起点 = 某次写任务完成点**。
- 下一次写任务必须在转场结束后才能启动（`!xfd_busy`）。
- 故在 `[转场起点, 转场终点]` 区间内不存在任何写任务。这保证了 `old` 图缓冲（`BUF(disp^1)`）在整个转场期间不被覆盖。

## 7. 带宽与资源核算

- 转场期间读带宽：2×640×480 词/帧 ÷ 16.7 ms ≈ **36.9 M 词/s**，占 125 M 词/s 的 **29.5%**；写通路空闲。总线不紧张，**无需降帧率**。
- 转场期间像素域读带宽：每像素 2 次 BRAM 读（old、new 各一次），25 MHz 下 2 读/拍。两块 BRAM 端口 B 各 1 读/拍，满足。
- BRAM：4 × (1024×32 bit) = 4 × 32 Kbit = **4 个 32Kb 块**（共 16 个，余量充足）。
- DSP：混合用 3 个 8×9 乘法（可选 M18x18），29 个 DSP 中占用 ≤3。
- LUT/FF：预估新增 < 800 LUT / < 600 FF，相对 19600 的规模可忽略。

## 8. 转移/边界情形

| 情形 | 处理 |
|---|---|
| 上电首次加载 | `disp_buf_idx` 保持 0 不变，不触发转场；显示经既有读通路正常输出 |
| 上电后第一次切图 | `disp` 0→1，转场 old=BUF0（首图）、new=BUF1；正常淡入淡出 |
| 转场期间按“下一张” | 请求记入 `next_req_pending`，转场结束后执行，不丢按键 |
| 转场期间自动轮播计时 | `auto_cnt` 因 `load_busy`/`xfd_busy` 停走，不会与转场抢缓冲 |
| 只有 1 张图 | 不会切图，无转场 |
| 复位 | 所有新增寄存器异步复位：`xfd_en=0`、`alpha=0`、行号=0、页选择=0；`prevd` 在复位释放后首次采样不触发转场 |
| 行号越界 | 取数引擎行号 > 479 时丢弃触发，不越界读 |
