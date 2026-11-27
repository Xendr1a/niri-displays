--!nonstrict
-- 控制中心快捷入口：在「只留笔记本 / 只留外接 / 双屏并排」之间循环。
-- 与面板按钮走同一条服务端链路：写 preset_kind + bump preset_requested。

local snapshot = noctalia.state.get("display_snapshot") or { displays = {} }
local presetStatus = noctalia.state.get("preset_status") or {}

local function isBuiltinPort(port)
  return type(port) == "string"
    and (port:match("^eDP%-") ~= nil
      or port:match("^LVDS%-") ~= nil
      or port:match("^DSI%-") ~= nil)
end

local function collectState()
  local hasBuiltin, hasExternal = false, false
  local builtinEnabled, externalEnabled = false, false
  for _, display in ipairs(snapshot.displays or {}) do
    if isBuiltinPort(display.port) then
      hasBuiltin = true
      builtinEnabled = builtinEnabled or display.enabled
    else
      hasExternal = true
      externalEnabled = externalEnabled or display.enabled
    end
  end
  return hasBuiltin, hasExternal, builtinEnabled, externalEnabled
end

local function nextPreset()
  -- refreshing 不算忙：只有首屏加载/出错或预设进行中才禁用瓷砖，否则每轮刷新都会闪灰。
  if (snapshot.status ~= "ok" and snapshot.status ~= "refreshing") or presetStatus.pending then
    return nil
  end
  local hasBuiltin, hasExternal, builtinEnabled, externalEnabled = collectState()
  local available = {}
  if hasBuiltin then
    table.insert(available, "laptop")
  end
  if hasExternal then
    table.insert(available, "external")
  end
  if hasBuiltin and hasExternal then
    table.insert(available, "dual")
  end
  if #available == 0 then
    return nil
  end

  local current = nil
  if builtinEnabled and externalEnabled then
    current = "dual"
  elseif builtinEnabled then
    current = "laptop"
  elseif externalEnabled then
    current = "external"
  end

  for i, kind in ipairs(available) do
    if kind == current then
      return available[i % #available + 1]
    end
  end
  return available[1]
end

local function render()
  local _, _, builtinEnabled, externalEnabled = collectState()
  shortcut.setLabel(noctalia.tr("shortcut.preset_cycle.label"))
  shortcut.setIcon("layout-columns")
  shortcut.setActive(builtinEnabled and externalEnabled)
  shortcut.setEnabled(nextPreset() ~= nil)
end

noctalia.state.watch("display_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.state.watch("preset_status", function(value)
  presetStatus = value or {}
  render()
end)

render()

function onClick()
  local kind = nextPreset()
  if kind ~= nil then
    noctalia.state.set("preset_kind", kind)
    noctalia.state.set("preset_requested", (noctalia.state.get("preset_requested") or 0) + 1)
  end
end
