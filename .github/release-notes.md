首个公开版本 · First public release

**为什么做它**：平时用语音输入法打字，每次开始 / 停止语音都要先按一下键，手又得离开鼠标去够键盘——一会儿按键、一会儿挪鼠标，来回切换很别扭。既然手本来就在鼠标上，那就干脆用鼠标画个手势把键按了。于是有了 GlyphKey：**只用鼠标，就能完成「按键」这一步**。

**它是什么**：在 Apple Magic Mouse / 触控板上画手势，映射成任意按键。默认「画一个圈 → 右侧 Option」，用来一键开关微信语音输入。

**亮点**
- 画圈 / 上下左右滑 / 点按 / 双击
- 任意按键映射（Option / Space / Return / Control / Command / Shift，区分左右）
- 菜单栏常驻 + 图形化设置，灵敏度可调、防误触
- 开机自动启动
- 借鉴 $1 Unistroke Recognizer 的方向一致性判定

**安装**
1. 下载 `GlyphKey-*.zip`，解压得到 `GlyphKey.app`
2. 拖进 `/Applications`
3. 首次打开若被拦截：右键 → 打开（或「系统设置 → 隐私与安全性 → 仍要打开」）
4. 在「辅助功能」「输入监控」里授权后重启 App

> 本包为 Apple 芯片（arm64）版本。Intel 用户可克隆仓库后 `sh build.sh` 自行构建。

作者 / Author：@ph4ble — https://x.com/ph4ble
