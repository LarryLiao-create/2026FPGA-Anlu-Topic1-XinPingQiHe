# char_rom Behavior Specification

## Requirement Summary

16x16 中文点阵字库 ROM 模块，为 osd_overlay 滚动字幕提供字形行数据。组合读出（无时钟、无额外延迟），地址变化即输出对应行数据。纯 Verilog 内联数据，不依赖任何 TD IP / .mif / 外部文件。

## Public Interface

| Port      | Direction | Width    | Active | Description                                      |
|-----------|-----------|----------|--------|--------------------------------------------------|
| `addr`    | input     | ADDR_W=9 | -      | 寻址地址，`{char_idx[4:0], row[3:0]}`，范围 0..335 |
| `row_data`| output    | CELL=16  | -      | 16bit 一行点阵，bit15=最左列，bit0=最右列          |

## Parameters and Defaults

| Parameter | Default | Description                                     |
|-----------|---------|-------------------------------------------------|
| `NCHAR`   | 21      | 字幕字符格数量（重复字符不去重）                  |
| `CELL`    | 16      | 每行点阵位宽（16 像素列）                        |
| `ADDR_W`  | 9       | 地址位宽，$clog2(21*16) = $clog2(336) = 9       |

## Clocking and Reset

无时钟、无复位信号。纯组合逻辑（`always @(*)`），地址输入变化后经过组合延迟即输出对应行数据。

## Functional Behavior

### 寻址格式

- `addr = {char_idx[4:0], row[3:0]}`，即 `addr = char_idx * 16 + row`。
- `char_idx`：字符在字幕中的顺序位置 0..20。
- `row`：字形内行号 0..15（0 = 最上一行）。

### 字幕文本与字符映射

```
char_idx:  0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20
字符:      温 馨 提 示  ： 请 保 持 安 静  ， 有 序 就 诊  ， 谢 谢 配 合  。
addr范围:  0  16 32 48 64 80 96 112 128 144 160 176 192 208 224 240 256 272 288 304 320
```

### 位序约定

- `row_data[15]` = 字符格最左列（local x=0）
- `row_data[0]`  = 字符格最右列（local x=15）
- 行内某列 x 的墨点为 `row_data[15-x]`

### 组合读出

- `always @(*)` 内 `case(addr)` 逐条列出 336 个分支（0..335）。
- `default` 分支输出 `16'h0000`（空白行）。
- 不使用 `$readmemh`、`initial` 块或外部文件。

## Timing, Latency, and Throughput

- 纯组合延迟：地址变化到输出稳定，延迟为组合逻辑门延迟（无时钟拍数）。
- 无吞吐限制：每个时钟周期可独立寻址任意地址。

## Assumptions and Chosen Defaults

1. **字形数据来源**：字形数据由用户提供的 osd.TXT（纵向取模，每字 32 字节）经转置为行取模后内联，见 font21_21x16_rowmajor.hex。
2. **重复字符处理**：21 个字符格按位置顺序存储 21 组字形（如"谢谢"两字分别存储、两个"，"分别存储），寻址时不做去重。
3. **字形对齐**：16x16 点阵，字形于字符格左上角对齐；个别字的固有侧边距不额外居中。
4. **全角标点**：`：`（char[4]）、`，`（char[10]、char[15]）和 `。`（char[20]）为全角标点，各占一个 16px 字符格。

## Edge Cases and Error Handling

- **地址越界**：`addr >= 336` 时命中 `default` 分支，输出 `16'h0000`（空白行），不产生 X/Z 态。
- **地址位宽不足**：`ADDR_W=9` 最大寻址 0..511，超出 335 的地址仍命中 default 空白。

## Synthesis Notes

- 综合器会将 336 路 case 优化为 ROM 或 LUT 阵列（具体实现取决于综合器策略）。
- 纯 Verilog 内联数据，不依赖 TD IP / .mif / .dath / 外部文件，保证 iverilog 与 TD 都能综合。
- 无 `$readmemh`、`initial` 块，避免工具链路径差异。
- 336 entries x 16 bits = 5376 bits of ROM。

## Verification Plan

1. **地址回读**：对 addr=0..335 逐一读取，与 `font21_21x16_rowmajor.hex` 逐行比对，确认 336 个值完全一致。
2. **越界测试**：对 addr=336..511 读取，确认全部输出 `16'h0000`。
3. **字形预览**：将 row_data 按位序展开为 ASCII 点阵，逐字人工核对字形一致。
4. **集成测试**：在 osd_overlay 中例化 char_rom，确认字幕带内 21 个字符格按序水平排列、总宽 336 像素。

## Acceptance Criteria

1. 组合读出：地址变化到输出稳定，无时钟拍数延迟。
2. 336 条分支齐全：addr=0..335 均有对应 case 分支，无遗漏、无省略、无占位。
3. 端口名、参数名、位序与规格一致：`addr`（9bit）、`row_data`（16bit）、bit15=最左列。
4. 可综合：iverilog 编译通过，TD 综合通过，无仿真专用构造出现在综合路径。
5. 字形正确：21 个字符格的 16x16 点阵与 font21_21x16_rowmajor.hex 一致。

---

# osd_overlay Behavior Specification

## Requirement Summary

HDMI 视频底部整行宽滚动字幕叠加器。在视频帧底部（第 450~465 行）叠加一条浅蓝底黑字的水平滚动字幕，从右向左滚动，每帧移动 1 像素，连续循环。非字幕区像素透传原始 RGB。视频规格：640x480@60，像素时钟 25MHz，HS/VS 低有效。

## Public Interface

| Port       | Direction | Width | Active | Description                                      |
|------------|-----------|-------|--------|--------------------------------------------------|
| `clk`      | input     | 1     | 上升沿 | 像素时钟 25MHz                                   |
| `rst`      | input     | 1     | 高有效 | 复位信号                                         |
| `hs`       | input     | 1     | HS_POL | 行同步（极性由参数 HS_POL 决定）                 |
| `vs`       | input     | 1     | VS_POL | 场同步（极性由参数 VS_POL 决定）                 |
| `de`       | input     | 1     | 高有效 | 数据有效信号                                     |
| `rgb_in`   | input     | 24    | -      | 原始像素 RGB888                                  |
| `rgb_out`  | output reg| 24    | -      | 叠加后像素（output reg，组合逻辑赋值）           |

## Parameters and Defaults

| Parameter   | Default      | Description                                      |
|-------------|--------------|--------------------------------------------------|
| `H_ACTIVE`  | 640          | 一行有效像素数                                   |
| `V_ACTIVE`  | 480          | 一帧有效行数                                     |
| `BAND_TOP`  | 450          | 字幕带首行（含）                                 |
| `BAND_BOTTOM`| 465         | 字幕带末行（含），共 16 行                       |
| `TEXT_W`    | 320          | 字幕点阵总宽 = 20 字 * 16                        |
| `NCHAR`     | 20           | 字符格数                                         |
| `CELL`      | 16           | 字高/字宽（16x16 点阵）                          |
| `SCROLL_SPAN`| 960         | = H_ACTIVE + TEXT_W，滚动回绕周期                |
| `HS_POL`    | 1'b0         | 行同步极性：0=低有效                             |
| `VS_POL`    | 1'b0         | 场同步极性：0=低有效                             |
| `TEXT_COLOR`| 24'h000000   | 文字颜色（黑色）                                 |
| `BG_COLOR`  | 24'hADD8E6   | 底色（浅蓝）                                     |

## Clocking and Reset

- **时钟**：25MHz 像素时钟，所有寄存器在 `clk` 上升沿更新。
- **复位**：异步高有效复位 `rst`。复位时：
  - `x_cnt <= 0`
  - `y_cnt <= 0`
  - `de_d <= 0`
  - `vs_d <= 0`
  - `scroll_offset <= 0`

## Functional Behavior

### 1. 同步信号极性归一化

```verilog
wire hs_active = HS_POL ? hs : ~hs;   // 行同步有效（高有效统一）
wire vs_active = VS_POL ? vs : ~vs;   // 场同步有效（高有效统一）
```

### 2. 像素坐标计数（与 de 对齐，不引入额外流水延迟）

#### x_cnt：有效像素列号 0..H_ACTIVE-1

- **规则**：`de=1` 时 `x_cnt <= x_cnt+1`；`de=0` 时 `x_cnt <= 0`。
- **语义**：每个 de 有效行的第一个像素处 `x_cnt=0`，与 `rgb_in` 同拍对齐。
- **位宽**：`[9:0]`（容纳 0..639）。

#### y_cnt：有效行号 0..V_ACTIVE-1

- **de 打一拍**：`de_d` 为 `de` 打一拍，用于检测 de 下降沿。
- **de 下降沿**：`de_fall = de_d & ~de`，表示一行有效像素结束。
- **规则**：
  - `vs_active` 为真时 `y_cnt <= 0`（场消隐期强制复位，双保险）。
  - `de_fall` 时：若 `y_cnt == V_ACTIVE-1` 则 `y_cnt <= 0`（一帧结束回绕），否则 `y_cnt <= y_cnt+1`。
- **位宽**：`[9:0]`（容纳 0..479）。

### 3. 滚动偏移 scroll_offset（每帧 +1 像素，右→左滚动）

- **帧脉冲检测**：`vs_d` 为 `vs_active` 打一拍；`frame_pulse = vs_active & ~vs_d`（vs 上升沿，新帧开始）。
- **滚动偏移更新**：
  - 复位时 `scroll_offset <= 0`。
  - 每个 `frame_pulse`：`scroll_offset <= (scroll_offset == SCROLL_SPAN-1) ? 0 : scroll_offset+1`。
- **位宽**：`[9:0]`（容纳 0..959）。
- **语义**：滚动方向为文字右→左，每帧 1 像素；`scroll_offset=0` 时文字整体在屏幕右侧之外，随 `scroll_offset` 增大向左移动；到 `SCROLL_SPAN-1` 后回绕。

### 4. 字幕带判定

```verilog
wire in_band = de && (y_cnt >= BAND_TOP) && (y_cnt <= BAND_BOTTOM);
```

- **语义**：当前像素位于字幕带行范围内（de 有效且 y_cnt 在 [450, 465]）。

### 5. 文字窗口（右→左滚动的映射）

```verilog
wire [11:0] v_off = {2'b0, x_cnt} + {2'b0, scroll_offset};  // 0..1598
wire in_text = (v_off >= H_ACTIVE) && (v_off < H_ACTIVE + TEXT_W);
wire [11:0] v = v_off - H_ACTIVE;                           // in_text 时 0..319
wire [4:0]  ch_idx = v[8:4];                                // 字符序号 0..19
wire [9:0]  row_in_band = y_cnt - BAND_TOP;
wire [3:0]  glyph_row = row_in_band[3:0];                   // 字形内行号 0..15
wire [8:0]  rom_addr = {ch_idx, glyph_row};                 // = ch_idx*16+glyph_row
wire [3:0]  col = v[3:0];                                   // 字形内列号 0..15
```

- **v_off**：虚拟偏移 = x_cnt + scroll_offset，范围 0..(639+959)=1598。
- **in_text**：当前像素落在文字点阵窗口内（v_off 在 [640, 959]）。
- **v**：文字窗口内的局部坐标 0..TEXT_W-1（即 0..319）。
- **ch_idx**：字符序号 0..19（v / 16 的高位）。
- **glyph_row**：字形内行号 0..15（y_cnt 相对字幕带顶部的偏移）。
  - **注意**：必须先做完整位宽减法再截取低 4 位，不能仅取低 4 位相减。
- **rom_addr**：字库寻址 = ch_idx * 16 + glyph_row。
- **col**：字形内列号 0..15。

### 6. 字库例化（例化 char_rom，不内联字模逻辑）

```verilog
wire [15:0] rom_row;
wire dot = rom_row[CELL - 1 - col];  // = rom_row[15-col]

char_rom #(
    .NCHAR (NCHAR),
    .CELL  (CELL)
) u_char_rom (
    .addr     (rom_addr),
    .row_data (rom_row)
);
```

- **char_rom 位序**：`row_data[15]` = 字符格最左列（local x=0），`row_data[0]` = 最右列。
- **当前像素墨点**：`dot = rom_row[15-col]`（col=0 时取 bit15，col=15 时取 bit0）。

### 7. 输出选择（组合逻辑，不引入额外流水延迟）

```verilog
always @(*) begin
    if (in_band) begin
        if (in_text && dot)
            rgb_out = TEXT_COLOR;    // 文字墨点：黑色
        else
            rgb_out = BG_COLOR;      // 底色：浅蓝（整行宽）
    end else begin
        rgb_out = rgb_in;            // 非字幕区：透传原始像素
    end
end
```

- **字幕带内**：文字墨点处输出 `TEXT_COLOR`（黑），其余输出 `BG_COLOR`（浅蓝底）。
  - **整行宽蓝底**：非文字窗口处同样为浅蓝底色。
- **字幕带外**：透传原始像素 `rgb_in`。
- **实现**：`rgb_out` 为 `output reg`，在 `always @(*)` 组合逻辑块中赋值，不引入额外流水延迟。

## Timing, Latency, and Throughput

- **像素对齐**：与 `hs/vs/de/rgb_in` 同域组合逻辑，不插入额外流水延时；`rgb_out` 与 `rgb_in` 同拍输出。
- **滚动速度**：每帧（每个 vs 上升沿）`scroll_offset` +1，文字 1 像素/帧 右→左移动。
- **回绕周期**：`SCROLL_SPAN = 960` 帧后回绕（文字尾部离开左侧后从右侧重新进入）。
- **吞吐**：每个时钟周期处理 1 个像素，25MHz 时钟下满足 640x480@60 的像素吞吐（25M pixels/sec）。

## Assumptions and Chosen Defaults

1. **滚动行程**：默认 `SCROLL_SPAN = H_ACTIVE + TEXT_W = 640 + 320 = 960`，即文字尾部离开左侧后从右侧重新进入的连续循环。
2. **每帧时机**：默认在 `vs` 上升沿（进入新帧）执行 `scroll_offset <= scroll_offset + 1`（模 `SCROLL_SPAN`）。
3. **整行宽蓝条**：第 450~465 行**始终**输出蓝底（文字未覆盖处为浅蓝），已由用户确认；文字窗口外同样为蓝底。
4. **像素对齐**：与 `hs/vs/de/rgb_in` 同域组合逻辑，不插入额外流水延时；若接入 top 后差 1~2 拍，后续加可选打拍参数。
5. **计数口径**：
   - `x_cnt`：de 有效内递增，de=0 时清零；每个 de 有效行的第一个像素处 `x_cnt=0`。
   - `y_cnt`：de 下降沿递增，vs_active 时强制清零；场消隐期复位为双保险。
6. **字形对齐**：simsun 16ppem 点阵，字形于字符格左上角对齐；个别字的固有侧边距不额外居中。
7. **重复字符**：按 **20 个位置顺序存 20 组字形**（允许重复），寻址 = `{位置[4:0], 行[3:0]}`，不做去重。
8. **hs 端口**：端口保留，可用于 x 计数辅助复位（HS_POL=0 时低有效，即 `hs_active = HS_POL ? hs : ~hs`，在 hs_active 时清 x_cnt），也可不用。当前实现未使用 hs 辅助复位（de=0 已经覆盖消隐区），但保留端口以兼容其他设计。
9. **字幕文本**：固定为"温馨提示：请保持安静，有序就诊，谢谢配合"（20 个 16x16 字符格），由 `char_rom` 提供字形数据。

## Edge Cases and Error Handling

- **复位后首帧**：`scroll_offset=0`，文字整体在屏幕右侧之外（v_off 范围 0..639，in_text 为假），字幕带为纯蓝底。
- **滚动边界**：`scroll_offset=959` 时文字最左侧刚好离开屏幕左边界；下一帧回绕到 `scroll_offset=0`，文字从右侧重新进入，无跳变。
- **字幕带外**：`y_cnt < BAND_TOP` 或 `y_cnt > BAND_BOTTOM` 时，`in_band=0`，`rgb_out = rgb_in` 透传。
- **de=0 时**：`in_band=0`，`rgb_out = rgb_in`（消隐区透传，通常为黑色）。
- **字形数据缺失**：`char_rom` 的 `default` 分支输出 `16'h0000`（空白行），不会产生 X/Z 态。
- **参数越界**：若 `BAND_TOP >= V_ACTIVE` 或 `BAND_BOTTOM >= V_ACTIVE`，`in_band` 恒为 0，字幕不显示，不影响视频输出。

## Synthesis Notes

- **纯可综合 Verilog-2001**：不依赖 TD IP、不依赖外部文件、不用 `initial` 块做逻辑。
- **字库例化**：`char_rom` 为纯 Verilog 内联数据 ROM，综合器会将其优化为 LUT 或 Block RAM（取决于综合器策略）。
- **组合逻辑输出**：`rgb_out` 为 `output reg`，在 `always @(*)` 中赋值，综合后为组合逻辑，不引入触发器延迟。
- **位宽一致性**：所有加法/减法使用显式位宽，避免隐式扩展或截断。
- **极性参数化**：`HS_POL` 和 `VS_POL` 为编译期常量，综合时会优化为反相器或直连。
- **工具兼容**：iverilog 与 TD 6.2 均可综合，无 `$readmemh`、`initial` 块或仿真专用构造。

## Verification Plan

1. **像素对齐测试**：在 de 有效的第一个像素处，确认 `x_cnt=0` 且 `rgb_out` 与 `rgb_in` 同拍。
2. **字幕带位置**：在 `y_cnt=450..465` 且 `de=1` 时，确认 `in_band=1`；其他行 `in_band=0`。
3. **整行宽蓝底**：在字幕带内，无论 `in_text` 为真或假，`rgb_out` 均为 `BG_COLOR`（浅蓝）或 `TEXT_COLOR`（黑）。
4. **文字显示**：在 `in_text && dot` 时，`rgb_out = TEXT_COLOR`；在 `in_text && !dot` 时，`rgb_out = BG_COLOR`。
5. **滚动速度**：每个 vs 上升沿，`scroll_offset` 恰好 +1；文字 1 像素/帧 右→左移动。
6. **回绕测试**：`scroll_offset=959` 后下一帧回绕到 0，文字从右侧重新进入，无跳变。
7. **透传测试**：在字幕带外，`rgb_out == rgb_in`（逐像素比对）。
8. **字形正确性**：20 个字符格按序水平排列，总宽 320 像素；每字形与 `char_rom` 的 ASCII 预览一致。
9. **复位测试**：复位后 `scroll_offset=0`、`x_cnt=0`、`y_cnt=0`，字幕带为纯蓝底。
10. **集成测试**：接入 `top_tf_hdmi_audio.v` 视频通路后，板上目视确认蓝条位于底部、文字右→左匀速滚动、字迹清晰。

## Acceptance Criteria

1. **透传**：非字幕带像素（`y_cnt∉[450,465]` 或 `de=0`）时 `rgb_out == rgb_in`。
2. **字幕带显示**：字幕带且 `de=1` 时：点阵 `=1` 处输出 `24'h000000`（黑），`=0` 处输出 `24'hADD8E6`（浅蓝）；整行宽（x=0..639）均为蓝底或黑字。
3. **滚动速度**：每帧 `scroll_offset` 恰好 +1；文字 1 像素/帧 右→左移动；到 `SCROLL_SPAN` 回绕，无跳变。
4. **字符排列**：20 个字符格按序水平排列，总宽 320 像素；每字形与 `char_rom` 的 ASCII 预览一致。
5. **字库接口**：`char_rom` 以 `{位置[4:0], 行[3:0]}` 寻址输出 16bit 行点阵；20 个位置均能回读正确行数据。
6. **端口/参数一致性**：端口名、参数名、位宽、位序与规格一致；`rgb_out` 为 `output reg`。
7. **可综合性**：模块可综合、可被 iverilog 编译通过，无仿真专用构造出现在综合路径。
8. **无占位/省略**：RTL 源码中无 `// ...`、`TODO`、`FIXME`、`TBD`、省略/占位写法。

---

# hdmi_audio_tone_i2s_64fs Behavior Specification

## Requirement Summary

I2S 音频发送模块，具备背景测试音循环播放和叫号提示音抢占功能。背景音为 8 音符（C4~C5 do/re/mi/fa/so/la/si/do）方波循环，每音持续 0.5s。当 `trigger_beep` 上升沿到来时，模块立即在下一个 48kHz 帧边界切换到"叮-咚"提示音（880Hz + 440Hz），持续 0.45s 后自动恢复背景音。I2S 发送时序与原有 64fs 接收端兼容。

## Public Interface

| Port Name | Direction | Width | Active Level | Description |
|-----------|-----------|-------|--------------|-------------|
| I_mclk | input | 1 | - | 主时钟 12.288MHz，所有逻辑在此时钟域运行 |
| I_rst | input | 1 | 高有效 | 异步复位，高电平时复位所有寄存器 |
| trigger_beep | input | 1 | 上升沿有效 | 叫号触发信号，上升沿触发提示音播放 |
| O_i2s_BCLK | output reg | 1 | - | I2S 位时钟，频率 12.288MHz / 2 = 6.144MHz，每 mclk 翻转 |
| O_i2s_LRCK | output reg | 1 | 0=左声道, 1=右声道 | I2S 左右声道选择，周期 64 BCLK，左右各 32 bit |
| O_i2s_DOUT | output reg | 1 | - | I2S 串行音频数据输出，MSB first，取 S_shift_reg[63] |

## Parameters and Defaults

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| PHASE_INC | [31:0] | 32'd39370534 | 兼容旧顶层，实际未使用（保留接口） |
| AMP | signed [23:0] | 24'sd2000000 | 背景测试音方波幅度 |
| NOTE_HOLD_FRAMES | integer | 24000 | 每个背景音持续帧数（0.5s @ 48kHz） |
| BEEP_AMP | signed [23:0] | 24'sd2000000 | 提示音方波幅度，默认与 AMP 相同 |

内部常量（localparam）：
- `ST_IDLE = 2'd0`：空闲状态，输出背景音
- `ST_BEEP_DING = 2'd1`：输出 880Hz "叮"音
- `ST_BEEP_DONG = 2'd2`：输出 440Hz "咚"音
- `DING_PHASE_INC = 32'd78741068`：880Hz 相位增量 @ 48kHz，计算公式 `round(880 * 2^32 / 48000)`
- `DONG_PHASE_INC = 32'd39370534`：440Hz 相位增量 @ 48kHz，计算公式 `round(440 * 2^32 / 48000)`
- `DING_FRAMES = 14'd7200`：880Hz 持续 0.15s @ 48kHz
- `DONG_FRAMES = 14'd14400`：440Hz 持续 0.3s @ 48kHz

## Clocking and Reset

- **时钟域**：所有逻辑均在 I_mclk (12.288MHz) 时钟域运行，无跨时钟域信号。
- **复位策略**：高有效异步复位（`posedge I_rst`），所有寄存器在复位时初始化为 0（S_sample_next 例外，复位为 AMP）。
- **trigger_beep 同步**：`trigger_beep` 输入经过 2 级 FF 同步（带 `(* ASYNC_REG = "TRUE" *)` 属性），消除亚稳态。同步延迟 2 个 mclk 周期。边沿检测后锁存为 `beep_req`，在帧边界消耗。

## Functional Behavior

### 背景音生成（始终运行，不受 beep 状态影响）

1. **音符 LUT**：`note_inc_lut` 函数，3bit 索引映射 8 个音符相位增量（C4~C5）。
2. **相位累加器**：32bit `S_phase_acc`，每个 48kHz 帧边界（LRCK==1 且 bit_cnt==63）累加 `W_note_inc`。
3. **方波生成**：`S_phase_acc[31]` 决定极性——为 1 输出 +AMP，为 0 输出 -AMP，存入 `S_sample_next`。
4. **音符切换**：`S_note_frame_cnt` 计数到 `NOTE_HOLD_FRAMES - 1`（23999）时，`S_note_idx` 加 1（到 7 后回 0），帧计数器清零。
5. **样本装载**：`S_sample_next` 在每个帧边界写入 `S_sample_word` 并装入 `S_shift_reg` 的 bit[63:40]。

### 叫号提示音抢占（新增功能）

1. **触发检测**：
   - `trigger_beep` 经 2FF 同步为 `S_trig_sync2`
   - `S_trig_prev` 记录前一拍
   - `W_edge_det = S_trig_sync2 & ~S_trig_prev` 检测上升沿
   - 上升沿时 `beep_req <= 1'b1` 锁存请求
2. **状态机**（仅在 48kHz 帧边界执行）：
   - **IDLE**：若 `beep_req == 1`，进入 BEEP_DING，相位累加器清零，帧计数器从 1 开始；否则输出背景音 `S_sample_next`。
   - **BEEP_DING**：32bit `S_beep_phase_acc` 每帧累加 `DING_PHASE_INC`（78741068），`S_beep_phase_acc[31]` 决定 +BEEP_AMP 或 -BEEP_AMP；帧计数从 1 到 7200，计满后进入 BEEP_DONG。
   - **BEEP_DONG**：`S_beep_phase_acc` 每帧累加 `DONG_PHASE_INC`（39370534），同理产生 440Hz 方波；帧计数从 1 到 14400，计满后回 IDLE，恢复背景音。
   - **default**：强制回 IDLE，防止非法状态。
3. **抢占规则**：
   - 提示音期间（DING/DONG 状态），`beep_req` 在帧边界被默认清零（第 127 行 `beep_req <= 1'b0`），新触发被忽略。
   - 提示音结束后回 IDLE，此时可接受新触发。
   - 背景音相位累加器和音符切换在提示音期间照常运行，保证恢复时背景音连续。

### I2S 发送时序（与原版完全一致）

1. **BCLK**：每个 mclk 上升沿翻转 `O_i2s_BCLK`（频率 = mclk / 2 = 6.144MHz）。
2. **数据发送**：`O_i2s_BCLK == 1` 时（BCLK 下降沿时刻）：
   - `O_i2s_DOUT <= S_shift_reg[63]`
   - `S_shift_reg <= {S_shift_reg[62:0], 1'b0}`（左移）
3. **位计数**：`S_bit_cnt` 从 0 计到 63，共 64 bit/帧。
4. **声道切换**：
   - `S_bit_cnt == 63` 且 `LRCK == 0`：左声道完成 → LRCK 切为 1，`S_shift_reg` 重新装载 `S_sample_word`（右声道复用同一值）。
   - `S_bit_cnt == 63` 且 `LRCK == 1`：右声道完成 → LRCK 切为 0，新样本生成并装入。
5. **状态切换时机**：所有状态机切换仅在帧边界（LRCK==1 且 bit_cnt==63 的 mclk 上升沿）发生，不破坏 I2S 位流连续性。

## Timing, Latency, and Throughput

- **I2S 采样率**：12.288MHz / 256 = 48kHz（64fs 格式，左右各 32bit 含 8bit padding）。
- **BCLK 频率**：6.144MHz（mclk / 2）。
- **帧周期**：1/48000 = 20.833us，对应 128 个 mclk 周期（256 个 BCLK 半周期）。
- **提示音触发延迟**：`trigger_beep` 上升沿到提示音开始，最大延迟 = 2 mclk（2FF 同步）+ 1 帧边界等待（最多 20.8us）。
- **提示音总时长**：7200 + 14400 = 21600 帧 = 0.45s。
- **背景音循环周期**：8 音符 x 24000 帧 = 192000 帧 = 4.0s。

## Assumptions and Chosen Defaults

1. **trigger_beep 信号**：假设为外部输入，可能异步于 I_mclk，因此使用 2FF + ASYNC_REG 同步。
2. **提示音频率精度**：相位增量按 `freq * 2^32 / fs` 计算，fs = 48kHz；32bit 累加器频率分辨率约 0.011Hz。
3. **方波生成**：使用相位累加器 bit31 作为方波极性控制，无需 sin 查表。
4. **BEEP_AMP 默认值**：与背景音 AMP 相同（24'sd2000000），可通过参数调整音量。
5. **背景音不暂停**：提示音期间背景音相位累加器继续运行、音符切换正常进行，保证恢复时背景音连续无断裂。
6. **左右声道复用**：提示音和背景音均左右声道复用同一 `S_sample_word`（与原版行为一致）。
7. **帧计数器位宽**：14bit（最大 16383），DING_FRAMES=7200 和 DONG_FRAMES=14400 均在此范围内。

## Edge Cases and Error Handling

1. **提示音期间新触发**：被忽略。`beep_req` 在帧边界默认清零，DING/DONG 状态不检查 `beep_req`。
2. **复位后状态**：所有寄存器清零（S_sample_next 为 AMP），状态机在 IDLE，背景音从音符 0（C4）开始。
3. **帧边界对齐**：所有状态切换严格在 LRCK==1 且 bit_cnt==63 时发生，保证 I2S 时序完整性。
4. **相位累加器溢出**：32bit 自然溢出，无需额外处理。
5. **default 状态分支**：状态机 default 分支强制回 IDLE，防止非法状态导致死锁。
6. **beep_req 竞争**：`beep_req` 在帧边界先默认清零、再在 IDLE 分支中被检查。若同一帧边界检测到新边沿且处于 IDLE，则 `beep_req` 被设为 1 后立即在 IDLE 分支中被消耗（非阻塞赋值后值生效，下帧开始播放）。

## Synthesis Notes

- **ASYNC_REG 属性**：`S_trig_sync1` 和 `S_trig_sync2` 标记为 `(* ASYNC_REG = "TRUE" *)`，指导 FPGA 布局工具将同步器 FF 放置在靠近 IOB 的位置。
- **寄存器复位**：所有寄存器使用异步复位（`posedge I_rst`），符合 FPGA 原语特性。
- **无锁存**：所有 `always` 块为时序逻辑，无组合锁存风险。
- **位宽匹配**：14bit 帧计数器足够容纳 DING_FRAMES=7200 和 DONG_FRAMES=14400。
- **方波 vs 正弦波**：当前实现为方波输出，资源消耗极低。若需正弦波需增加查表或 CORDIC。
- **资源估算**：新增约 80 个寄存器（32bit 相位累加器 + 14bit 帧计数器 + 24bit 样本 + 状态 + 同步器），综合后几乎无额外 LUT 开销。

## Verification Plan

1. **背景音功能**：验证 8 音符循环播放，每音持续 24000 帧（0.5s），音调与 LUT 一致。
2. **提示音触发**：施加 `trigger_beep` 上升沿脉冲，验证 880Hz 方波输出 7200 帧后切换为 440Hz 方波 14400 帧。
3. **提示音抢占**：提示音期间持续拉高 `trigger_beep`，验证仅响应一次触发。
4. **自动恢复**：提示音结束后验证自动回 IDLE，输出恢复为背景音。
5. **I2S 时序**：验证 BCLK = mclk/2，LRCK 周期 = 64 BCLK，DOUT 在 BCLK==1 时更新且取 shift_reg[63]。
6. **声道复用**：验证左右声道发送同一 `S_sample_word` 值。
7. **帧边界切换**：验证所有状态切换仅在 LRCK==1 且 bit_cnt==63 时发生。
8. **复位测试**：异步复位后验证所有信号为 0（S_sample_next 为 AMP），状态机在 IDLE。
9. **连续触发**：提示音结束后立即再次触发，验证可连续播放。

## Acceptance Criteria

1. 端口仅新增 `trigger_beep`，原有端口顺序、名称、位宽不变。
2. 背景音 8 音符循环正常，相位增量与 LUT 一致，每音 24000 帧。
3. 提示音"叮"880Hz 持续 7200 帧、"咚"440Hz 持续 14400 帧，频率精度由 32bit 相位累加器保证。
4. I2S 发送时序完全保持：BCLK 每 mclk 翻转、S_bit_cnt 0~63、LRCK 半帧切换、S_shift_reg 左移、O_i2s_DOUT 取 bit63。
5. 所有状态切换仅在 48kHz 帧边界（LRCK==1 且 bit_cnt==63）发生。
6. 提示音期间忽略新触发，提示音结束后自动恢复背景音。
7. 代码可综合，无 stub、无 TODO、无 FIXME，复位为高有效异步复位。
8. trigger_beep 经 2FF 同步（ASYNC_REG 属性）+ 边沿检测 + 锁存。

## Requirement Summary

图片切换淡入淡出转场的像素域处理流水线，包含行缓存读取控制和 Alpha 混合计算。模块输出与既有 `video_delay` 模块的 20 拍延时链逐拍对齐，保证顶层在"转场通路 vs 非转场通路"二选一时无相位跳变。

## Public Interface

| Port | Direction | Width | Active | Description |
|------|-----------|-------|--------|-------------|
| `video_clk` | input | 1 | 上升沿 | 25MHz 像素时钟 |
| `rst` | input | 1 | 高有效 | 异步复位 |
| `xfd_en` | input | 1 | 高有效 | 转场使能（1=本通路输出有效） |
| `alpha` | input | 9 | 0..256 | 混合系数（0=全新旧图，256=全新图） |
| `hs_in` | input | 1 | 高有效 | 来自 video_timing_data 的行同步 |
| `vs_in` | input | 1 | 高有效 | 来自 video_timing_data 的场同步 |
| `de_in` | input | 1 | 高有效 | 来自 video_timing_data 的数据使能 |
| `rd_page` | output | 1 | - | 行缓存读页选择（显示行号奇偶） |
| `rd_addr` | output | 10 | 0..639 | 行缓存读地址（= 当前像素 x） |
| `old_dob` | input | 32 | - | 旧图行缓存输出（页由顶层按 rd_page 选择） |
| `new_dob` | input | 32 | - | 新图行缓存输出（同上） |
| `hs_out` | output | 1 | 高有效 | 延时 20 拍的行同步 |
| `vs_out` | output | 1 | 高有效 | 延时 20 拍的场同步 |
| `de_out` | output | 1 | 高有效 | 延时 20 拍的数据使能，与 rgb_out 对齐 |
| `rgb_out` | output | 24 | - | 混合后像素 {R[23:16], G[15:8], B[7:0]} |
| `disp_row` | output | 10 | - | 当前显示行号（调试用） |

## Parameters and Defaults

| Parameter | Default | Description |
|-----------|---------|-------------|
| `LINE_LEN` | 640 | 一行有效像素数 |
| `LAT` | 20 | 对齐延迟拍数，固定 20（与 video_delay 一致） |

## Clocking and Reset

- 时钟：`video_clk = 25MHz`，所有逻辑在上升沿触发
- 复位：`rst` 高有效异步复位，所有寄存器复位清零
- 复位释放后，内部计数器、延时链、页选择逻辑立即开始工作

## Functional Behavior

### 1. 延时链（hs_d / vs_d / de_d）

- 结构：21 位移位寄存器 `[20:0]`（LAT+1 位），每拍左移一位
- 移入：`hs_d <= {hs_d[19:0], hs_in}`（vs_d、de_d 同理）
- 输出：`hs_out = hs_d[20]`，`vs_out = vs_d[20]`，`de_out = de_d[20]`
- 延迟：输入到输出恰好 20 拍

### 2. 像素计数 x（决定 rd_addr）

- 位宽：10bit，范围 0..639
- 递增条件：`de_d[18] == 1` 时 `x <= x + 1`
- 清零条件：`de_d[18] == 0` 时 `x <= 0`
- 输出：`rd_addr = x`（组合逻辑）
- 时序对齐：
  - 第一个 `de_d[18]==1` 的周期：x=0
  - 下一拍（`de_d[19]`）：BRAM 输出 `mem[0]`（读延迟 1 拍）
  - 同一拍（`de_d[19]`）：混合结果锁存到 rgb_r
  - 再下一拍（`de_d[20]`）：rgb_out 有效，对应像素 0

### 3. vs_in 上升沿检测

- 实现：`vs_d1` 打一拍，`vs_rise = vs_in & ~vs_d1`
- 用途：场起始时复位 page 和 row

### 4. de_d[20] 下降沿检测

- 实现：`de_out_fall = ~de_d[LAT] & de_d[LAT-1]`（即 `~de_d[20] & de_d[19]`）
- 用途：一行结束时翻转 page、递增 row
- 时机：仅在行消隐期发生，此时 `de_d[18]==0`，不产生 BRAM 读

### 5. 行缓存页选择 page

- 复位值：0
- vs_in 上升沿：`page <= 0`（场起始）
- de_d[20] 下降沿：`page <= ~page`（行结束翻转）
- 输出：`rd_page = page`（组合逻辑）
- 安全性：page 仅在消隐期翻转，此时 `de_d[18]==0`，不会读到错页

### 6. 显示行号 row（调试用）

- 位宽：10bit
- vs_in 上升沿：`row <= 0`
- de_d[20] 下降沿：`row <= row + 1`
- 输出：`disp_row = row`（组合逻辑）

### 7. Alpha 混合计算（组合逻辑）

- 公式：`out = (old * (256 - alpha) + new * alpha) >> 8`
- 三通道独立计算（R/G/B），取 `old_dob/new_dob` 的 `[23:16]=R`、`[15:8]=G`、`[7:0]=B`
- 位宽分析：
  - alpha：9bit（0..256）
  - alpha_inv = 256 - alpha：9bit（0..256）
  - 像素通道：8bit（0..255）
  - 乘法：`{1'b0, pixel} * {1'b0, weight}` = 9bit x 10bit = 18bit（足够）
  - 两项和：18bit + 18bit，用 19bit 防溢出（最大值 255*256 + 255*256 = 130560）
  - >>8：取 [15:8] = 8bit，实际有效范围 0..255
- 边界验证：
  - alpha=0：`out = old*256 + new*0 = old*256 >> 8 = old`（精确）
  - alpha=256：`out = old*0 + new*256 = new*256 >> 8 = new`（精确）
  - 中间值：误差 ≤ 1 LSB（整数除法截断）

### 8. 输出寄存

- 锁存条件：`de_d[19] == 1` 时 `rgb_r <= blend_rgb`
- 清零条件：`de_d[19] == 0` 时 `rgb_r <= 0`
- 输出：`rgb_out = rgb_r`
- 对齐：与 `de_d[20]`（即 `de_out`）严格对齐

### 9. xfd_en 的影响

- `rgb_out` 在 `xfd_en=0` 时无意义（顶层不选用）
- 但 `x / hs_d / vs_d / de_d / page / row` 照常运行（不用 xfd_en 门控计数）
- 目的：`xfd_en` 上升沿到来时内部状态已就绪，二选一切换无跳变

## Timing, Latency, and Throughput

- 输入到输出延迟：20 拍（由 LAT 参数决定）
- 吞吐：每拍 1 像素（25MHz 下 = 25Mpixel/s）
- 行缓存读延迟：1 拍（BRAM NOREG 模式）
- 混合计算延迟：组合逻辑（无额外流水线级）

## Assumptions and Chosen Defaults

1. BRAM 读延迟：1 拍（REGMODE=NOREG），BRAM 地址输入后下一拍输出数据
2. 行有效像素数：640（LINE_LEN 参数）
3. alpha 精度：9bit（0..256），混合误差 ≤ 1 LSB
4. xfd_en 不影响内部状态：无论 xfd_en 是否为 1，x/page/row/延时链照常运行
5. old_dob/new_dob 的 [31:24] 未使用（仅取 [23:0] 的 RGB 数据）
6. 与 video_delay 对齐：hs_d/vs_d/de_d 的移位结构与 video_delay 完全一致

## Edge Cases and Error Handling

- 复位：所有寄存器异步清零，复位释放后立即开始计数
- 场起始：vs_in 上升沿复位 page=0、row=0
- 行结束：de_d[20] 下降沿翻转 page、递增 row
- xfd_en=0：rgb_out 无意义（顶层不选用），但内部状态已就绪
- alpha 边界：alpha=0 精确输出 old，alpha=256 精确输出 new
- old_dob/new_dob 高 8 位（[31:24]）：忽略，仅使用 [23:0]

## Synthesis Notes

- 纯 Verilog-2001，可综合，不调用任何 TD IP
- 所有寄存器异步复位（posedge rst）
- 混合计算为组合逻辑，无额外流水线（若需提高频率可在 blend_rgb 处加 1 级寄存器）
- 乘法器由综合器推断为 DSP 或 LUT 阵列（取决于器件资源）
- 中文注释覆盖所有关键逻辑

## Verification Plan

1. 延时对齐：验证 hs_out/vs_out/de_out 与 hs_in/vs_in/de_in 恰好延迟 20 拍
2. 像素计数：验证 x 在 de_d[18] 高电平期间从 0 递增到 639，de_d[18]=0 时清零
3. 页翻转：验证 page 在每行 de_d[20] 下降沿翻转，vs_in 上升沿复位为 0
4. 行号计数：验证 row 在每行 de_d[20] 下降沿递增，vs_in 上升沿复位
5. Alpha 混合边界：
   - alpha=0 → rgb_out = old_dob[23:0]（精确）
   - alpha=256 → rgb_out = new_dob[23:0]（精确）
   - alpha=128 → rgb_out ≈ (old + new) / 2（误差 ≤ 1）
6. 输出对齐：验证 rgb_out 在 de_d[20] 拍有效，与 de_out 严格对齐
7. xfd_en 无影响：xfd_en=0 和 xfd_en=1 时，x/page/row/延时链行为一致

## Acceptance Criteria

1. 所有端口名称、位宽、方向与规格一致
2. 延时链精确 20 拍（LAT=20）
3. Alpha 混合边界值精确，中间值误差 ≤ 1 LSB
4. page/row 翻转仅在消隐期（de_d[20] 下降沿）发生
5. 输出与 video_delay 模块相位对齐
6. 无 stub、TODO、FIXME 等占位符
7. 所有逻辑闭合，无未覆盖分支
8. 纯 Verilog-2001，可综合
