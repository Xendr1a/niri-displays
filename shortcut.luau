--!nonstrict
-- 控制中心快捷开关：点一下直接打开显示器面板。
-- 与控制中心其它瓷砖一样，靠 noctalia.state 里的快照决定高亮状态。

local PANEL_ID = "xendr1a/niri-displays:panel"
local snapshot = noctalia.state.get("display_snapshot") or { displays = {} }

local function enabledCount()
  local count = 0
  for _, display in ipairs(snapshot.displays or {}) do
    if display.enabled then
      count += 1
    end
  end
  return count
end

local function render()
  local count = enabledCount()
  shortcut.setLabel(noctalia.tr("shortcut.label"))
  shortcut.setIcon("device-desktop")
  -- 多屏时点亮，单屏时灰着，一眼能看出当前是不是在投副屏
  shortcut.setActive(count > 1)
  shortcut.setEnabled(true)
end

noctalia.state.watch("display_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
