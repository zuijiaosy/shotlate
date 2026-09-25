# AGENTS.md

写给在这个仓库里工作的 AI 编码代理（Claude Code、Codex 等）的说明：常用命令、整体结构、产品取舍和容易踩的坑。README 面向用户，这里只写改代码时需要知道、但从单个文件看不出来的东西。

## 产品原则：小而精

Shotlate（原名 Snap）是 macOS 菜单栏截图工具，核心路径只有：**截图 → 标注 → 复制 / 保存 / 贴图 / 识别 / 翻译**，外加长截图和扫码。项目刻意从“大而全”精简过，**判断一个功能时先问要不要做，而不是怎么做**。

以下功能是有意删掉的，没有用户明确要求不要加回来：超级截图、界面元素识别、比例锁定 / 输入尺寸、截取鼠标指针、刷新截图、截图历史、椭圆 / 直线 / 折线 / 记号笔 / 橡皮擦、不透明度调节、智能打码、OCR 表格 / 代码模式、打印、分享、美化背景 / 圆角 / 阴影、文件名模板、复制为文件、自动保存、音效、贴图分组 / Solo / 旋转翻转 / 灰度反色 / 缩略图 / 拖入替换 / 多选 / 吸附 / 鼠标穿透 / 恢复关闭 / 退出后恢复、白板、屏幕触发角、自定义快捷键命令、`snap://` 自动化和命令行、忽略应用、长截图自动滚动、剪贴板贴文字 / 色卡。

已经定下来的交互（改之前先确认）：

- 工具栏只有图标，没有快捷键角标和分隔线（仿 iShot）。指针停留 500 毫秒后弹出悬停卡片，显示名称和快捷键；卡片上点按键可以改单键快捷键，冲突时两个按钮互换。
- 7 个标注工具默认快捷键是 `1`–`7`（矩形、箭头、画笔、马赛克、放大镜、文字、序号），`X` 是 OCR，`Y` 翻译，`T` 贴图，`S` 长截图；撤销 `⌘Z`、退出 `Esc`、保存 `⌘S`、完成 `↩` 不能改。工具栏上没有重做按钮，只保留 `⇧⌘Z`。
- 序号放下后在右侧直接打开文字输入（说明文字）；下一次点击保留文字并放下一个序号；不输入文字时只保留序号。
- OCR 只做纯文本识别，结果显示在可编辑面板里，**不会自动复制**，点「复制」按钮才复制。
- 设置窗口左侧是菜单（快捷键 / 保存 / 翻译 / 通用），**没有保存按钮**，每项改动立即写入。
- 默认保存到 `~/Downloads`。
- 界面文案、README、提交信息用中文；代码注释用英文，风格简短，写“为什么”。

## 常用命令

只需要 Command Line Tools，不需要 Xcode。

```bash
swift build                                   # debug 构建，产物 .build/debug/Shotlate
scripts/test.sh                               # 单元测试（Swift Testing；脚本补上了 CLT 下 Testing.framework 的路径）
scripts/test.sh --filter StitcherTests        # 只跑一个测试组或测试
.build/debug/Shotlate --check all [输出目录]   # AppKit 自检，逐条 PASS/FAIL，失败时退出码非零
.build/debug/Shotlate --check ocr             # 只跑一项；名字见 FeatureChecks.checks
.build/debug/Shotlate --ui-demo bg.png out/   # 离屏驱动截图界面，每一步输出一张 PNG
.build/debug/Shotlate --translate-image in.png out.png --scale 2   # 不开界面检查 OCR 和译文排版（没 Key 用占位译文）
.build/debug/Shotlate --scroll-demo long.png  # 长截图端到端（需要终端有屏幕录制权限）
scripts/build-app.sh                          # 生成 build/Shotlate.app，有 Apple Development 证书时自动签名
ARCHS="arm64 x86_64" scripts/build-app.sh     # 通用二进制
scripts/make-dmg.sh 0.1.9                     # build/Shotlate-0.1.9.dmg
```

改完代码的标准验证：`swift build` 没有警告 → `scripts/test.sh` → `.build/debug/Shotlate --check all`。改了界面时，看一眼 `--check` 输出目录里的 PNG（比如 `toolbar-hover.png`、`settings-*.png`、`ocr.png`）。

更新本机安装的应用（用户经常要求“更新本地客户端”）：

```bash
scripts/build-app.sh
osascript -e 'quit app id "app.shotlate.Shotlate"'; pkill -f "Shotlate.app/Contents/MacOS/Shotlate"
rm -rf /Applications/Shotlate.app && ditto build/Shotlate.app /Applications/Shotlate.app && open /Applications/Shotlate.app
```

## 结构

```
Sources/ShotlateCore/   不依赖 AppKit 的纯逻辑，有单元测试：Vision 坐标换算与段落合并（TextBlocks）、取色（ColorSampling）、
                        翻译接口与缓存（Translator）、长截图拼接（ScrollStitcher）、贴图文字选择（TextSelection）
Sources/Shotlate/       菜单栏应用
Tests/ShotlateCoreTests 单元测试（只测 ShotlateCore）
Resources/              Info.plist、图标；scripts/ 构建、打包、测试、生成发布说明
docs/images/            README 用的动图和截图
```

跨文件才看得出的关系：

- **main.swift → DevTools.runIfRequested()**：命令行参数（`--check`、`--ui-demo`、`--translate-image`、`--scroll-demo`、`--stitch-diagnose`）在这里分流，没有参数才启动菜单栏应用（AppDelegate）。注意参数必须放在第一位，否则会当成正常启动挂住。
- **一次截图 = CaptureSession + 每块屏幕一个 CaptureView**。CaptureRootView 底层是冻结的截图 layer，上面是透明的 CaptureView，所以鼠标移动不会重绘截图。选区、标注、撤销、文字编辑、键盘分发、工具栏布局都在 CaptureView 里（最大的文件）。同一时刻只有一个 view 拥有选区（`CaptureSession.canInteract`）。
- **贴图再标注**复用同一套截图界面：`CaptureSession.beginPinEdit` 以 `.pinEdit` 模式把贴图画在透明画布上，完成后把结果写回 PinWindow。
- **ContentRenderer**（Annotation.swift）同时用于屏幕上的绘制和 Exporter 导出，保证导出的图和屏幕上看到的一致。标注模型是 `AnnotationItem` + `Shape`；每种工具的颜色、粗细、样式在 `StyleMemory`（CaptureView.swift 顶部）里按工具记忆，存在 UserDefaults。
- **Chrome.swift**：工具栏 `ToolbarView`、悬停卡片 `HoverCardView`、单键快捷键 `ToolbarKeys`（UserDefaults `toolbar.keys`，只存改过的）、样式条、选区上方的尺寸条、OCR 结果面板。`ToolbarAction.action(forKey:)` 决定单键按下时触发哪个按钮。
- **Recognition.swift**：Vision 文字识别（截图的 OCR / 翻译共用一次结果，贴图文字选择走 `layout`）、译文排版 `TranslationLayout`、扫码 `CodeScanner`、贴图翻译 `ImageTranslator`。
- **Pin.swift**：`PinManager`（全部贴图、隐藏 / 显示）、`PinWindow`（缩放、透明度、翻译、复制保存）、`PinView`（拖动、文字选择、右键菜单）。
- **Settings.swift**：设置都在 UserDefaults（域 `app.shotlate.Shotlate`）；翻译 API Key 存 `~/Library/Application Support/Shotlate/api-key`（权限 600，**不用钥匙串**，因为每次重新签名都会弹密码框）。未打包运行（`.build/debug/Shotlate`）时 Key 只读环境变量 `DEEPSEEK_API_KEY`，从不碰真实配置。
- **SettingsWindow.swift**：`SettingsModel` 的每个属性 `didSet` 立即写入 Settings；改全局快捷键会发 `Settings.didChange`，AppDelegate 重新注册（HotKey.swift，Carbon，不需要辅助功能权限）。
- **FeatureChecks.swift + CaptureHarness.swift**：离屏窗口加模拟事件的自检。未打包运行时，开始前会清空本进程的 UserDefaults 域，保证互不影响。新增交互功能时在这里加对应的检查，也就是用户说的“自检”。

## 发布与仓库

- GitHub：`zuijiaosy/shotlate`。本地分支 `master` 跟踪 `origin/main`，推送用 `git push origin HEAD:main`。
- **推送到 `main` 会自动发版**（`.github/workflows/release.yml`）：跑测试 → 构建通用版 → DMG → GitHub Release。版本号的主、次版本取自 Info.plist，补丁号在上一个同系列标签上加一。只改文档的提交在信息里写 `[skip release]`。**提交和推送都要等用户明确要求**。
- 提交信息用中文 conventional commits（`feat:` / `fix:` / `docs:` …）；正文里的 `- ` 列表会被 `scripts/release-notes.sh` 收进发布说明，写成给用户看的变化；结尾加 `Co-Authored-By: Claude <noreply@anthropic.com>`。
- 可选上传到 Cloudflare R2：仓库配好 Secrets `CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID` 和 Variable `R2_BUCKET` 后，每次发布同时上传 `Shotlate-<版本>.dmg` 和 `Shotlate-latest.dmg`；没配时自动跳过（目前没配）。
- 默认 ad-hoc 签名；屏幕录制权限和签名、Bundle ID 绑定，改 Bundle ID 或签名后需要重新授权。

## 官网

另一个目录：`/Users/lin/super.engineering/projects/snap-web`（TanStack Start，预渲染成静态页面；这个目录目前没有 git 提交和远程仓库）。

- 托管在 Cloudflare **Pages** 的 `shotlate` 项目，地址 `https://shotlate.pages.dev`。部署用 `pnpm run deploy`（`wrangler pages deploy --branch main`）。不要再用 workers.dev：那个地址会带出账号子域，旧的 Worker 已经删除。
- 下载按钮默认跳到 `https://github.com/zuijiaosy/shotlate/releases/latest`；构建时设置 `VITE_DMG_URL=https://<R2 公开域名>/Shotlate-latest.dmg` 就改成直接从 R2 下载。
- 页面文字在 `src/routes/*.tsx`、`src/content/manual.ts`、`src/content/faq.ts`，功能有变化时和本仓库 README 一起更新。
- `public/shots/` 的截图和视频由应用本身渲染：`SHOTLATE_APP=<本仓库>/build/Shotlate.app pnpm assets`（先 `scripts/build-app.sh`）。UI 演示步骤的文件名（`--ui-demo` 的 `NN-name.png`）被 `scripts/assets/build-assets.sh` 引用，改 UIDemo 的步骤时同步改脚本。
- README 顶部的 `docs/images/capture-flow.gif` 由官网的 `capture-flow.mp4` 转成；`settings.gif` 来自 `--check hotkeys` 输出的 `settings-*.png`。

## 容易踩的坑

- 同一个可执行文件第一次调用 Vision 要编译模型，可能几十秒；应用启动时会预热。Vision 的识别结果偶尔会有波动（曾经有一阵同一张图少识别几行，后来自己恢复了），怀疑识别有问题时多跑几次、对比旧版本，再改代码。
- `--scroll-demo` 拍的是屏幕上的真实区域：演示窗口没在最前面时，会拍到用户屏幕上的其他内容。生成的图一定要先看一眼，不要直接发布（素材脚本已经会拒绝没拼接成功的结果）。
- `ToolbarKeys` 和其他 UserDefaults 状态在打包的 App 和 `.build/debug` 之间不共享（域不同）；离屏演示用打包的 App 跑时，会带上用户本机的样式偏好。
- 快捷键卡片、样式条、OCR 面板都是 CaptureView 的子视图，位置在 `layoutChrome()` 里统一计算；选区下方放不下时工具栏会竖排，改布局后跑 `--check toolbar-placement`。
- 在 macOS 上，这台机器 shell 里的 `grep` 有别名，输出可能被吞；检查构建产物时可以用 `/usr/bin/grep` 或 Python。
