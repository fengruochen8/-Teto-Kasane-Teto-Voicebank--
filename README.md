# 旋律草稿 · TetoMelody

为重音Teto UTAU日语音源做的原生 iPad 旋律编辑器。导入音源后，编辑、歌声合成、保存和 WAV 导出都在设备上完成。

## 运行

需要安装了 Xcode 16或更高版本的 Mac，支持 iPadOS 17及以上。打开 `TetoMelody.xcodeproj`，选中 `TetoMelody` scheme 和一台 iPad 模拟器即可运行。安装到 iPad 时，在目标的 Signing & Capabilities 中选择团队，并选择已启用开发者模式的设备。Xcode 首次构建会获取固定版本的 ZIPFoundation。

```sh
xcodebuild -project TetoMelody.xcodeproj -scheme TetoMelody \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 工程管理

启动后进入欢迎页。可命名并新建空白工程，从「文件」打开 .tetomelody，也可点「打开示例」练习。编辑过的工程会自动保存在本机，之后可从「最近工程」继续。旧版保存的旋律会出现在「上次编辑的旋律」。

编辑页的「保存」在第一次使用时会让你选文件位置，已打开或已保存的工程可以通过「保存」更新原文件。「工程」菜单提供「另存为」，可以选新位置或文件名。一份 .tetomelody 只保存旋律、速度和歌词，换设备打开后需要在该设备导入音源。

## 欢迎页插画

个人构建使用[重音Teto官网配布的角色插画](https://kasaneteto.jp/illust-logo/)。Xcode 读取本地的 `App/Assets.xcassets/TetoWelcomeIllustration.imageset`，资源按[角色使用条款](https://kasaneteto.jp/guideline/character.html)用于个人非商用构建。图片著作权标注为重音テト © 線／小山乃舞世／TWINDRILL。从 Git 克隆后，个人构建可运行 `python3 scripts/fetch_teto_art.py`，从官网获取同一张插画、校验原图并生成本地 Xcode 资源。如果 `LocalArtwork/OfficialTetoUTAU.png` 已有官网原图，脚本会优先复用。在 macOS 使用系统的 sips 缩放，其他平台使用 Pillow。

## 使用

1. 在[重音Teto官网](https://kasaneteto.jp/utau/)选择「通常音源 単独音」并将 `TETO-tandoku-100619.zip` 保存到 iPad 的「文件」。在 App 中选「导入音源 ZIP」。
2. 默认使用「选择」编辑已有音符，切换「画笔」后点网格添加音符，也可拖动决定时值。拖动音符本体改音高或起拍，拖右端改时值。「网格吸附」可切换1/16、1/8和1/4。音符默认唱「ら」，选中后可逐音编辑日语假名。
3. 点底部「钢琴键盘」展开，App 启动时键盘收起。「试听」可以直接弹键找音高。「录入」在橙色光标处写入音符，然后前进到音符末尾。点卷帘上方的时间尺可重新定位。光标对准现有音符起点时，按键只改这个音符的音高，保留歌词和时值。
4. 点按或拖动时间尺设定试听起点，点「Teto唱一遍」从该位置开始，播放头随歌声移动。录入光标与试听起点不同时，橙线表示录入位置，浅灰线表示试听起点。点回到开头按钮从第1小节开始。通过「导出 WAV」保存完整4小节的44.1kHz单声道16位 PCM。
5. 编辑会自动保存。使用撤销与重做按钮恢复操作，外接键盘可以用⌘Z和⇧⌘Z。

真机验收可先新建、编辑并保存一个 .tetomelody 工程，返回首页后重新打开文件，检查音符、速度和歌词。再导入音源并打开飞行模式。播放示例，改一个音高和一个假名，确认重合成后都能听出变化。导出 WAV，并在重开 App 后检查旋律和音源仍可用。

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
