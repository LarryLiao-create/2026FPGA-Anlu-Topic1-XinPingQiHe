# xfd_top 行为规格

## 需求概述

`xfd_top` 是图片切换淡入淡出转场子系统的顶层封装模块，集成以下功能：
- 跨时钟域信号同步（video/mem/sd 三域）
- SDRAM 读端口仲裁（转场取数 vs 既有整帧读）
- 4 块行缓存 BRAM 例化（旧图/新图各 2 块，奇偶行乒乓）
- 显示输出二选一（转场通路 vs 既有通路）

目标平台：安路 EG4S20BG256B，640x480@60 HDMI 图片轮播系统。

## 公共接口

| 端口名 | 方向 | 位宽 | 时钟域 | 说明 |
|--------|------|------|--------|------|
| `video_clk` | input | 1 | - | 25MHz 像素时钟 |
| `ext_mem_clk` | input | 1 | - | 125MHz SDRAM 控制器时钟 |
| `sd_card_clk` | input | 1 | - | 100MHz SD 卡时钟（本模块未直接使用） |
| `rst` | input | 1 | - | 高有效异步复位（顶层 rst_all） |
| `hs_0` | input | 1 | video | 行同步（来自 video_timing_data） |
| `vs_0` | input | 1 | video | 场同步（来自 video_timing_data） |
| `de_0` | input | 1 | video | 数据有效（来自 video_timing_data） |
| `disp_buf_idx` | input | 2 | sd | 当前显示图片索引（来自 sd_card_bmp） |
| `fifo_App_rd_en` | input | 1 | mem | 既有读请求使能（来自 frame_read_write） |
| `fifo_App_rd_addr` | input | ADDR_BITS | mem | 既有读地址 |
| `Sdr_rd_en` | input | 1 | mem | SDRAM 读数据有效脉冲 |
| `Sdr_rd_dout` | input | 32 | mem | SDRAM 读数据 |
| `hs_fifo` | input | 1 | video | 既有行同步（来自 video_delay） |
| `vs_fifo` | input | 1 | video | 既有场同步 |
| `de_fifo` | input | 1 | video | 既有数据有效 |
| `rgb_fifo` | input | 24 | video | 既有 RGB 像素 |
| `App_rd_en` | output | 1 | mem | 仲裁后读请求使能（→ sdram 控制器） |
| `App_rd_addr` | output | ADDR_BITS | mem | 仲裁后读地址 |
| `Sdr_rd_en_gated` | output | 1 | mem | 门控后读有效（→ frame_read_write） |
| `xfd_en` | output | 1 | video | 转场通路有效（→ video_timing_data） |
| `xfd_busy_sd` | output | 1 | sd | 转场忙（→ sd_card_bmp） |
| `hs` | output | 1 | video | 输出行同步 |
| `vs` | output | 1 | video | 输出场同步 |
| `de` | output | 1 | video | 输出数据有效 |
| `vout_data` | output | 24 | video | 输出 RGB 像素 |

## 参数与默认值

| 参数名 | 默认值 | 说明 |
|--------|--------|------|
| `ALPHA_STEP` | 4 | alpha 每帧增量，传递给 xfd_ctrl |
| `ADDR_BITS` | 21 | SDRAM 字地址位宽（2M 字 = 2^21） |
| `BUF0_ADDR` | 21'd0 | 帧缓冲 0 基址（字地址） |
| `BUF1_ADDR` | 21'd307200 | 帧缓冲 1 基址（640*480=307200） |
| `BUF2_ADDR` | 21'd614400 | 帧缓冲 2 基址（307200*2） |

## 时钟与复位

- **video_clk (25MHz)**：像素时钟，驱动 xfd_ctrl 和 xfd_disp_pipe
- **ext_mem_clk (125MHz)**：SDRAM 控制器时钟，驱动 xfd_line_fetch 和 BRAM 写端口
- **sd_card_clk (100MHz)**：SD 卡时钟，仅用于 xfd_busy 同步输出
- **rst**：高有效异步复位，所有寄存器统一使用 `posedge rst` 异步复位

跨时钟域同步策略：
- 所有跨域信号使用 2 级触发器同步（`xfd_cdc2` 模块）
- 多 bit 信号（如 `old_idx`/`new_idx`）逐 bit 独立例化同步器，避免位间 skew
- 同步延迟：2 拍目标时钟（约 16ns@125MHz 或 80ns@25MHz）

## 功能行为

### 1. 跨时钟域同步

**video → mem 域**（供 xfd_line_fetch 使用）：
- `xfd_en_v` → `xfd_en_mem`：转场使能
- `xfd_old_idx[1:0]` → `old_idx_mem[1:0]`：旧图索引（逐 bit 同步）
- `xfd_new_idx[1:0]` → `new_idx_mem[1:0]`：新图索引（逐 bit 同步）
- `xfd_vs_tgl` → `vs_tgl_m`：帧起始 toggle
- `xfd_line_tgl` → `line_tgl_m`：行起始 toggle

**video → sd 域**（供 sd_card_bmp 使用）：
- `xfd_busy_v` → `xfd_busy_sd`：转场忙标志

### 2. 帧缓冲基址映射（组合逻辑，mem 域）

```verilog
old_base = (old_idx_mem == 2'd0) ? BUF0_ADDR :
           (old_idx_mem == 2'd1) ? BUF1_ADDR : BUF2_ADDR;

new_base = (new_idx_mem == 2'd0) ? BUF0_ADDR :
           (new_idx_mem == 2'd1) ? BUF1_ADDR : BUF2_ADDR;
```

### 3. SDRAM 读端口仲裁（组合逻辑，mem 域）

```verilog
App_rd_en   = xfd_en_mem ? xfd_fetch_rd_en   : fifo_App_rd_en;
App_rd_addr = xfd_en_mem ? xfd_fetch_rd_addr : fifo_App_rd_addr;
```

- `xfd_en_mem=1`：取数引擎独占 SDRAM 读端口
- `xfd_en_mem=0`：既有整帧读通路使用 SDRAM 读端口
- **安全保证**：`xfd_en` 的上升/下降沿严格发生在帧边界（见 xfd_ctrl 设计），不会在画面中途切换，避免仲裁毛刺

### 4. 读 FIFO 写使能门控（组合逻辑，mem 域）

```verilog
Sdr_rd_en_gated = Sdr_rd_en & ~xfd_en_mem;
```

- 转场期间（`xfd_en_mem=1`）屏蔽 `Sdr_rd_en`，防止取数引擎数据混入既有读 FIFO
- 非转场期间（`xfd_en_mem=0`）直通 `Sdr_rd_en`

### 5. 行缓存 BRAM 读写控制

**写端口（mem 域）**：
- 4 块 RAM_0：旧图 page0/page1、新图 page0/page1
- 写使能逻辑：
  - `u_ram_old_p0.cea = wr_en_old & ~wr_page`（旧图偶数行）
  - `u_ram_old_p1.cea = wr_en_old &  wr_page`（旧图奇数行）
  - `u_ram_new_p0.cea = wr_en_new & ~wr_page`（新图偶数行）
  - `u_ram_new_p1.cea = wr_en_new &  wr_page`（新图奇数行）
- 写地址/数据：来自 xfd_line_fetch 的 `wr_addr`/`wr_data`

**读端口（video 域）**：
- 4 块 RAM_0 统一使用 `rd_addr`（来自 xfd_disp_pipe 的像素计数器）
- 读页二选一（组合逻辑）：
  ```verilog
  old_dob = rd_page ? old_p1_dob : old_p0_dob;
  new_dob = rd_page ? new_p1_dob : new_p0_dob;
  ```
- `rd_page` 来自 xfd_disp_pipe，每行翻转（奇偶行乒乓）

### 6. 显示输出二选一（组合逻辑，video 域）

```verilog
hs        = xfd_en_v ? xfd_hs  : hs_fifo;
vs        = xfd_en_v ? xfd_vs  : vs_fifo;
de        = xfd_en_v ? xfd_de  : de_fifo;
vout_data = xfd_en_v ? xfd_rgb : rgb_fifo;
```

- `xfd_en_v=1`：输出转场通路（xfd_disp_pipe 混合后像素）
- `xfd_en_v=0`：输出既有通路（video_delay 直通像素）
- **安全保证**：`xfd_en_v` 的上升/下降沿严格发生在帧边界，不会在画面中途切换

## 时序、延迟与吞吐

### 跨时钟域同步延迟
- 2 拍目标时钟：video→mem 约 16ns@125MHz，video→sd 约 20ns@100MHz
- 对系统影响：`xfd_en` 从 video 域到 mem 域有 2 拍延迟，但因切换仅在帧边界发生，不影响功能正确性

### SDRAM 仲裁延迟
- 组合逻辑，0 拍延迟
- 仲裁切换仅在帧边界发生，无毛刺风险

### 行缓存读写延迟
- RAM_0 读延迟：1 拍（BRAM 固有延迟）
- 读写时钟异步：写端口 ext_mem_clk (125MHz)，读端口 video_clk (25MHz)
- 乒乓机制保证：写 page0 时读 page1，无冲突

### 吞吐
- SDRAM 读端口：125MHz × 32bit = 4Gbps
- 转场取数：每行 1280 字 × 125MHz = 约 10.24us/行（含 burst drain 间隔）
- 一帧 480 行：约 4.9ms/帧，远小于帧周期 16.67ms@60Hz

## 假设与默认选择

1. **帧缓冲布局**：3 个帧缓冲（BUF0/BUF1/BUF2），每个 640×480×32bit = 307200 字
   - 若实际布局不同，修改 `BUF0_ADDR`/`BUF1_ADDR`/`BUF2_ADDR` 参数即可

2. **disp_buf_idx 来源**：来自 sd_card_bmp 模块，表示当前显示图片索引（0/1/2）
   - 若索引编码不同（如 1/2/3），需在上游调整或本模块增加映射逻辑

3. **xfd_en 切换时机**：严格在帧边界（vs_in 上升沿），由 xfd_ctrl 保证
   - 若 xfd_ctrl 设计变更，需重新验证仲裁/显示二选一的无毛刺特性

4. **RAM_0 IP 原语**：安路 TD 原语，Simple Dual Port BRAM
   - 端口 A 写（wea 固定 1），端口 B 读（ceb 固定 1）
   - 若更换平台，需替换为对应 BRAM 原语或推断式 BRAM

5. **sd_card_clk 未使用**：本模块仅用于 `xfd_busy_sd` 同步输出
   - 若后续需要 sd 域逻辑（如状态机），需重新评估时钟域交互

## 边界情况与错误处理

1. **disp_buf_idx 变化过快**：若两次变化间隔小于一帧，xfd_ctrl 内部会排队处理，不会丢失
2. **xfd_en 同步延迟**：video→mem 有 2 拍延迟，但因切换仅在帧边界，不影响功能
3. **BRAM 读写冲突**：乒乓机制保证同一时刻读写不同页，无冲突
4. **SDRAM 仲裁竞争**：`xfd_en_mem` 仅在帧边界切换，避免中途仲裁毛刺
5. **复位后首帧**：xfd_ctrl 在首帧不会触发转场（`disp_sync == prev_disp == 0`），显示既有通路

## 综合注意事项

1. **跨时钟域信号必须显式同步**：所有 video↔mem↔sd 域信号已使用 `xfd_cdc2` 同步
2. **BRAM 推断**：RAM_0 为 TD 原语，综合工具会直接例化，不会推断为逻辑
3. **组合逻辑环路**：无（所有反馈路径均经过寄存器）
4. **多驱动**：无（每个信号仅由一个 always 块或 assign 驱动）
5. **锁存器**：无（所有组合逻辑路径完整赋值）

## 验证计划

### 基本功能测试
1. **非转场模式**：`disp_buf_idx` 保持不变，验证输出直通 `hs_fifo`/`vs_fifo`/`de_fifo`/`rgb_fifo`
2. **单次转场**：改变 `disp_buf_idx`，验证：
   - `xfd_en` 在帧边界上升
   - `alpha` 从 0 递增到 256
   - `xfd_en` 在 alpha=256 时下降
   - 输出像素按 alpha 混合新旧图

### 跨时钟域同步测试
1. 验证 `xfd_en_v` → `xfd_en_mem` 延迟 2 拍 ext_mem_clk
2. 验证 `xfd_busy_v` → `xfd_busy_sd` 延迟 2 拍 sd_card_clk
3. 验证 `old_idx`/`new_idx` 逐 bit 同步，无位间 skew

### SDRAM 仲裁测试
1. `xfd_en_mem=0` 时，验证 `App_rd_en = fifo_App_rd_en`
2. `xfd_en_mem=1` 时，验证 `App_rd_en = xfd_fetch_rd_en`
3. 验证 `Sdr_rd_en_gated` 在转场期间为 0

### 行缓存 BRAM 测试
1. 验证写使能逻辑：`wr_en_old & ~wr_page` 等
2. 验证读页二选一：`rd_page` 切换时输出对应页数据
3. 验证乒乓机制：写 page0 时读 page1，无冲突

### 显示二选一测试
1. `xfd_en_v=0` 时，验证输出 = 既有通路
2. `xfd_en_v=1` 时，验证输出 = 转场通路
3. 验证切换仅在帧边界发生，无画面中途毛刺

## 验收标准

- [ ] 所有端口按规格连接，无悬空/未驱动信号
- [ ] 跨时钟域信号全部使用 2FF 同步，无亚稳态风险
- [ ] SDRAM 仲裁无毛刺，切换仅在帧边界
- [ ] 行缓存 BRAM 读写无冲突，乒乓机制正确
- [ ] 显示二选一输出干净，切换仅在帧边界
- [ ] 综合后无锁存器、无多驱动、无组合环路
- [ ] 时序满足：video_clk 25MHz、ext_mem_clk 125MHz、sd_card_clk 100MHz
