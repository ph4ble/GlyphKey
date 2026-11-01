# MouseGestureKey（鼠标手势按键）

> 把苹果 **Magic Mouse** 上的手势映射成键盘上的某一个键。
> 默认：在鼠标表面**画一个圈 → 发送右侧 Option 键**，用来便捷地开关微信语音输入。
> 你也可以在图形界面里**自定义多个「手势 → 按键」映射**。

English summary: Map gestures drawn on an Apple Magic Mouse to keyboard keys (e.g. draw a circle → send Right Option) to toggle WeChat voice input. Comes with a menu-bar GUI for managing multiple customizable gesture→key bindings.

---

## 功能特性

- 🖱️ 画圈、左右上下滑动、点按、双击 —— 多种内置手势。
- 🔑 每个手势可单独映射到任意按键（Option / 空格 / 回车 / Control / Command / Shift，左/右区分）。
- 🧩 **自定义手势**：在设置里随时新增 / 删除「手势 → 按键」映射，可同时启用多个。
- 🖥️ 菜单栏（menu bar）常驻图标 🖱️，点开即可「设置 / 测试触发 / 重新连接 / 退出」。
- 🎚️ 灵敏度可调：闭合容差、圆度要求两个滑块，误触与漏触自己权衡。
- 🔧 自带「测试触发」按钮，一键验证按键是否真的发出去；内置「打开系统权限设置」「请求辅助功能权限」入口。
- 🐞 调试模式：把每一帧原始触控坐标打印到终端，方便排查。

---

## 原理

- 读取鼠标表面触控数据走的是 macOS **私有框架 `MultitouchSupport.framework`**，在运行时用 `dlopen` / `dlsym` 动态加载（不依赖头文件、不链接），所以即使系统升级改变了框架内部布局也能扛住。
- 不同 macOS 版本上「触控点坐标」在结构体里的字节偏移不固定，引擎会**自动尝试多种偏移量**，只在取到的坐标看起来是归一化 [0,1] 时才采用，从而天然过滤掉错误偏移的干扰。
- 单指笔画结束时，引擎提取归一化坐标并判定手势类型（画圈 / 滑动 / 点按 / 双击），命中启用中的映射就通过 **CoreGraphics** 向系统发送一次键盘事件。
- 默认只连接**外部设备**（Magic Mouse）；内置触控板会被跳过。

---

## 系统要求

- 一台 Mac + 已连接的 **Apple Magic Mouse**。
- macOS 11 (Big Sur) 或更新版本。
- 已安装 **Xcode 命令行工具**：`xcode-select --install`（仅编译时需要）。
- 需要在「系统设置 → 隐私与安全性」里手动授权（见下）。

---

## 快速开始

```sh
cd "本项目目录"
sh build.sh
```

构建完成后：

- 图形界面版（推荐）：`open MouseGestureKey.app` 或直接双击 `MouseGestureKey.app`。
  启动后设置窗口会自动弹出，菜单栏出现 🖱️ 图标。
- 命令行版（调试用）：`./MouseGestureKey`。

---

## 权限（这一步最关键，没授权就「没反应」）

工具要**读取鼠标触控数据**并**向其他 App 发送键盘事件**，macOS 的隐私保护会拦截，必须手动授权：

1. **辅助功能 (Accessibility)** —— 把运行它的程序加进去：
   - 直接双击 `MouseGestureKey.app` → 授权 **MouseGestureKey**（或「终端 Terminal」，如果你是 `./MouseGestureKey` 命令行启动）。
   - 第一次点击「请求辅助功能权限」按钮会弹出系统授权框。
2. **输入监控 (Input Monitoring)** —— 同样把程序加进去（发送键盘事件需要）。
   点设置里的「打开系统权限设置」会直接跳到该页面。

> ⚠️ 没授权时程序不会崩溃，但要么收不到手势、要么按键发不出去。授权后**重跑一次**即可。

---

## 自定义手势（在图形界面里）

打开设置窗口 → 「手势 → 按键 映射」区域：

1. 每行是一个映射：左边选**手势类型**，中间选**要发送的按键**，右边勾选**启用**。
2. 点 **「＋ 添加手势」** 新建一条映射，可同时启用多个。
3. 点 **「删除」** 移除某条映射。
4. 改完即时保存（配置写在 `~/.mousegesturekey.json`）。

支持的手势类型：

| 手势 | 说明 |
|------|------|
| `circle` 画圈 | 鼠标表面画一个闭环圆 |
| `swipeLeft` 向左滑 | 向左拖动 |
| `swipeRight` 向右滑 | 向右拖动 |
| `swipeUp` 向上滑 | 向上拖动 |
| `swipeDown` 向下滑 | 向下拖动 |
| `tap` 点按 | 短促轻点 |
| `doubleTap` 双击 | 两次快速点按 |

> 注：当前版本的「自定义」指的是**自由组合上述手势 → 任意按键**并增删映射。
> 如果你想要「识别任意自绘形状（比如画个三角）」，那是更高级的手势形状识别，可作为后续扩展。

---

## 配置说明

配置自动保存在 `~/.mousegesturekey.json`，可用任意编辑器手动修改（GUI 里改完也会写这个文件）。

### 按键预设（GUI 下拉框里就是这些）

| 按键 | keyCode (十六进制) | keyCode (十进制) | flag |
|------|--------------------|------------------|------|
| 右侧 Option | 0x3D | 61 | `rightOption` |
| 左侧 Option  | 0x3A | 58 | `leftOption` |
| 空格 Space   | 0x31 | 49 | `""` |
| 回车 Return  | 0x24 | 36 | `""` |
| 右侧 Control | 0x3E | 62 | `rightControl` |
| 左侧 Control | 0x3B | 59 | `control` |
| Command ⌘   | 0x37 | 55 | `command` |
| 右侧 Shift ⇧ | 0x3C | 60 | `rightShift` |

### 完整配置示例（`mousegesturekey.sample.json`）

```json
{
  "bindings": [
    { "gesture": "circle",     "keyCode": 61, "flag": "rightOption", "enabled": true  },
    { "gesture": "swipeRight", "keyCode": 49, "flag": "",           "enabled": false },
    { "gesture": "tap",        "keyCode": 55, "flag": "command",    "enabled": false }
  ],
  "debug": false,
  "holdSeconds": 0,
  "minAngularCoverage": 3.8,
  "maxRadiusStd": 0.6,
  "maxClosure": 0.45
}
```

字段含义：

- `bindings`：手势 → 按键映射列表。
  - `gesture`：见上表的手势类型字符串。
  - `keyCode`：macOS 虚拟键码（见上表）。
  - `flag`：修饰键家族（`rightOption` / `leftOption` / `rightControl` / `control` / `rightShift` / `shift` / `command` / 留空 `""`）。
  - `enabled`：是否启用该条映射。
- `debug`：调试模式（终端打印原始触控帧）。
- `holdSeconds`：按住时长（秒）。`0` = 瞬时点按；`>0` = 按下后保持该时长再松开（适合「按住说话」类的键）。
- `minAngularCoverage`：画圈时至少要扫过的角度（弧度），越大越不容易误判。
- `maxRadiusStd`：圆半径允许的变化（标准差/均值），越大越宽松。
- `maxClosure`：圈没画闭合时，终点离起点的容差（占平均半径的比例），越大越容易判定为「圈」。

---

## 编译

```sh
sh build.sh
```

`build.sh` 会同时产出：

- `MouseGestureKey`：命令行版本（`./MouseGestureKey --selftest` 可跑内置自测）。
- `MouseGestureKey.app`：图形界面版本（已做 ad-hoc 签名，本地双击即可运行）。

> 用 Xcode 命令行工具里的 `swiftc` 编译，无需 Xcode 完整 IDE。

---

## 命令行版 & 自测

```sh
# 运行（调试时可见 FIRED 日志）
./MouseGestureKey

# 内置自测：画圈 / 半弧 / 直线 三类判定
./MouseGestureKey --selftest
```

自测会校验：完整圆圈 → 识别为 circle；半圈弧 → 不误判为 circle；直线 → 识别为 swipe。

---

## 开机自启（可选）

- **图形界面版**：系统设置 → 通用 → 登录项 (Login Items) → 把 `MouseGestureKey.app` 加入「登录时打开」。
- **命令行版**：用 `com.user.mousegesturekey.plist` 模板（把里面的路径改成你机器上 `MouseGestureKey` 的绝对路径），然后：

  ```sh
  cp com.user.mousegesturekey.plist ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/com.user.mousegesturekey.plist
  ```

  日志在 `mousegesturekey.log`。

---

## 调试 / 校准

如果画圈没反应，按这个顺序排查：

1. 看菜单栏图标 → 设置窗口「实时状态」：是否「已连接并运行」、是否授权。
2. 在设置里勾选「调试模式」，再用命令行 `./MouseGestureKey` 运行，会打印每帧：

   ```
   frame n=2 x=0.5123 y=0.4890 pts=3
   classify dur=1.02 ... sweep=6.10 std=0.05 dlast=0.02 net=... straight=...
   FIRED gesture=circle keyCode=61 flag=rightOption
   ```

   - **完全没 `frame` 输出** → 权限没给够，或鼠标没被识别成外部设备。
   - **有输出但不触发** → 看 `classify` 那行，把 `sweep / std / dlast / straight` 调一调（用设置里的灵敏度滑块，或改 `minAngularCoverage` / `maxRadiusStd` / `maxClosure`）。

---

## 开源

本仓库以 **MIT 许可证** 开源，欢迎 Issue 与 PR。

路线图中可能的能力（按需再加）：

- 任意自绘形状的手势识别（不只是预设的圈/滑/点）。
- 多点手势。
- 触发「点击屏幕某坐标」而非键盘事件。
- 更丰富的按键组合（如 按下+修饰键序列）。

---

## 局限

- 仅支持单指笔画的预设手势类型；复杂多点手势暂未实现。
- 依赖私有框架，极端情况下某个 macOS 大版本可能改接口（已用运行时加载 + 多偏移探测尽量降低风险）。
- 发送的是「物理按键」，需要辅助功能 + 输入监控两项权限。
