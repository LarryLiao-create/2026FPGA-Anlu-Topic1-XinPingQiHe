# 交接说明 —— 图片切换淡入淡出转场（架构 → RTL）

## 1. 本阶段结论

已完成“图片切换淡入淡出（Alpha 交叉溶解）转场”的架构设计，冻结了模块划分、接口契约、时钟/复位/CDC 策略、SDRAM 读端口仲裁与行缓存读写约定。

**同时发现并修正了当前磁盘代码的一条根本缺陷**：现有“每行触发 `read_req` + `read_len=640`”的读取通路**没有行地址偏移**，且 `rd_toggle` 让相邻行交替取自显示 BUF 与 BUF2，导致 480 行全部读第 0 行并隔行撕裂（用户已确认上板显示不对）。本架构据此对既有通路做了最小回退（R-01）。

## 2. 产物清单

| 文件 | 内容 |
|---|---|
| `doc/arch/interface_contract.yaml` | 顶层端口、3 个新模块、4 处既有改动、行缓存 BRAM、顶层仲裁/二选一的完整端口契约 |
| `doc/arch/clock_reset_cdc.md` | 7 个时钟域、复位策略、行缓存结构性 CDC、“写页≠读页”证明、新增 CDC 清单、带宽/资源核算 |
| `doc/arch/module_partition.md` | 模块表、所有权边界、黑盒、数据流总览 |
| `doc/arch/connection_matrix.md` | 生产者→消费者矩阵、信号级仲裁/二选一代码、一帧内时序关系 |
| `rtl/top_skeleton.sv` | 顶层连接骨架（接口参考，不参与综合） |
| `doc/arch/risks.md` | 3 处方案偏离说明、高风险 R-04/R-05/R-06/R-11、未决问题 |
| `doc/arch/handoff_packet.md` | 本文件 |

## 3. RTL 生成清单（按此顺序，逐一调用，一次一个模块）

| 序 | 目标文件 | 类型 | 关键点 |
|---|---|---|---|
| 1 | `src/user_source/hdl_source/xfd_line_fetch.v` | 新增 | mem_clk 域；行号领先一行；先 old 后 new 各 640 词；写 `row[0]` 页 |
| 2 | `src/user_source/hdl_source/xfd_disp_pipe.v` | 新增 | video_clk 域；20 拍延时链与 `video_delay` 同构；`out=(old*(256-a)+new*a)>>8` |
| 3 | `src/user_source/hdl_source/xfd_ctrl.v` | 新增 | video_clk 域；帧边界启停转场；alpha 0..256 斜坡；产生 6 组输出 |
| 4 | `src/user_source/hdl_source/SD/frame_fifo_read.v` | 修改 | 移除 `rd_toggle`，地址选择回到 `read_addr_index_d1` |
| 5 | `src/user_source/hdl_source/SD/video_timing_data.v` | 修改 | 新增 `xfd_en`；`read_req` 每帧一次；`xfd_en` 时清零 |
| 6 | `src/user_source/hdl_source/SD/sd_card_bmp.v` | 修改 | 新增 `xfd_busy`；三处 load_start 追加 `&& !xfd_busy` |
| 7 | `src/user_source/hdl_source/top_tf_hdmi_audio.v` | 修改 | 例化 3 新模块 + 4 RAM_0；读端口仲裁；显示二选一；5 处 CDC；补齐 `ram_*` 声明；`read_len=307200` |

> 注意：`top_tf_hdmi_audio.v` 需在其既有内容基础上增改（不是重写），保留 TF/HDMI/音频/PLL 全部实例。

## 4. 编译检查

对全部改动文件运行编译检查（`iverilog -tnull`），重点验证：
- 新增 3 模块语法与端口一致；
- `top_tf_hdmi_audio.v` 中原 TD 报的 5 处 `ram_*` undeclared/no-driver 警告消除（`syn_1/run.log:93,96,97,279,282`）；
- 无隐式 1 bit wire 悬空。

## 5. 上板验证口径

1. 不切图：画面与改前一致（无条纹、无残缺行）。
2. 切图（按键或自动）：出现平滑淡入淡出，无黑屏、无撕裂、无接缝条带。
3. 字幕滚动、右上时间戳、左上亮度显示、按键调亮度、音频全部正常。
4. （可选）引出 `alpha` / `fetch_row` / `disp_row` 用 ChipWatcher 观察斜坡与行号锁步。

## 6. 需要用户确认（实施前）

- R-01 / R-02 / R-03 三处方案偏离是否接受（见 `risks.md` 第 0 节）。
- `ALPHA_STEP` 取值（默认 4 ≈ 1.07 s；8 ≈ 0.53 s）。
- BUF2 本次留空是否可接受（如需三缓冲轮换可后续扩展）。
