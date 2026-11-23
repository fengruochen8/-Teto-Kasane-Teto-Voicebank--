# TetoMelody v1.0 Mac 开发与 iPad 验收交接

## 接手时的版本

- 产品是「旋律草稿」TetoMelody，面向重音Teto UTAU 日语单独音的原生 iPad 编辑器。编辑、转假名、歌声合成和导出在设备上运行。
- 版本为 v1.0.0，构建号9。开发分支为 `codex/ipad-v0.1`。本次验收以代码提交 `916a1e697b6bed4d785f700e122e4d0274e02272` 为基线，后续交接文档有单独的提交。[已验证的代码提交](https://github.com/fengruochen8/-Teto-Kasane-Teto-Voicebank--/commit/916a1e697b6bed4d785f700e122e4d0274e02272)
- Xcode 16.4 和 iOS 18.5的 iPad 模拟器已完成构建和测试。10项 XCTest 通过，其中7项是文件互通、3项是工程保存和迁移。独立 C++ DSP 回归通过。另在本地使用重音实际采样核对了16小节混音、区间渲染及分轨对齐。[CI 结果](https://github.com/fengruochen8/-Teto-Kasane-Teto-Voicebank--/actions/runs/45134700583)
- 真机验收待进行，检查安装签名、文件选择器导入导出、触控手势、首播等待、卡顿或掉帧，以及调校后的听感。

## Mac 环境与拉取

全新环境可以克隆到 `TetoMelody`。已有工作副本时，先用 `git status --short --branch` 核对分支和未提交修改。在 `codex/ipad-v0.1` 分支上执行 `git pull --ff-only origin codex/ipad-v0.1`。

```sh
git clone --branch codex/ipad-v0.1 \
  https://github.com/fengruochen8/-Teto-Kasane-Teto-Voicebank--.git TetoMelody
cd TetoMelody
git status --short --branch
git log -3 --oneline
xcodebuild -version
open TetoMelody.xcodeproj
```

最低部署版本为 iPadOS 17。真机请使用能识别当前 iPadOS 的 Xcode。首次构建需要联网解析固定版本的 Swift Packages，分别为 ZIPFoundation 0.9.21、Mecab-Swift／IPADic 0.8.0和 Yams 6.2.2。后续构建可以复用 Xcode 缓存。

### 个人测试资源

- 将官网的「通常音源 単独音」`TETO-tandoku-100619.zip` 下载到 iPad「文件」，或从 Mac 传到 iPad。在 App 的编辑器选择「导入音源 ZIP」，选中原始 ZIP。[重音Teto音源官网](https://kasaneteto.jp/utau/)
- 个人非商用构建若要显示官方欢迎页插画，在仓库根目录运行 `python3 scripts/fetch_teto_art.py` 后重新构建。有本地原图时脚本会优先复用。音源和插画都作为本地测试资源管理。[插画准备说明](../README.md#欢迎页插画)

## 构建与安装

**模拟器回归。** 在 Xcode 选 `TetoMelody` scheme 和一个 iPad 模拟器，通过 Product → Test 运行单测。也可先用命令列出可用 iPad，再把下方 `IPAD_SIMULATOR_UDID` 替换为对应的设备 ID。

```sh
xcrun simctl list devices available
xcodebuild test -project TetoMelody.xcodeproj -scheme TetoMelody \
  -destination 'platform=iOS Simulator,id=IPAD_SIMULATOR_UDID' \
  -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

**真机运行。** 用 USB 连接并解锁 iPad，按提示配对、信任 Mac，并在 iPad 上打开「设置 → 隐私与安全性 → 开发者模式」，首次开启时按提示重启并确认。在 Xcode 登录自己的 Apple 账户，在 App target → Signing & Capabilities 选择 Team，使用自动签名。把 Run Destination 切换为实物 iPad，再运行 `TetoMelody`。设备列表里缺少 iPad 时先检查配对、开发者模式和 Xcode 对该 iPadOS 的支持。[Apple 真机运行说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

## 真机验收顺序

在欢迎页点「打开示例」得到16小节主唱加和声工程。先另存一份测试副本。保持示例的112 BPM和16小节时，完整混音与分轨 WAV 都应约34.286秒，导出规格是44.1 kHz、16位、单声道。

| 验收项 | 操作与预期 |
| --- | --- |
| 首页、音源和离线 | 启动后从首页新建及打开示例，导入官方 ZIP。退出再打开 App，确认音源仍可用。进入飞行模式后，确认示例可以合成，日语句子可以转成假名。 |
| 时间轴与卷帘 | 放大并横移到第16小节，框选音符并复制到另一轨，批量移调，再撤销与重做。拖动时间尺圈出第5至8小节，打开「循环」后确认播放头回到第5小节。试一遍画笔、音符右端拖动和钢琴键盘录入。 |
| 日语歌词 | 在前段有足够音符时，输入「桜が咲く。」并转换，预览应为`さ・く・ら・が・さ・く`。确认按时间顺序写入当前轨，整批撤销可恢复。换到曲尾测试音符不足提示。 |
| 歌声调校 | 选相邻的两个音符，在后一个音符上启用连唱，循环对比开启前后。分别画音高偏移、调整滑音、颤音和发音早晚。听是否有爆音、明显断裂或发音位置异常。 |
| 多轨及 WAV | 重命名、复制和调序。在同一段对比调整和声音量前后，并测试静音与独奏。导出混音、主唱和和声各一份，核对 WAV 时长一致。若修改过工程长度或 BPM，按修改后的时间计算。 |
| 原生工程保存 | 保存并另存为`.tetomelody`，返回首页，从「文件」打开副本。核对速度、长度、音符、歌词、循环、音量、静音或独奏及调校。用旧工程副本测试迁移，按原节拍核对音符位置。 |
| 乐谱互通 | 将同一份示例导出为`.mid`、`.ust`和`.ustx`，逐一导回为新工程。MIDI 和 USTX 检查多轨，UST 检查导出时选中的轨。核对音高、起拍、时值和歌词。可以在 OpenUtau 再打开 UST／USTX 验证一次。 |

当前乐谱互通按4/4拍和单一速度处理。变速、拍号、伴奏和部分专用表达参数以导入提示为准。`.tetomelody` 用于完整保留本 App 的调校和循环。经典 UST 优先写 Shift-JIS，无法表示的字符使用 UTF-8 文件；旧版 UTAU 对 UTF-8 的兼容性需要单独核对。[OpenUtau 文件格式](https://github.com/openutau/OpenUtau/wiki/USTX-file-format)

### 记录性能和问题

同一台 iPad、同一份测试工程记录首次点击播放到出声的耗时，以及重复播放的耗时。连续缩放、横移、拖音符和切轨，观察卡顿、播放中断与画面迟滞。发现稳定复现的卡顿后，在 Xcode 用 Product → Profile 记录原操作，再看 Time Profiler 和界面卡顿记录。[Apple 响应性排查](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)

每个问题记录设备型号、iPadOS、Xcode、App 提交号、Debug 或 Release、测试工程、复现步骤、预期和实际结果。导入问题保留输入文件的最小复现副本，导出问题保留文件名、格式、时长和报错。有崩溃或明显掉帧时，一并保留 Xcode 日志或 Instruments 记录。

## 开发入口

| 任务 | 文件 |
| --- | --- |
| 工程结构、480 PPQN和旧格式迁移 | [Project.swift](../App/Project.swift)、[ProjectLibrary.swift](../App/ProjectLibrary.swift)、[ProjectMigrationTests.swift](../Tests/ProjectMigrationTests.swift) |
| 选择、跨轨复制、撤销、播放和自动保存 | [StudioModel.swift](../App/StudioModel.swift) |
| 时间轴、触控和键盘 | [PianoRoll.swift](../App/PianoRoll.swift)、[PianoKeyboard.swift](../App/PianoKeyboard.swift)、[MelodySketchApp.swift](../App/MelodySketchApp.swift) |
| 音轨、音量和调校界面 | [TrackPanel.swift](../App/TrackPanel.swift)、[NoteExpressionSheet.swift](../App/NoteExpressionSheet.swift) |
| ZIP 读取、歌词转换和批量写入 | [Voicebank.swift](../App/Voicebank.swift)、[JapaneseLyrics.swift](../App/JapaneseLyrics.swift)、[BatchLyricsSheet.swift](../App/BatchLyricsSheet.swift) |
| 渲染、连音、音高曲线、WAV | [MelodyAudio.swift](../App/MelodyAudio.swift)、[TetoDSP.cpp](../Native/TetoDSP.cpp)、[TetoDSPTests.cpp](../Tests/TetoDSPTests.cpp) |
| 乐谱互通与文件选择器 | [ProjectInterchange.swift](../App/ProjectInterchange.swift)、[ProjectWorkspace.swift](../App/ProjectWorkspace.swift)、[ProjectInterchangeTests.swift](../Tests/ProjectInterchangeTests.swift) |

修复后重跑受影响的真机步骤，再跑 `TetoMelody` 模拟器测试。改过渲染器时一并运行独立 DSP 回归。[DSP 测试命令](../README.md#合成核心检查) · [模拟器 CI 配置](../.github/workflows/ipad-test.yml)

## 可直接贴给 Mac 上的 Codex

> 请阅读本仓库 `docs/MAC_HANDOFF.md`。先核对当前分支、提交、工作区和 Xcode 环境，再运行 TetoMelody 的 iPad 模拟器测试。看到 iPad 可用后，按文档用16小节双轨示例验收真机。构建、文件导入导出、编辑手势、播放听感及帧率分别记录。遇到失败先复现并保存证据，再修复与验收直接相关的问题，复测后给我结果。签名 Team、设备信任和开发者模式由我在 Mac 或 iPad 上处理。
