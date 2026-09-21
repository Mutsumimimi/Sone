# lvol — 让 macOS 的音量调节变得细腻

macOS 的音量滑块在低音量区太粗：一格可能就是好几 dB 的跳跃。戴耳机想听小一点时，
要么还是太响，要么一下子跳到静音。

lvol 用一个 **dB 均匀**的刻度取代它——每格对应相同的 dB 变化，也就是相同的听感变化——
并且直接控制设备的浮点音量，能压到系统滑块到不了的更低电平。

## 安装

```sh
make
make install-gui        # 装到 ~/Applications/lvol.app
```

需要 macOS 12 或更新版本，以及 Xcode Command Line Tools。

## 使用

打开 `lvol.app` 拖动滑块即可，数值会同时显示 level / dB / 线性幅度。

- **菜单栏图标** —— 左键唤出窗口；右键有快捷菜单：音量增减、全局快捷键开关、最低音量档位
- **全局快捷键** —— 默认 `⌥-` / `⌥+` 调音量，**按住可连续调整**；可在设置里录成任意组合
- **设置** —— `⌘,`
- 调音量时会**自动解除静音**；设备静音时滑块变灰，但仍然可以拖

窗口聚焦时的快捷键：`+` / `=` 音量 +2 格，`-` 音量 −2 格。

## 设置

`⌘,` 打开设置窗口：

- **Minimum volume** —— 刻度最低能压到多低（−30 … −120 dB）
- **Volume up / Volume down** —— 录制全局快捷键（至少要带一个修饰键）
- **Global hot keys** —— 全局快捷键的总开关

## 命令行

```sh
make install            # 装到 /usr/local/bin/lvol

lvol 70                 # 设为刻度 70
lvol +5  /  lvol -5     # 相对调整
lvol -30dB              # 按绝对增益设置
lvol mute / unmute      # 静音 / 取消静音
lvol list               # 列出输出设备
```

`lvol -h` 看全部选项（`-d` 指定设备、`-r` 调刻度跨度）。

## 打不开？

app 是本地签名、未经 Apple 公证，从网上下载后首次打开可能被 Gatekeeper 拦下。
在 Finder 里**右键 → 打开**，或者：

```sh
xattr -dr com.apple.quarantine ~/Applications/lvol.app
```

自己 `make` 出来的 app 不会有这个问题。

## 许可

[MIT](LICENSE)
