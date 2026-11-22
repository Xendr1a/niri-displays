# Niri Displays

Inspect connected outputs and make temporary display changes directly from Noctalia. The plugin uses Niri's IPC to expose per-output enable/disable, resolution, refresh-rate, scale, rotation (transform), position, and focused-output state.

## Screenshots

Default panel — connection behavior, presets, and per-output controls:

![Panel](images/panel.png)

Expanded layout editor with the output map:

![Layout](images/panel-layout.png)

Bar widget (the monitor glyph between volume and battery):

![Bar widget](images/bar-widget.png)

## Plugin

| Field | Value |
| --- | --- |
| ID | `xendr1a/niri-displays` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `displays`; shortcuts: `shortcut`, `preset-cycle` |

## Requirements

- Noctalia plugin API 9 or newer (used for closure-backed display controls).
- The `niri` executable on `PATH`, with a running Niri session and `NIRI_SOCKET` available to Noctalia.
- A Niri version that supports the `niri msg output` IPC commands.

## Usage

Enable `xendr1a/niri-displays` in **Settings → Plugins**, then add the `bar` entry from **Settings → Bar → Widgets**. The `displays` service starts automatically, watches Noctalia's output-change hook, and uses slow polling as a recovery fallback.

Click the bar widget to open the `panel` entry. Each connected output shows its connector, make/model, focused state, current mode, refresh rate, scale, rotation, and position. Select a mode, refresh rate, or rotation reported by Niri, adjust the position, or drag the scale slider, to apply a temporary change.

The **Enabled** toggle at the top of each card runs `niri msg output <port> on` or `off`. A disabled output stays listed with its controls greyed out, so it can be switched back on at any time. The last enabled output is protected: its toggle is locked and labelled "Only display" so a session can never be left without a screen.

The star button marks an output as the primary screen. If that output is enabled, the plugin immediately runs `niri msg action focus-monitor <port>`; if it is disabled, the choice is only written to the persisted layout so the next startup can use it.

Open the panel without the bar widget with:

```sh
noctalia msg panel-toggle xendr1a/niri-displays:panel
```

### Scale presets

Each `scale_presets` item uses one of these forms:

```text
WIDTHxHEIGHT=SCALE
PORT:WIDTHxHEIGHT=SCALE
```

For example:

```text
3840x2160=1.5
2560x1440=1
DP-3:1920x1080=1.25
```

A port-specific preset wins over a global preset for the same resolution. At the same specificity, the last valid matching item wins. Presets match the resolution exactly and are applied after a resolution change, including changes detected outside the panel; refresh-rate-only changes do not reapply them.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `scale_presets` | `string_list` | empty | Global or per-connector `resolution=scale` mappings applied after matching resolution changes. |
| `refresh_interval` | `int` | `30` seconds | Recovery polling interval, limited to 5–300 seconds; normal output updates are event-driven. |
| `glyph` | `glyph` | `device-desktop` | Glyph used by this bar-widget instance. |
| `show_resolution` | `bool` | `true` | Shows the focused connector and resolution beside the bar glyph; disable for icon-only display. |

## IPC

The `displays` service accepts these events:

```sh
# Query Niri for a fresh output snapshot.
noctalia msg plugin xendr1a/niri-displays:displays all refresh

# Write the normalized output snapshot to the Noctalia log.
noctalia msg plugin xendr1a/niri-displays:displays all dump

# Apply a layout preset without opening the panel.
noctalia msg plugin xendr1a/niri-displays:displays all preset laptop
noctalia msg plugin xendr1a/niri-displays:displays all preset external
noctalia msg plugin xendr1a/niri-displays:displays all preset dual
noctalia msg plugin xendr1a/niri-displays:displays all preset all
```

The optional `preset-cycle` shortcut cycles through the available presets in the control center. It skips presets that need a missing builtin or external output, and never turns off the last enabled screen.

## 连接行为（接上外接屏时）

面板顶部有一块「连接行为」，两个开关都是接外接屏时的默认动作，跨开机生效，存在
`~/.config/niri/displays-policy.json`（和 `outputs.kdl` 同目录）：

| 开关 | 默认 | 行为 |
| --- | --- | --- |
| 接上外接屏时焦点跟过去 | 开 | 开机时、或插上外接屏时，把焦点移到外接屏一次；之后手动切回内屏不会被抢回 |
| 接上外接屏时关闭笔记本内屏 | 关 | 外接屏亮着时执行 `niri msg output eDP-1 off`；外接屏拔掉后自动打开内屏 |

- 只在「亮着的外接屏集合」发生变化时执行一次（开机第一次快照也算一次），所以手动把
  内屏再打开、或把焦点切回笔记本，都不会被策略反复覆盖。
- 熄内屏永远不会关掉最后一块亮着的输出；拔掉外接屏后内屏会自动恢复。
- 开机焦点还有静态着一层：`outputs.kdl` 里 `focus-at-startup` 的书写顺序就是优先级
  （niri 取第一个已连接的）。插件把外接屏写在前面、内置屏写在后面，所以「接着显示器
  开机」落在显示器上，「只开笔记本」落在笔记本上，不需要等面板服务起来。

命令行等价操作（脚本化验证用）：

```sh
# 查看当前策略
noctalia msg plugin xendr1a/niri-displays:displays all policy
# 改策略（等价于面板拨开关，会落盘并立刻重新执行一次）
noctalia msg plugin xendr1a/niri-displays:displays all policy '{"focus_external":true,"internal_off_with_external":true}'
```

## 面板交互（本插件的做法）

- 分辨率 / 刷新率：平时只显示当前值（一个带 ⌄、右边缘对齐的宽按钮），点一下就地展开整列选项，
  点一项立刻生效并收起；再点当前值收起。不用悬停展开——面板重新打开时指针恰好停在字段上会自己弹开，很吵。
- 旋转：`‹ 角度 ›` 调节器逐档转 90°，镜像单独一个按钮，比铺 8 个选项省一行。
- 卡片整行宽；展开时标题只写型号与端口（当前值下面字段已经写了），折叠时才补一行 `2560×1600 @ 150%`。
- 布局图下方有一排端口按钮，点一下就把布局编辑目标切到那块屏；卡片折叠状态和布局区展开状态会在面板重开之间保留。
- 面板不自己上强调色：标题、编号、当前焦点徽标、卡片边框都用 `on_surface` / `on_surface_variant`，
  紫色只会来自主题调色板本身（开关、滑块的 primary）。

## Verification

- 布局：`niri validate` + `niri msg -j outputs`（`writeOutputsFile` 写完会自己跑一次
  `niri validate`，失败整份回滚到 `.bak`）。
- 焦点：`niri msg action focus-monitor <port>` 是策略用的原语，单独执行可以验证端口名。
- 面板：`noctalia plugins lint .`，日志 `~/.cache/noctalia/noctalia.log` 里不应出现
  `plugin translation key ... not found`（译文是在插件 enable 时载入的，改完
  `translations/*.json` 要 disable + enable 才刷新）。

## Notes

- Discovery spawns `niri msg --json outputs` and `niri msg --json focused-output`. Changes spawn `niri msg output <connector> mode ...`, `niri msg output <connector> scale ...`, `niri msg output <connector> transform ...`, or `niri msg output <connector> position ...`.
- Niri intentionally does not persist these IPC changes to `config.kdl`. A Niri restart or a later configuration reload can restore configured values; keep permanent defaults in your Niri configuration.
- A matching scale preset can change output scale automatically when the service starts, reloads, detects a resolution change, or receives a settings change.
- The plugin does not write files or make network requests. Command errors are shown without discarding the last successful in-memory output snapshot.
