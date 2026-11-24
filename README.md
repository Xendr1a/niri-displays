# Niri 显示器（Niri Displays）

在 Noctalia 中查看和调整 Niri 的显示器。支持开关输出、分辨率、刷新率、缩放、旋转、可变刷新率（VRR）、屏幕位置和启动主屏。布局可以写入 Niri 的配置，显示器的开关状态只对当前会话生效。

| 项目 | 值 |
| --- | --- |
| 插件 ID | `xendr1a/niri-displays` |
| 入口 | 栏组件 `bar`，面板 `panel`，服务 `displays` |
| 控制中心快捷方式 | `shortcut` 打开面板，`preset-cycle` 循环切换布局 |

## 截图

显示器面板，包含连接行为、布局预设和各输出的设置。

![显示器面板](images/panel.png)

展开屏幕布局，查看各显示器的相对位置。

![布局编辑器](images/panel-layout.png)

状态栏上的显示器图标位于音量和电池之间。

![状态栏组件](images/bar-widget.png)

## 启用和配置

需要 Noctalia v5.4.0 或更新版本，插件声明的 API 版本为 42。Noctalia 需要能通过 `PATH` 找到支持 `niri msg output` 的 Niri，并通过 `NIRI_SOCKET` 连接到当前 Niri 会话。持久化布局需要支持 KDL `include` 的 Niri 25.11 或更新版本。[Noctalia 插件 API](https://docs.noctalia.dev/noctalia/v5.4.0/plugins/development/plugin-api/)，[Niri 配置引用](https://niri-wm.github.io/niri/Configuration%3A-Include.html)

1. 在 Noctalia 的「设置 → 插件」中启用插件，再到「设置 → 栏 → 组件」添加 `bar`。也可以在控制中心添加快捷方式。
2. 如果希望重启 Niri 后恢复布局，在 Niri 的 `config.kdl` 顶层加入以下一行。相对路径以 `config.kdl` 所在目录为基准。Niri 26.04 起，`optional=true` 允许文件在首次保存前缺失。使用 Niri 25.11 时，先通过下文的 `save` 事件生成文件，再添加 `include "outputs.kdl"`。

   ```kdl
   include "outputs.kdl" optional=true
   ```

   默认将布局写到 `~/.config/niri/outputs.kdl`。如果 Niri 使用其他配置目录，请在插件的 `outputs_file` 中填写专用文件的绝对路径，并让 `include` 指向同一文件。如果 `include` 使用符号链接，请将 `outputs_file` 指向实际文件。插件保存时会替换指定路径上的文件。已有 `output` 配置时，请备份并检查同一输出是否重复定义。Niri 会原样载入各 `output` 条目，插件只写入下文列出的字段。[Niri 输出配置](https://niri-wm.github.io/niri/Configuration%3A-Outputs.html)
3. 运行 `niri validate` 检查配置。修改布局或发送下文的 `save` 事件后，检查 `outputs.kdl` 是否生成，再校验一次完整配置。

点击栏图标打开面板，也可以直接运行：

```sh
noctalia msg panel-toggle xendr1a/niri-displays:panel
```

## 显示器和布局

- 每张卡片对应一个输出，显示端口、型号和当前焦点。支持的分辨率和刷新率由 Niri 提供。只有支持 VRR 的输出才可切换 VRR。
- 「启用」开关改变当前会话中的输出状态。重启 Niri，或 Niri 重新载入有变动的输出配置时，这些临时设置可能会被重置。已关闭但仍连接的显示器保留在列表里，方便重新打开。最后一块亮着的显示器无法通过此开关关闭。[Niri 输出 IPC](https://niri-wm.github.io/niri/niri_ipc/enum.Request.html#variant.Output)
- 点击星标可设定启动主屏。选中已启用的输出时，面板还会立即将焦点移过去。已关闭的输出会在下次启动时按生成的 Niri 配置处理。
- 「屏幕布局」可以预览显示器的相对位置，选择要移动的输出并设置方向和偏移。缩放、分辨率或旋转改变屏幕的逻辑尺寸时，插件会尝试调整相邻屏幕，保留边缘间距。
- 面板提供「全部打开」「只留笔记本」「只留外接」和「双屏并排」。切换到单类输出时，先打开目标显示器，再关闭其余显示器。双屏并排会把一块外接屏放到左边，将内屏移到它右边。
- 控制中心的 `preset-cycle` 在「只留笔记本」「只留外接」和「双屏并排」之间切换，并跳过不具备相应输出的预设。

布局文件记录模式、缩放、旋转、位置、VRR 和启动焦点。插件会尝试保留已关闭或断开的输出此前保存的布局。插件先用 Niri 校验生成的布局片段，再更新专用文件并保留上一版 `.bak`。已有的手写布局文件会被保留，请为插件另选路径。写入或校验失败时可在 Noctalia 中查看错误。输出的开关状态由当前会话和连接策略决定。

### 分辨率缩放预设

`scale_presets` 每行接受 `宽x高=缩放`，也可以用 `端口:宽x高=缩放` 为某个输出单独设置。

```text
3840x2160=1.5
2560x1440=1
DP-3:1920x1080=1.25
```

端口专用规则优先。同一优先级下，最后一条有效匹配生效。插件会在启动、修改插件设置或检测到分辨率变化时检查规则。只改刷新率时不会重新应用预设。

### 连接行为

面板顶部的「连接行为」保存在与 `outputs_file` 同目录的 `displays-policy.json` 中，重启后继续生效。

| 选项 | 默认 | 行为 |
| --- | --- | --- |
| 接上外接屏时焦点跟过去 | 开 | 启动服务或接入外接屏时，尝试把焦点从内屏移到外接屏。 |
| 接上外接屏时关闭笔记本内屏 | 关 | 外接屏亮着时关闭内屏。外接屏全断开后，自动恢复内屏。 |

策略在首次读取输出和可用外屏发生变化时执行。外屏保持连接期间，可以手动把焦点切回内屏或重新打开内屏。Niri 启动时先按 `outputs.kdl` 内的 `focus-at-startup` 选定焦点，Noctalia 服务启动后再应用连接策略。

## 设置

| 设置 | 类型 | 默认 | 用途 |
| --- | --- | --- | --- |
| `outputs_file` | `string` | `~/.config/niri/outputs.kdl` | 插件生成的布局文件，应与 Niri 的 `include` 指向同一文件。 |
| `scale_presets` | `string_list` | 空 | 依据分辨率和可选端口应用缩放。 |
| `refresh_interval` | `int` | 30 秒 | 兜底轮询间隔，范围为 5–300 秒。通常由 Noctalia 的输出事件刷新。 |
| `glyph` | `glyph` | `device-desktop` | 当前栏组件的图标。 |
| `show_resolution` | `bool` | 关 | 开启后在图标旁显示当前聚焦输出的端口和分辨率。 |

## IPC

向 `displays` 服务发送事件，无需打开面板。

```sh
# 刷新输出状态，或者把当前快照写入 Noctalia 日志
noctalia msg plugin xendr1a/niri-displays:displays all refresh
noctalia msg plugin xendr1a/niri-displays:displays all dump

# 保存布局，或将已连接的输出设为启动主屏
noctalia msg plugin xendr1a/niri-displays:displays all save
noctalia msg plugin xendr1a/niri-displays:displays all primary DP-1

# 应用布局预设
noctalia msg plugin xendr1a/niri-displays:displays all preset laptop
noctalia msg plugin xendr1a/niri-displays:displays all preset external
noctalia msg plugin xendr1a/niri-displays:displays all preset dual
noctalia msg plugin xendr1a/niri-displays:displays all preset all

# 将当前连接策略写入日志，或更新并应用策略
noctalia msg plugin xendr1a/niri-displays:displays all policy
noctalia msg plugin xendr1a/niri-displays:displays all policy '{"focus_external":true,"internal_off_with_external":true}'
```

`primary` 设置启动主屏。若只需要切换当前焦点，可以运行 `niri msg action focus-monitor DP-1`。请将示例的 `DP-1` 替换为实际输出端口。

## 验证

- 在插件目录运行 `noctalia plugins lint .` 检查插件清单与设置。
- 运行 `niri validate` 校验完整的 Niri 配置和其中的 `include`。运行 `niri msg --json outputs` 查看当前输出状态，运行 `niri msg --json focused-output` 查看当前焦点。
- 如需排查执行或翻译问题，查看 Noctalia 日志。修改 `translations/*.json` 后，重新启用插件以重新载入译文。
