# lvol — macOS dB 均匀输出音量控制

两个小工具，用来弥补 macOS 音量滑块的缺陷：

- **`lvol`** — 命令行工具（C，约 34 KB，无运行时依赖）
- **`lvol.app`** — 桌面窗口小应用（Swift/AppKit）

## 它解决什么问题

macOS 的音量滑块**几乎是线性幅度**的（实测：滑块 50% → 底层幅度标量 0.5，滑块 12% → 0.125）。
线性幅度在低音量区的听感跨度极大：底层幅度从 0.01 到 0.02 就是 **+6 dB** 的跳跃。
所以当你（尤其是接耳机时）需要把音量压到很低时，滑块的每一格都太粗，没法做细节调节。

`lvol` 的做法：

1. 用一个 **dB 均匀**的 0–100 刻度（每 1 格 = 同样的 dB 变化，等于同样的听感变化），低音量区因此可以精细调节；
2. 直接写设备的**浮点**音量标量，能到达系统滑块无法到达的低电平（例如 −50 dB ≈ 0.32%，滑块最低非零值约 1%）。

## 构建

```sh
make            # 产出 ./lvol（CLI）和 build/lvol.app（桌面窗口应用）
```

需要：

- **macOS 12 (Monterey) 或更新版本** —— 代码用到 `kAudioObjectPropertyElementMain`，
  该常量由 macOS 12 SDK 引入（`Info.plist` 里对应 `LSMinimumSystemVersion = 12.0`）；
- **Xcode Command Line Tools**（`clang` + `swiftc`），不需要完整 Xcode；
- **Python 3 + [Pillow](https://python-pillow.org/)**（`pip3 install Pillow`），只用于生成应用图标。
  没装 Pillow 时会跳过图标并给出提示，`./lvol` 和 `lvol.app` 仍能正常构建；
  只要 CLI 的话直接 `make lvol`。

## 桌面窗口应用（GUI）

```sh
make install-gui        # 复制到 ~/Applications/lvol.app
open ~/Applications/lvol.app
```

启动后会出现一个**桌面窗口**（Dock 里也会有一个图标）：

- **大滑块**：拖动着调音量，刻度是 dB 均匀的（低音量区一样好调）；
- **数值**：同时显示 `level / dB / 线性%`；
- **Mute**：静音开关。

窗口打开时，如果你用音量键或别的程序改了音量，显示会每 2 秒自动同步。

关掉窗口后应用仍在 Dock 里——点 Dock 图标即可重新打开；`Cmd+Q` 才真正退出。

### 键盘快捷键

窗口聚焦时（应用在前台）：

- `+` 或 `=` —— 音量 +2 格
- `-` —— 音量 −2 格

窗口不在前台时不响应——这是应用内的局部快捷键，不是全局热键。

**开机自启**：系统设置 → 通用 → 登录项，把 `~/Applications/lvol.app` 加进去。

### 无界面自检

应用二进制也能当命令行用（方便排查）：

```sh
~/Applications/lvol.app/Contents/MacOS/LvolApp --get      # 打印当前音量
~/Applications/lvol.app/Contents/MacOS/LvolApp --set 70   # 设为刻度 70
```

### 应用图标

应用图标由根目录的 `logo_raw.png` 生成：构建时会自动裁掉白边、把图形居中放进 macOS 圆角方块，并输出多尺寸 `.icns`（脚本 `gui/make_icon.py`，纯 Python + Pillow，不依赖 `sips`/`iconutil`）。换图标只需替换 `logo_raw.png` 再 `make`。

### 从 GitHub 下载后打不开（Gatekeeper）

`lvol.app` 用的是 **ad-hoc 签名**（`codesign --force --sign -`），既没有开发者 ID 签名、
也没有经过 Apple 公证。从 GitHub 下载后，macOS 会给它打上隔离属性
（`com.apple.quarantine`），首次双击时弹出“无法打开，因为 Apple 无法检查它是否包含
恶意软件”之类的提示。两种放行方式：

- **Finder 里右键**（或按住 Control 点击）这个 app → **打开**，再在弹窗里点一次 **打开**；
- 或者去掉隔离属性：

```sh
xattr -dr com.apple.quarantine ~/Applications/lvol.app
```

自己在本机 `make` 构建出来的 app 不带隔离属性，也就不会有这个提示。

### 卸载

```sh
make uninstall-gui      # 删除 ~/Applications/lvol.app
```

## 命令行用法

```sh
make install            # 安装到 /usr/local/bin/lvol

lvol                 # 查看当前音量（刻度 / dB / 线性幅度）
lvol 70              # 设置感知刻度 0-100（等步长 = 等 dB）
lvol +5              # 相对调高 5 格
lvol -5              # 相对调低 5 格
lvol -30dB           # 以绝对增益设置（0dB = 最大，可选负数越小越轻）
lvol mute / unmute   # 静音 / 取消静音
lvol list            # 列出输出设备
```

选项：

```sh
lvol -d "耳机" ...    # 指定设备（按名称子串匹配，默认用系统默认输出设备）
lvol -r 80  ...       # 调整 0-100 刻度覆盖的 dB 跨度（默认 60 dB）
lvol -h               # 帮助
```

刻度含义（默认 `-r 60`）：`level 100 → 0 dB（100%）`，`level 0 → −60 dB（0.1%）`，
中间线性对应 dB。所以 `level 50 = −30 dB`，`level 70 ≈ −18 dB`。

## 例：把耳机调到一个合适的低音量

```sh
$ lvol
外置耳机   level  69.9/100    -18.1 dB   amp 12.500%

$ lvol -50dB
外置耳机   level  16.7/100    -50.0 dB   amp  0.316%
```

注意：系统音量 UI 会显示 0%（因为它只显示整数百分比），但设备实际是 0.316%，
不是静音——这正是比滑块更低、更细的控制。

## 工作原理

- 取默认输出设备（`kAudioHardwarePropertyDefaultOutputDevice`）。
- 读写设备的虚拟主音量：优先 `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`，
  回退到 `kAudioDevicePropertyVolumeScalar`（主 / 通道 1）。
- 这些属性是 `Float32`，可写任意浮点，因此不受滑块 1% 步进限制。
- 刻度换算：`dB = (level/100 - 1) * range`，`scalar = 10^(dB/20)`。
- CLI 与应用是**同一套逻辑**的两个前端（C 与 Swift 各实现一份），输出一致。

## 可选：绑定到键盘

GUI 提供滑块；若还想要快捷键，可在 Karabiner-Elements / skhd / Raycast / 快捷指令里绑定：

```sh
lvol +2      # 音量 + 键
lvol -2      # 音量 - 键
```

（CLI 不接管系统音量键——那需要常驻进程。桌面应用本身也不会拦音量键。）

## 许可

[MIT](LICENSE)
