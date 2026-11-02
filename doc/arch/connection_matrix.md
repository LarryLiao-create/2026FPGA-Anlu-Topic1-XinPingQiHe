# 连接矩阵 —— 图片切换淡入淡出转场

工程：med_screen　顶层：`src/user_source/hdl_source/top_tf_hdmi_audio.v`

时钟域缩写：`VC`=video_clk(25M)、`MC`=ext_mem_clk(125M)、`SD`=sd_card_clk(100M)。

## 1. 转场链路（新增）

| # | 生产者 | 信号组 | 消费者 | 协议 | 域 | 延迟/背压 | 备注 |
|---|---|---|---|---|---|---|---|
| 1 | `sd_card_bmp` | `disp_buf_idx[1:0]` | `xfd_ctrl` | 电平 | SD→VC | 2-FF（每 bit） | 帧边界变化 |
| 2 | `video_timing_data` | `hs_0/vs_0/de_0` | `xfd_ctrl` | 同步/有效 | VC | 同域 | 转场启停与行/帧脉冲基准 |
| 3 | `xfd_ctrl` | `xfd_en` | `xfd_disp_pipe` | 电平 | VC | 同域 | 选择显示通路 |
| 3b | `xfd_ctrl` | `xfd_en` | `top` CDC → `xfd_line_fetch`/仲裁 | 电平 | VC→MC | 2-FF | 读端口所有权 |
| 3c | `xfd_ctrl` | `xfd_busy`(=xfd_en) | `top` CDC → `sd_card_bmp` | 电平 | VC→SD | 2-FF | 禁止新写图任务 |
| 4 | `xfd_ctrl` | `alpha[8:0]` | `xfd_disp_pipe` | 电平 | VC | 同域 | 每帧 +ALPHA_STEP |
| 5 | `xfd_ctrl` | `old_idx/new_idx` | `top`(基址映射) → `xfd_line_fetch` | 电平 | VC→MC | 2-FF | 帧边界变化，稳定≥1帧 |
| 6 | `xfd_ctrl` | `vs_tgl` | `xfd_line_fetch` | toggle | VC→MC | 2-FF+边沿 | 帧起始 |
| 7 | `xfd_ctrl` | `line_tgl` | `xfd_line_fetch` | toggle | VC→MC | 2-FF+边沿 | 行起始（de 上升沿） |
| 8 | `xfd_line_fetch` | `App_rd_en/App_rd_addr` | `top` 仲裁 | 握手/地址 | MC | 同域 | 仅 `xfd_en_mem=1` 时有效 |
| 9 | `sdram` | `Sdr_rd_en/Sdr_rd_dout[31:0]` | `xfd_line_fetch` | valid/data | MC | SDRAM 读延迟 | 转场期间由本引擎消费 |
| 10 | `xfd_line_fetch` | `wr_en_old/wr_en_new/wr_page/wr_addr/wr_data` | `RAM_0`×4 端口A | 写 | MC | 同域 1 拍 | 写页 = row[0] |
| 11 | `RAM_0`×4 | `dob[31:0]` | `top` 读 mux → `xfd_disp_pipe` | 数据 | VC | BRAM 读延迟 1 拍 | 按 `rd_page` 二选一 |
| 12 | `xfd_disp_pipe` | `rd_addr/rd_page` | `RAM_0`×4 端口B | 地址 | VC | 同域 | 读页 = 显示行号[0] |
| 13 | `xfd_disp_pipe` | `hs_out/vs_out/de_out/rgb_out` | `top` 二选一 → `brightness_ctrl` | 视频流 | VC | 对齐延迟 20 拍 | 与非转场通路同构 |

## 2. 非转场链路（既有，未改动，仅被门控）

| # | 生产者 | 信号组 | 消费者 | 协议 | 域 | 备注 |
|---|---|---|---|---|---|---|
| A | `video_timing_data` | `read_req` | `frame_fifo_read` | 握手（保持到 ack） | VC→MC | **改动**：每帧一次；`xfd_en` 时强制 0 |
| B | `frame_fifo_read` | `App_rd_en/App_rd_addr` | `top` 仲裁 → `sdram` | 握手/地址 | MC | `xfd_en_mem=0` 时有效 |
| C | `sdram` | `Sdr_rd_en/Sdr_rd_dout` | 读 FIFO（`rfifo_32_32_512`） | valid/data | MC | **改动**：`we = Sdr_rd_en & ~xfd_en_mem` |
| D | 读 FIFO | `read_data[31:0]` | `video_delay` | 流 | VC | 不变 |
| E | `video_delay` | `hs_r/vs_r/de_r/vout_data[23:0]` | `top` 二选一 | 视频流 | VC | 不变 |
| F | `top` 二选一 | `hs/vs/de/rgb` | `brightness_ctrl`→`osd_overlay`→`video_rgb_to_axis` | 视频流 | VC | 下游完全不变 |

## 3. 顶层二选一与仲裁（信号级）

```
// 读端口仲裁（MC 域）
assign App_rd_en   = xfd_en_mem ? xfd_App_rd_en   : fifo_App_rd_en;
assign App_rd_addr = xfd_en_mem ? xfd_App_rd_addr : fifo_App_rd_addr;

// 读 FIFO 写门控（MC 域）
assign fifo_we = Sdr_rd_en & ~xfd_en_mem;

// 行缓存读页二选一（VC 域）
assign old_dob = rd_page ? ram_old_p1_dob : ram_old_p0_dob;
assign new_dob = rd_page ? ram_new_p1_dob : ram_new_p0_dob;

// 显示流二选一（VC 域）
assign hs      = xfd_en_v ? xfd_hs : hs_r;
assign vs      = xfd_en_v ? xfd_vs : vs_r;
assign de      = xfd_en_v ? xfd_de : de_r;
assign vout_data_raw = xfd_en_v ? xfd_rgb : vout_data_fifo;
```

## 4. 基址映射（MC 域）

```
BUF0_ADDR = 21'd0
BUF1_ADDR = 21'd307200
BUF2_ADDR = 21'd614400          // 保留未用

old_base = (old_idx==2'd0) ? BUF0_ADDR : (old_idx==2'd1) ? BUF1_ADDR : BUF2_ADDR;
new_base = (new_idx==2'd0) ? BUF0_ADDR : (new_idx==2'd1) ? BUF1_ADDR : BUF2_ADDR;
```

## 5. 时序关系（一帧内）

```
行 y-1 有效期内 ── xfd_line_fetch 取 row y  ──→ 写 页(y[0])
行 y   有效期内 ── xfd_disp_pipe 读 页(y[0])  ──→ 混合输出
                 └ xfd_line_fetch 取 row y+1 ──→ 写 页((y+1)[0]) = 页(~y[0])   （无冲突）
vs 有效边沿 ──→ 显示行号清零、取数行号清零、alpha += ALPHA_STEP、Xfd 启停判定
```

## 6. 背压与流控

| 位置 | 背压机制 |
|---|---|
| SDRAM 读突发 | `frame_fifo_read` 用 `wrusedw < FIFO_DEPTH-BURST_SIZE` 门控；`xfd_line_fetch` 用“单行取完再等下一行触发”的固有节奏（每行预算 32 µs，实测取数 ~17 µs） |
| 读 FIFO | `frame_fifo_write`/`frame_fifo_read` 由 `App_rd_busy`/`App_wr_busy` 互斥（既有） |
| 行缓存 | 靠“写页/读页奇偶乒乓”结构性隔离，无需显式背压 |
| 写图任务 | `sd_card_bmp` 的 `load_busy` + 新增 `xfd_busy` 门控，串行化 |
