# 拉霸机 Slot Machine（Godot 4）

3 列滚轮、每列 3 格，只显示滚轮内容，没有外壳。手动逐个停轮（目押），重点做了音效和打击感。
滚轮做成向外鼓起的滚筒；启动后是待机画面（滚轮自己慢慢滚，每列显示"请开始"）；带循环背景音乐和可保存的设置界面。

- 引擎：Godot **4.4+**（GDScript，Compatibility 渲染器，桌面横屏 1920×1080）
- 中奖内容（符号图片、中奖等级、出现概率、音效）全部在编辑器 Inspector 里配置，换内容不用改代码
- 默认素材由 `tools/` 下的脚本生成，没有外部素材

## 运行

用 Godot 4.4 或更新版本打开本目录（导入 `project.godot`），按 F5 运行。

## 操作

| 操作 | 按键 |
| --- | --- |
| 开始（拉杆） | 空格 / 回车 / 鼠标左键 / 手柄 A |
| 停第 1 / 2 / 3 列 | `Z` `X` `C`，或 `1` `2` `3`，或 `←` `↓` `→`，或直接点击该列滚轮，手柄 X / Y / B |
| 停下一列（从左到右） | 转动中再按空格 |
| 打开设置 | Esc 或 F2（手柄 Back），转动中不能打开 |
| 显示 / 隐藏帮助 | F1 |
| 全屏 | F11 |

按键在启动时自动注册。如果你在 **项目设置 → 输入映射** 里定义了同名动作（`slot_start`、`slot_stop_1`…），会优先使用你的设置。

## 待机画面

- 启动后直接进入待机：各列滚轮自己慢慢滚动，每列中间有一块小遮罩，显示"请开始"并呼吸闪烁
- 按开始键（或点击）立刻开转，遮罩淡出
- 一局结束后闲置一段时间（默认 15 秒）自动回到待机。时间在 `Main` 节点 Inspector → 待机 → Attract Delay 里改，设为 0 则不回
- 待机滚动速度、遮罩上的文字在 `SlotMachine` 节点的 Attract Speed、Prompt Text 里改

## 设置界面

按 **Esc** 或 **F2** 打开（转动中不能打开）。可以调：

| 项目 | 说明 |
| --- | --- |
| 屏间距 | 滚轮之间的间距，拖动时上方的滚轮实时变化 |
| 转速（目押难度） | 滚轮转动速度，越快越难目押 |
| 背景音乐音量 | 0 = 静音 |
| 音效音量 | 拖动时会播放一声金币声试听 |

键盘操作：↑↓ 选择项目，←→ 调整数值，Enter 按按钮，Esc 取消（恢复打开前的值）。

点"保存"后写入 `user://settings.cfg`，下次启动自动生效。这个文件的实际位置：

- Windows：`%APPDATA%\Godot\app_userdata\Slot Machine\settings.cfg`
- macOS：`~/Library/Application Support/Godot/app_userdata/Slot Machine/settings.cfg`
- Linux：`~/.local/share/godot/app_userdata/Slot Machine/settings.cfg`

删除这个文件就回到默认值。默认值就是场景里 Inspector 上的值（Reel Gap、Spin Speed 等），"恢复默认"按钮恢复的也是它们。

## 设置滚轮间距和外观（编辑器里）

打开 `scenes/main.tscn`，选中 **ShakeRoot/SlotMachine** 节点，在 Inspector 里修改，编辑器视图会实时预览：

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| Symbol Set | 中奖内容（符号组），见下一节 | `symbols/default_set.tres` |
| Reel Count | 列数 | 3 |
| Visible Rows | 每列可见格数 | 3 |
| **Reel Gap** | **滚轮之间的间距（像素）** | 40 |
| Cell Size | 每格的宽 × 高 | 300 × 210 |
| Curvature | 突起程度：越大，中间一格越突出，上下两格越扁越暗，轮廓越像鼓起的滚筒；0 = 平面 | 0.8 |
| Spin Speed | 转速（格/秒），决定目押难度 | 16 |
| Attract Speed | 待机时自己滚动的速度（格/秒） | 1.6 |
| Prompt Text | 待机时每列遮罩上的文字 | 请开始 |
| 外观 → Reel Color / Edge Shade | 滚轮底色、上下压暗程度 | |

这里的 Reel Gap 和 Spin Speed 是默认值；玩家在设置界面里保存过的值会覆盖它们。

背景色在 `Background` 节点上改；不需要背景可以直接删掉这个节点。

## 更换中奖内容

中奖内容由两种资源文件组成，都在 `symbols/` 目录，双击就能在 Inspector 里编辑，改完编辑器里的滚轮预览会立刻刷新。

**符号**（`symbols/seven.tres` 等，每个文件一个符号）：

| 参数 | 说明 |
| --- | --- |
| Id | 唯一标识，只在手写滚轮带时用到 |
| Display Name | 备注名。没有图片时会把它当文字显示在格子里 |
| Texture | 符号图片。任意尺寸都行，透明背景的 PNG 最好，会按比例缩放进格子；高速转动的模糊效果会自动生成 |
| Tier | 中奖等级：`Jackpot` 大奖 / `Big` 中奖 / `Normal` 小奖 / `None` 不中奖（空白格、装饰用） |
| Color | 主题色：中奖高亮、连线、粒子都用这个颜色 |
| Count | 每列滚轮上出现几次。越多越容易连线；一列的总格数 = 所有符号的 Count 之和 |
| Size Scale | 在格子里的大小（1 = 默认） |
| Win Sound | 这个符号专属的中奖音效；留空就按等级使用默认音效 |

**符号组**（`symbols/default_set.tres`）：

- **Symbols**：这套内容用到哪些符号
- **Custom Strips**（可选）：手写每列滚轮带。第 1 项是第 1 列，按从上往下的顺序写符号的 Id。没写的列会按各符号的 Count 自动均匀排布

常见操作：

- **换图**：打开对应的 `.tres`，把新图片拖到 Texture 上
- **加一个符号**：在 FileSystem 里右键 `symbols/seven.tres` → 复制（Duplicate），改 Id、图片、等级、颜色，然后加到 `default_set.tres` 的 Symbols 列表里
- **去掉一个符号**：从 Symbols 列表删掉（或者把 Count 设成 0）
- **整套换掉**：复制 `default_set.tres`（比如叫 `spring_set.tres`）改成另一套内容，再到 SlotMachine 的 Symbol Set 里切换。不同活动可以各备一套

中奖规则：3 条横线 + 2 条对角线（3×3 时共 5 条），一条线上的符号全部相同、且等级不是 `None`，就算中奖。两列停下后，如果某条线上已经有 2 个相同符号，就进入**听牌**：播放音效，已停的格子高亮，剩下那列发光。

| 等级 | 演出 |
| --- | --- |
| Jackpot | 顿帧、全屏闪光、彩虹连线、金币喷泉加金币雨、背景随节奏闪烁 |
| Big | 号角音效、闪光、金币喷泉 |
| Normal | 琶音、星光 |

**目押补正**（Main 节点 Inspector → 目押补正）：

- `Assist Slip`：停轮时最多再"滑"几格去凑连线或听牌（默认 2；设为 0 就是纯目押，按到哪停哪）
- `Assist Chance`：能凑成时实际去凑的概率（默认 0.35）

## 打击感做了什么

每次停轮：

1. 按键瞬间立刻有"咔"的按键音（反馈不等滚轮）
2. 滚轮冲到格子位置时硬停：过冲后弹簧回弹，运动模糊瞬间消失、符号一下变清晰
3. 停轮重击音：高频瞬态"咔" + 金属撞击"锵" + 下滑低频"咚"，经过软削波；每停一列音调略降，越停越沉
4. 该列闪白 + 落地挤压（先变矮变宽再弹回）
5. 画面向下冲击位移（弹簧）+ 震屏，两侧喷火花，冲击环扩散
6. 手柄震动
7. 最后一列再叠加低频轰击、更强的震屏和缩放冲击，转动声在重击后立刻收掉

中奖时先**顿帧**（时间几乎冻结 0.05~0.13 秒），再爆发连线、粒子和音效。

强度可在 Main 节点 Inspector → 打击感 里调整（震屏倍率、顿帧开关、手柄震动开关）。

## 更换音乐、音效和粒子贴图

**音乐和音效**：选中 `Sfx` 节点，Inspector 里每个声音都是一个槽位，把 `.wav` / `.ogg` / `.mp3` 拖进去即可，留空就不播放：

| 槽位 | 用途 |
| --- | --- |
| Bgm | 背景音乐，会自动循环播放。Bgm Db 调它相对音效的基础音量 |
| Press | 按停止键 |
| Lever | 开始转动 |
| Spin Loop | 转动循环声（会自动循环播放，音调随转速变化） |
| Stop | 停轮重击 |
| Boom | 最后一列停下、中奖时叠加的低频轰击 |
| Reach | 听牌 |
| Win / Win Big / Jackpot | 小奖 / 中奖 / 大奖（符号设置了 Win Sound 时用符号自己的） |
| Coin | 金币声（随机音调连发） |
| Miss | 听牌后没中 |

BGM 和音效分别走 `BGM`、`SFX` 两条音频总线（设置界面里的两个音量调的就是它们）。每次停轮和中奖时 BGM 会被瞬间压低一下，让重击和中奖音乐更突出。

**粒子贴图**：选中 `ShakeRoot/FX` 节点，可以替换 Spark（停轮火花）、Star（中奖星光）、Coin（金币，比如换成你的奖品图标）。金币图不管多大，默认都显示成约 64 像素，可以用 Coin Scale 调大小。

## 重新生成素材

需要 Python 3、numpy、Pillow：

```bash
python3 tools/gen_symbols.py   # 符号、粒子贴图、图标
python3 tools/gen_sfx.py       # 音效和背景音乐（BGM 转 .ogg 需要 ffmpeg，没有则输出 .wav）
```

这两个脚本只用来生成默认素材（会覆盖 `assets/` 里同名文件）。用你自己的素材时不需要它们，直接在 Inspector 里换即可。

## 目录结构

```
scenes/main.tscn        主场景
symbols/                中奖内容：每个符号一个 .tres，default_set.tres 是符号组
scripts/
  main.gd               游戏流程、输入、打击感演出编排
  slot_machine.gd       拉霸机本体（@tool）：布局、间距、中奖线、高亮
  reel.gd               单列滚轮（@tool）：转动、停轮回弹、待机自转、鼓面绘制
  slot_symbol.gd        符号资源（图片、等级、颜色、出现次数…）
  slot_symbol_set.gd    符号组资源（用哪些符号、滚轮带怎么排）
  win_overlay.gd        中奖连线层
  prompt_overlay.gd     待机时每列的"请开始"遮罩
  settings_panel.gd     设置界面
  game_settings.gd      设置的读取与保存（user://settings.cfg）
  shaker.gd             震屏 / 冲击位移 / 缩放冲击
  fx.gd                 粒子与冲击环
  sfx.gd                背景音乐、音效槽位、音效池、转动循环声、音量总线
shaders/reel_blur.gdshader  转动时的纵向运动模糊
assets/                 默认贴图与音效（由 tools/ 生成）
tools/                  默认素材的生成脚本（Godot 会忽略此目录）
```
