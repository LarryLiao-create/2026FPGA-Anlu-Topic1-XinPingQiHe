# osd_overlay 滚动字幕 需求梳理摘要

## Task Summary

在既有 HDMI 640x480 图片轮播工程中，新增 Verilog 模块 `osd_overlay`，在视频帧底部叠加一条**整行宽浅蓝底黑字**的滚动字幕。文本为「温馨提示：请保持安静，有序就诊，谢谢配合」，从右向左滚动，每帧移动 1 像素，非字幕区像素透传原始 RGB。

任务类型：新增可综合 RTL（1 个字库模块 + 1 个叠加模块），不含约束/仿真交付。

> 后续变更（用户提供自有字模后）：字幕字符数由 20 改为 **21**（末尾增加全角句号「。」），
> 因此 `TEXT_W` 由 320 改为 **336**、`NCHAR` 由 20 改为 **21**、`SCROLL_SPAN` 由 960 改为 **976**。
> 用户字模为**纵向取模**（每个 16 位字是一整列），已转置为行取模后填入 `char_rom`；
> 详见 `doc/osd/osd_font21_src.txt` 与 `font21_21x16_rowmajor.hex`。

## Confirmed Facts

**目标文件与现状**

- `src/user_source/hdl_source/osd_overlay.v` 当前为空壳 `module osd_overlay( ); endmodule`，且**未**被 `src/td_project/HDMI1.4b_Transmitter_v1.0_Runs/{syn_1,phy_1}/HDMI1.4b_Transmitter_v1.0.prj` 源文件列表引用（暂不在编译范围内）。
- 子模块 `char_rom` 全工程不存在，需新建。

**接口（已修正用户笔误）**

- `input clk`（像素时钟 25MHz）、`input rst`（高有效）、`input hs`、`input vs`、`input de`、`input [23:0] rgb_in`
- `output reg [23:0] rgb_out` —— 用户原文写作 `input [23:0] rgb_out`，方向为笔误，实际为输出；已修正。

**字幕几何**

- 文本 = 18 汉字 + 2 个全角标点（`：` `，`），**实际 20 个 16px 字符格**，点阵总宽 = 20 × 16 = **320 像素**（非按 18 字算的 288）。
- 字符格紧邻无间隔：第 k 字占点阵列 `[k*16, k*16+15]`。
- 叠加行范围：**第 450~465 行，共 16 行**（用户原文「450~466」与「高度16像素」矛盾，经确认为 450~465）。
- 颜色：文字 `24'h000000`，底色 `24'hADD8E6`。

**用户本轮确认的两项决策**

1. **字幕条为整行宽**：第 450~465 行的全部 x（0..639）都填浅蓝底，黑字在其上右→左滚过。
2. **行范围取 450~465（16 行）**。

**视频时序（实测自 `SD/color_bar.v` 的 `VIDEO_640_480`）**

- H_ACTIVE=640, H_FP=16, H_SYNC=96, H_BP=48 → **H_TOTAL=800**
- V_ACTIVE=480, V_FP=10, V_SYNC=2, V_BP=33 → **V_TOTAL=525**
- HS_POL=0, VS_POL=0；像素时钟 25MHz（640x480@60）

**接入点（实测自 `top_tf_hdmi_audio.v`）**

- `video_timing_data_m0` → `hs_0/vs_0/de_0` → `video_delay_m0` → `hs/vs/de` + `vout_data_raw`
- `assign vout_data = display_valid ? vout_data_raw : 24'd0;` → `video_rgb_to_axis_640x480` 的 `I_vs/I_de/I_rgb`
- 建议插入：`vout_data` → `osd_overlay` → `video_rgb_to_axis_640x480.I_rgb`，`hs/vs/de` 同域引入。

**字模可行性（已实测）**

- `C:\Windows\Fonts\simsun.ttc` 含 EBDT/EBLC 点阵，存在 **ppemX=16 / ppemY=16 / bitDepth=1** strike，覆盖全部字形 —— 可提取**真实** 16x16 点阵，无需伪造字库。
- 工程内无任何现成中文字模（无 HZK16、无 font 相关 .hex/.mif/.coe）。

**工程技术惯例（实测）**

- 现有 ROM 均为 TD IP 包装（`src/td_project/al_ip/AUDIO_SAMPLE_ROM.v` + `.mif`/`.dath`），其 `.ipc` 无法脚本生成。
- 故本次字库采用**工具无关的纯 Verilog ROM**（`$readmemh` + 内联常量二选一），不依赖 TD IP。

## Hardware Dependency

`hw_dependency: none`

理由：纯 RTL 行为实现（像素域叠加），不涉及引脚映射、IOSTANDARD、板上外设或约束规划；视频时序参数已从工程内实测得到。

## Assumptions and Defaults

标注 owner=用户，若与预期不符需回填：

1. **滚动行程**：默认 `SCROLL_SPAN = H_ACTIVE + TEXT_WIDTH = 640 + 320 = 960`，即文字尾部离开左侧后从右侧重新进入的连续循环。
2. **每帧时机**：默认在 `vs` 上升沿（进入新帧）执行 `scroll_offset <= scroll_offset + 1`（模 `SCROLL_SPAN`）。
3. **整行宽蓝条**：第 450~465 行**始终**输出蓝底（文字未覆盖处为浅蓝），已由用户确认；文字窗口外同样为蓝底。
4. **像素对齐**：与 `hs/vs/de/rgb_in` 同域组合逻辑，不插入额外流水延时；若接入 top 后差 1~2 拍，后续加可选打拍参数。
5. **计数口径**：模块内自维护 `h_cnt`(0..H_TOTAL-1) 与 `v_cnt`(0..V_TOTAL-1)，在 `de` 有效内递增；字幕带 = `de & v_cnt∈[450,465]`，像素 x = `h_cnt`。
6. **字模对齐**：simsun 16ppem 点阵，字形于字符格左上角对齐；个别字的固有侧边距不额外居中。
7. **重复字符**：按 **20 个位置顺序存 20 组字形**（允许重复），寻址 = `{位置[4:0], 行[3:0]}`，不做去重。
8. **参数化**：`H_ACTIVE/H_TOTAL/V_ACTIVE/V_TOTAL/BAND_TOP/BAND_BOTTOM/TEXT_WIDTH/SCROLL_SPAN` 做成模块参数，默认取上述实测值。

## Missing Information

无**阻塞**信息缺失。以下为非阻塞确认项：

- 非阻塞：文字尾部离开后是否需额外空白停留（默认无停留，连续循环）。owner=用户
- 非阻塞：字幕带是否需上下描边/过渡（默认无，纯蓝底黑字）。owner=用户
- 非阻塞：新 RTL 落盘位置（沿用工程源码树 `src/user_source/hdl_source/` 还是在根目录新建 `rtl/`）。owner=用户
- 非阻塞：是否本轮一并接入 `top_tf_hdmi_audio.v`（默认只交付模块）。owner=用户

## Evidence Needed

- 字模提取脚本 `src/user_source/hdl_source/python/gen_font16.py`：从 simsun.ttc 生成 20 个字符的 16x16 点阵。
- **字形正确性证据**：脚本输出的 ASCII 点阵预览，逐字人工核对（无缺字/错字/镜像）。
- **编译证据**：`iverilog -tnull` 对 `osd_overlay.v` + `char_rom.v` 通过（后续编译检查阶段产出）。
- **板上观感证据**（后续）：接入 top 后目视确认蓝条位于底部、文字右→左匀速滚动、字迹清晰。

## Acceptance Criteria

1. 非字幕带像素（`v_cnt∉[450,465]` 或 `de=0`）时 `rgb_out == rgb_in`（透传）。
2. 字幕带且 `de=1` 时：点阵 `=1` 处输出 `24'h000000`，`=0` 处输出 `24'hADD8E6`；整行宽（x=0..639）均为蓝底或黑字。
3. 每帧 `scroll_offset` 恰好 +1；文字 1 像素/帧 右→左移动；到 `SCROLL_SPAN` 回绕，无跳变。
4. 20 个字符格按序水平排列，总宽 320 像素；每字形与 ASCII 预览一致。
5. `char_rom` 以 `{位置[4:0], 行[3:0]}` 寻址输出 16bit 行点阵；20 个位置均能回读正确行数据。
6. 模块可综合、可被 iverilog 编译通过，无仿真专用构造出现在综合路径。

## Handoff and Next Step

**建议下一个 skill：`fpga-rtl-build`**（按模块逐一调用）。

- 模块清单（2 个）：
  1. `char_rom`：16x16 点阵 ROM，地址 `{char_idx[4:0], row[3:0]}` → `[15:0]` 行点阵，含 20 组字形数据。
  2. `osd_overlay`：像素坐标计数、每帧 +1 滚动、字幕带判定、例化 `char_rom`、颜色选择。
- 前置动作：先运行字模提取脚本产出 20 组 16x16 点阵（含 ASCII 预览人工核对），作为 `char_rom` 的数据来源。
- 不在本轮范围：TB、仿真、VCD、XDC、top 接入（接入点已在上文记录，作为可选下一步）。
- 备注：本模块无需板级顶层即可独立生成；如需上板，需例化进 `top_tf_hdmi_audio.v` 视频通路并重新综合。
