# 旋律草稿 · TetoMelody

为重音Teto UTAU日语音源做的原生 iPad 旋律编辑器。导入音源后，编辑、歌声合成、保存和 WAV 导出都在设备上完成。

## 运行

需要安装了 Xcode 16或更高版本的 Mac，支持 iPadOS 17及以上。打开 `TetoMelody.xcodeproj`，选中 `TetoMelody` scheme 和一台 iPad 模拟器即可运行。安装到 iPad 时，在目标的 Signing & Capabilities 中选择团队，并选择已启用开发者模式的设备。Xcode 首次构建会获取固定版本的 ZIPFoundation。

```sh
xcodebuild -project TetoMelody.xcodeproj -scheme TetoMelody \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 使用

1. 在[重音Teto官网](https://kasaneteto.jp/utau/)选择「通常音源 単独音」并将 `TETO-tandoku-100619.zip` 保存到 iPad 的「文件」。在 App 中选「导入音源 ZIP」。
2. 点格子添加音符，拖动本体改音高或起拍，拖右端改时值。音符默认唱「ら」，选中后可逐音编辑为一个日语音节。单轨音符的时间范围不可重叠。点左侧琴键试听音高。
3. 点底部「钢琴键盘」展开，App 启动时键盘收起。「试听」可以直接弹键找音高。「录入」会试听并在橙色光标处写入音符，然后前进到音符末尾。点卷帘上方的时间尺可重新定位。光标对准现有音符起点时，按键只改这个音符的音高，保留歌词和时值。
4. 使用「Teto唱一遍」循环试听4小节，通过「导出 WAV」保存44.1kHz单声道16位 PCM。每次修改都会保存当前旋律。

真机验收可先导入音源，再打开飞行模式。播放示例，改一个音高和一个假名，确认重合成后都能听出变化。导出 WAV，并在重开 App 后检查旋律和音源仍可用。

## 实现与范围

- App 使用 SwiftUI 和 AVFoundation。ZIP 导入读取日文旧编码的 `oto.ini` 与匹配的 WAV，音源保存在设备的应用目录。
- 合成由独立的 C++17 核心完成。根据 `oto.ini` 裁剪和对齐采样，保留固定段，估计发声周期后，按目标音高重采样并调整时长。第一版适配日语单独音，用稳定的发声周期延音。歌声衔接和发音自然度仍需真机试听。后续可在保持编辑器和工程文件格式的前提下替换合成器。
- 仓库内不附带原始音源、角色素材或渲染样音。使用音源须遵守[官方音源条款](https://kasaneteto.jp/guideline/voice.html)。

## 合成核心检查

可在有 C++17编译器的环境中验证合成器。测试使用生成的波形，覆盖变调和极短样本，不需要下载音源。

```sh
mkdir -p build
c++ -std=c++17 -O2 -Wall -Wextra -Werror -INative Native/TetoDSP.cpp Tests/TetoDSPTests.cpp -o build/teto-dsp-tests
./build/teto-dsp-tests
```
