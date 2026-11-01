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

工具要**读取鼠标触控数据**并**向其他 App 发送键盘事件**，macOS 的隐私保护会拦截，必须手动授权**两项**：

> ⚠️ **最常见的误解**：以为"打开系统设置页面"就完事了——其实**必须点 ＋ 把本 App 加进列表并打勾**，而且**改完要退出 App 重新打开**权限才生效。只打开页面是没用的。

> 🔁 **授权后务必「退出本 App 再重新打开」**：macOS 的辅助功能 / 输入监控权限只对「新启动的进程」生效。如果你是在 App 已经运行的时候去系统设置里勾的权限，当前这个运行中的进程仍然读不到手势（设置页「已捕获帧数」会一直为 0），必须退出重开才生效。重开后看「实时状态」的「设备」一行应显示已连接、「已捕获帧数」在你滑动手指时会上涨。

### 步骤（图形界面版）

1. 打开本 App 的设置窗口，点 **「打开辅助功能设置」** 按钮（会直接跳到对应的系统设置页）。
2. 在「系统设置 → 隐私与安全性 → **辅助功能**」里，点左下角的 **＋** 号。
3. 在弹出的文件框里选中 `MouseGestureKey.app`，确认它出现在列表里，并且**右边的开关是打开**的。
   - 找不到 App？先点设置窗口里的 **「在访达中显示本 App」**，把 App 选中后**直接拖进刚才的 ＋ 文件框**即可；
   - 或者把 `MouseGestureKey.app` 先**拖进「应用程序(/Applications)」文件夹**，以后在这里更好找。
4. 回到上一级，进入 **输入监控**，用同样的方法（＋ 加入并打勾）把 `MouseGestureKey.app` 也加进去。
5. **菜单栏点 🖱️ → 退出**，再重新双击打开 `MouseGestureKey.app`。
6. 回到设置窗口看「实时状态」：辅助功能应显示"已授权 ✅"。

> 命令行版（`./MouseGestureKey`）则把 **终端 Terminal** 加进上述两个权限列表即可。

> 没授权时程序**不会崩溃**，但要么收不到手势、要么按键发不出去。按上面走完一遍就好。

> 📌 **为什么 App 里「输入监控」不显示绿色对号？** macOS **不向 App 提供读取「输入监控」授权状态的接口**（辅助功能有、输入监控没有），所以 App 无法自动显示对号——这**不代表没授权**。判断方法：① 以「系统设置」里的勾为准；② 看设置窗口「已捕获帧数」是否在动（动 = 手势读取正常）；③ 点「测试触发」验证按键是否真的发出去。

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
