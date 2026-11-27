--!nonstrict
-- Interactive Niri output controls. The service owns layout persistence.

local MAX_DISPLAYS = 12
local COMMAND_TIMEOUT_MS = 8000
local TRANSFORM_OPTIONS = {
  { value = "normal", label = "panel.rotation_normal" },
  { value = "90", text = "90°" },
  { value = "180", text = "180°" },
  { value = "270", text = "270°" },
  { value = "flipped", label = "panel.rotation_mirrored" },
  { value = "flipped-90", label = "panel.rotation_mirrored_angle", angle = "90°" },
  { value = "flipped-180", label = "panel.rotation_mirrored_angle", angle = "180°" },
  { value = "flipped-270", label = "panel.rotation_mirrored_angle", angle = "270°" },
}
local CENTERED_LAYOUT = { flexGrow = 1, align = "center", justify = "center", gap = 10, padding = 20 }

local snapshot = noctalia.state.get("display_snapshot") or {
  status = "loading",
  error_message = "",
  displays = {},
  updated_at = "",
}
local isOpen = false
local actionPending = false
local actionError = ""
local presetStatus = noctalia.state.get("preset_status") or {}
local scaleDraft = {}
local scaleEditing = {}
local positionDraft = {}
local lastEnabledByPort = {}
local layoutExpanded = false
local selectedPort = nil
local layoutDirection = nil
local layoutOffset = 0
local primaryPort = nil
-- 连接行为策略（服务端落盘 + 执行）：外接屏接上时的焦点与内屏去留
local policy = {
  focus_external = true,
  internal_off_with_external = false,
}
-- 卡片默认展开；点右上角箭头收起，只留「厂商 - 型号 - 端口 + 分辨率 @ 缩放」
local collapsedPorts = {}

-- 面板 UI 状态记忆：卡片折叠、布局区展开、上次选中的目标屏。
-- 只存共享 state，不落盘；面板重开和服务热重载之间保持。
local function savePanelUi()
  noctalia.state.set("display_panel_ui", {
    collapsed = collapsedPorts,
    layoutExpanded = layoutExpanded,
    selectedPort = selectedPort,
  })
end

local function loadPanelUi()
  local saved = noctalia.state.get("display_panel_ui")
  if type(saved) ~= "table" then
    return
  end
  if type(saved.collapsed) == "table" then
    collapsedPorts = saved.collapsed
  end
  if type(saved.layoutExpanded) == "boolean" then
    layoutExpanded = saved.layoutExpanded
  end
  if type(saved.selectedPort) == "string" then
    selectedPort = saved.selectedPort
  end
end

local render

local tr = noctalia.tr

local function canChangeDisplays(current, currentPreset)
  current = current or snapshot
  currentPreset = currentPreset or presetStatus
  -- refreshing 只是后台在取快照：若把它当忙，面板每轮刷新都会闪灰、期间的点击被吞。
  -- 只在首屏加载（loading/error）或真正的动作/预设进行中禁用。
  local ready = current.status == "ok" or current.status == "refreshing"
  return ready and not current.actions_pending and not actionPending and not currentPreset.pending
end

local function quoteShellArgument(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function syncFromState()
  snapshot = noctalia.state.get("display_snapshot") or snapshot
  primaryPort = noctalia.state.get("primary_port") or primaryPort
  local shared = noctalia.state.get("displays_policy")
  if type(shared) == "table" then
    policy.focus_external = shared.focus_external ~= false
    policy.internal_off_with_external = shared.internal_off_with_external == true
  end
  local presentPorts = {}
  for _, display in ipairs(snapshot.displays) do
    presentPorts[display.port] = true
    -- A re-enabled output keeps the placeholder 0,0 geometry it reported while
    -- disabled. Drop its drafts so they reseed from the values Niri just picked.
    if display.enabled and lastEnabledByPort[display.port] == false then
      scaleDraft[display.port] = nil
      scaleEditing[display.port] = nil
      positionDraft[display.port] = nil
    end
    lastEnabledByPort[display.port] = display.enabled
    if scaleDraft[display.port] == nil or (not actionPending and not scaleEditing[display.port]) then
      scaleDraft[display.port] = display.scale
    end
  end
  for port, _ in pairs(scaleDraft) do
    if presentPorts[port] ~= true then
      scaleDraft[port] = nil
      scaleEditing[port] = nil
      positionDraft[port] = nil
      lastEnabledByPort[port] = nil
    end
  end
end

local function formatRefresh(milliHz)
  local hz = milliHz / 1000
  local rounded = math.floor(hz + 0.5)
  if math.abs(hz - rounded) < 0.01 then
    return tostring(rounded) .. " Hz"
  end
  return string.format("%.3f Hz", hz)
end

local function formatScale(value)
  local text = string.format("%.4f", value)
  text = text:gsub("0+$", ""):gsub("%.$", "")
  return text
end

local function resolutionChoices(display)
  local choices = {}
  local seen = {}
  for _, mode in ipairs(display.modes) do
    local key = tostring(mode.width) .. "x" .. tostring(mode.height)
    if not seen[key] then
      seen[key] = true
      table.insert(choices, { width = mode.width, height = mode.height, text = string.format("%d×%d", mode.width, mode.height) })
    end
  end
  table.sort(choices, function(a, b) return a.width * a.height > b.width * b.height end)
  return choices
end

local function refreshChoices(display, width, height)
  local choices = {}
  for _, mode in ipairs(display.modes) do
    if mode.width == width and mode.height == height then
      table.insert(choices, {
        refresh_rate = mode.refresh_rate,
        preferred = mode.preferred,
        text = formatRefresh(mode.refresh_rate),
      })
    end
  end
  table.sort(choices, function(a, b) return a.refresh_rate > b.refresh_rate end)
  return choices
end

local function selectedResolutionIndex(display, choices)
  for index, choice in ipairs(choices) do
    if choice.width == display.width and choice.height == display.height then
      return index - 1
    end
  end
  return 0
end

local function selectedRefreshIndex(display, choices)
  for index, choice in ipairs(choices) do
    if choice.refresh_rate == display.refresh_rate then
      return index - 1
    end
  end
  return 0
end

local function selectedTransformIndex(display)
  for index, choice in ipairs(TRANSFORM_OPTIONS) do
    if choice.value == display.transform then
      return index - 1
    end
  end
  return 0
end

local function optionsFromChoices(choices)
  local options = {}
  for _, choice in ipairs(choices) do
    table.insert(options, choice.text or tr(choice.label, { angle = choice.angle }))
  end
  return options
end

local function presetFor(port, width, height)
  local rawPresets = noctalia.getConfig("scale_presets")
  local globalScale = nil
  local portScale = nil
  if type(rawPresets) ~= "table" then
    return nil
  end

  for _, raw in ipairs(rawPresets) do
    if type(raw) == "string" then
      local value = noctalia.string.trim(raw)
      local presetPort, presetWidth, presetHeight, presetScale =
        value:match("^([^:]+):(%d+)[xX](%d+)%s*=%s*(%d+%.?%d*)$")
      if presetPort ~= nil then
        if noctalia.string.trim(presetPort) == port
          and tonumber(presetWidth) == width
          and tonumber(presetHeight) == height
          and tonumber(presetScale) > 0 then
          portScale = tonumber(presetScale)
        end
      else
        presetWidth, presetHeight, presetScale =
          value:match("^(%d+)[xX](%d+)%s*=%s*(%d+%.?%d*)$")
        if tonumber(presetWidth) == width
          and tonumber(presetHeight) == height
          and tonumber(presetScale) > 0 then
          globalScale = tonumber(presetScale)
        end
      end
    end
  end
  return portScale or globalScale
end

local function bestRefresh(display, width, height)
  local choices = refreshChoices(display, width, height)
  if #choices == 0 then
    return nil
  end
  for _, choice in ipairs(choices) do
    if choice.refresh_rate == display.refresh_rate then
      return choice.refresh_rate
    end
  end
  for _, choice in ipairs(choices) do
    if choice.preferred then
      return choice.refresh_rate
    end
  end
  return choices[1].refresh_rate
end

local function runNiri(command, sessionOnly, onSuccess)
  if noctalia.state.get("display_action_pending") == true
    or not canChangeDisplays(noctalia.state.get("display_snapshot"), noctalia.state.get("preset_status")) then
    return
  end
  actionPending = true
  noctalia.state.set("display_action_pending", true)
  actionError = ""
  noctalia.log("niri-displays: running " .. command)
  render()

  local started = noctalia.runAsync(command, function(result)
    actionPending = false
    if result.exitCode ~= 0 then
      local message = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]*") or ""
      actionError = result.timedOut and tr("error.timeout") or (message ~= "" and message or tr("error.command"))
      noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
    else
      noctalia.log("niri-displays: display change applied")
      if onSuccess ~= nil then
        onSuccess()
      end
      local key = sessionOnly and "refresh_requested" or "persist_requested"
      noctalia.state.set(key, (noctalia.state.get(key) or 0) + 1)
    end
    noctalia.state.set("display_action_pending", false)
    render()
  end, COMMAND_TIMEOUT_MS)
  if not started then
    actionPending = false
    noctalia.state.set("display_action_pending", false)
    actionError = tr("error.command")
    render()
  end
end

local function applyMode(display, width, height, refreshRate)
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " mode " .. quoteShellArgument(string.format("%dx%d@%.3f", width, height, refreshRate / 1000))
  runNiri(command)
end

local function changeResolution(display, choices, index)
  local choice = choices[index + 1]
  if choice == nil or (choice.width == display.width and choice.height == display.height) then
    return
  end
  local refreshRate = bestRefresh(display, choice.width, choice.height)
  if refreshRate == nil then
    actionError = tr("error.mode_missing")
    render()
    return
  end
  applyMode(display, choice.width, choice.height, refreshRate)
end

local function changeRefresh(display, choices, index)
  local choice = choices[index + 1]
  if choice == nil or choice.refresh_rate == display.refresh_rate then
    return
  end
  applyMode(display, display.width, display.height, choice.refresh_rate)
end

local function changeTransform(display, index)
  local choice = TRANSFORM_OPTIONS[index + 1]
  if choice == nil then
    return
  end
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " transform " .. quoteShellArgument(choice.value)
  runNiri(command)
end

local function changeVrr(display, on)
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " vrr " .. (on and "on" or "off")
  runNiri(command)
end

local function enabledCount()
  local count = 0
  for _, display in ipairs(snapshot.displays) do
    if display.enabled then
      count += 1
    end
  end
  return count
end

-- `niri msg output <port> on|off` is temporary like every other command here:
-- the compositor config still decides the state after a reload.
local function changeEnabled(display, on)
  syncFromState()
  if not on and enabledCount() <= 1 then
    return
  end
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. (on and " on" or " off")
  runNiri(command, true)
end

-- 主屏 = 该输出带 focus-at-startup，重启 Niri 后工作区 1 落在它上面。
-- 已启用的输出会在点星标时立刻 focus-monitor；关着的输出只落盘，不抢焦点。
local function setPrimary(display)
  if not canChangeDisplays() then
    return
  end
  primaryPort = display.port
  noctalia.state.set("primary_port", display.port)
  if display.enabled then
    runNiri("niri msg action focus-monitor " .. quoteShellArgument(display.port), true)
  else
    render()
  end
  noctalia.state.set("persist_requested", (noctalia.state.get("persist_requested") or 0) + 1)
end

local function changeScaleDraft(display, value)
  value = tonumber(value)
  if value == nil then
    return
  end
  scaleEditing[display.port] = true
  scaleDraft[display.port] = value
  render()
end

local function commitScale(display)
  local scale = scaleDraft[display.port] or display.scale
  scaleEditing[display.port] = false
  if math.abs(scale - display.scale) < 0.001 then
    render()
    return
  end
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " scale " .. quoteShellArgument(formatScale(scale))
  runNiri(command)
end

local displayLogicalSize
local field

local function logicalArea(display)
  local size = displayLogicalSize(display)
  return size.width * size.height
end

local function selectLayoutOutput(port)
  selectedPort = port
  positionDraft = {}
  layoutDirection = nil
  layoutOffset = 0
end

local function defaultSelectedPort(displays)
  if selectedPort ~= nil then
    for _, display in ipairs(displays) do
      if display.port == selectedPort and display.enabled then
        return selectedPort
      end
    end
  end
  -- 布局默认选中当前焦点屏；没有焦点屏再按面积最小的一块兜底。
  local best = nil
  for _, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      if display.focused then
        best = display
        break
      end
      if best == nil or logicalArea(display) < logicalArea(best) then
        best = display
      end
    end
  end
  selectLayoutOutput(best and best.port or nil)
  return selectedPort
end

local function referenceDisplay(displays, port)
  local best = nil
  for _, display in ipairs(displays) do
    if display.enabled and display.port ~= port and display.width > 0 and display.height > 0 then
      if best == nil or logicalArea(display) > logicalArea(best) then
        best = display
      end
    end
  end
  return best
end

local function snapPosition(display, ref, direction)
  local size = displayLogicalSize(display)
  local refSize = displayLogicalSize(ref)
  if direction == "right" then
    return ref.x + refSize.width, ref.y + (refSize.height - size.height) / 2
  elseif direction == "left" then
    return ref.x - size.width, ref.y + (refSize.height - size.height) / 2
  elseif direction == "top" then
    return ref.x + (refSize.width - size.width) / 2, ref.y - size.height
  elseif direction == "bottom" then
    return ref.x + (refSize.width - size.width) / 2, ref.y + refSize.height
  end
  return ref.x, ref.y
end

local function setDirection(display, ref, direction)
  layoutDirection = direction
  layoutOffset = 0
  local x, y = snapPosition(display, ref, direction)
  positionDraft[display.port] = { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
  render()
end

local function changeLayoutOffset(display, ref, value)
  value = tonumber(value)
  if value == nil then
    return
  end
  layoutOffset = value
  local direction = layoutDirection or "right"
  local x, y = snapPosition(display, ref, direction)
  if direction == "right" or direction == "left" then
    y = y + value
  else
    x = x + value
  end
  positionDraft[display.port] = { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
  render()
end

local function commitPosition(display)
  local draft = positionDraft[display.port]
  if draft == nil then
    return
  end
  local command = "niri msg output " .. quoteShellArgument(display.port)
    .. " position set -- " .. tostring(draft.x) .. " " .. tostring(draft.y)
  runNiri(command, false, function()
    positionDraft[display.port] = nil
    layoutDirection = nil
    layoutOffset = 0
  end)
end

local MAP_WIDTH = 320
local MAP_HEIGHT = 150
local MAP_COLORS = { "primary", "tertiary", "secondary", "error" }
local POSITION_STEP = 10

local function isRotatedSideways(transform)
  return transform == "90" or transform == "270"
    or transform == "flipped-90" or transform == "flipped-270"
end

displayLogicalSize = function(display)
  if display.logical_width and display.logical_width > 0
    and display.logical_height and display.logical_height > 0 then
    return { width = display.logical_width, height = display.logical_height }
  end
  local scale = display.scale > 0 and display.scale or 1
  local width = display.width / scale
  local height = display.height / scale
  if isRotatedSideways(display.transform) then
    return { width = height, height = width }
  end
  return { width = width, height = height }
end

-- 布局预设：按端口前缀分辨内置屏（eDP-*）与外接屏，一键切到常见布局。
local function isBuiltinPort(port)
  return type(port) == "string"
    and (port:match("^eDP%-") ~= nil
      or port:match("^LVDS%-") ~= nil
      or port:match("^DSI%-") ~= nil)
end

-- 连接行为开关：面板只改共享状态，落盘和执行都由服务端做（面板不写文件）。
local function setPolicy(key, value)
  if not canChangeDisplays() then
    return
  end
  policy[key] = value == true
  local payload = {
    focus_external = policy.focus_external == true,
    internal_off_with_external = policy.internal_off_with_external == true,
  }
  noctalia.state.set("displays_policy", payload)
  noctalia.state.set("policy_set", payload)
  noctalia.state.set("policy_requested", (noctalia.state.get("policy_requested") or 0) + 1)
  render()
end

local function policySection()
  local hasBuiltin = false
  for _, display in ipairs(snapshot.displays) do
    if isBuiltinPort(display.port) then
      hasBuiltin = true
      break
    end
  end

  local function policyRow(titleKey, hintKey, checked, key)
    return ui.row({ align = "center", justify = "space_between", gap = 10 }, {
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr(titleKey), fontSize = 12, color = "on_surface" }),
        ui.label({ text = tr(hintKey), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.toggle({
        checked = checked,
        enabled = canChangeDisplays(),
        onChange = function(value)
          setPolicy(key, value == "true")
        end,
      }),
    })
  end

  local rows = {
    ui.row({ gap = 6, align = "center", tooltip = tr("panel.policy_note") }, {
      ui.glyph({ name = "plug", size = 13, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.policy_title"), fontSize = 11, fontWeight = "bold", color = "on_surface" }),
    }),
    policyRow("panel.policy_focus_external", "panel.policy_focus_external_hint",
      policy.focus_external, "focus_external"),
  }
  if hasBuiltin then
    table.insert(rows, policyRow("panel.policy_internal_off", "panel.policy_internal_off_hint",
      policy.internal_off_with_external, "internal_off_with_external"))
  end

  return ui.column({
    gap = 8,
    align = "stretch",
    fill = "surface_container/0.28",
    border = "outline_variant/0.50",
    borderWidth = 1,
    radius = 12,
    padding = 10,
  }, rows)
end

local function applyPreset(kind)
  if not canChangeDisplays() then
    return
  end
  actionError = ""
  noctalia.state.set("preset_kind", kind)
  noctalia.state.set("preset_requested", (noctalia.state.get("preset_requested") or 0) + 1)
end

local function effectivePosition(display)
  local draft = positionDraft[display.port]
  if draft ~= nil then
    return draft.x, draft.y
  end
  return display.x, display.y
end

local function layoutMap(displays)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  local any = false
  for _, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local size = displayLogicalSize(display)
      local x, y = effectivePosition(display)
      minX = math.min(minX, x)
      minY = math.min(minY, y)
      maxX = math.max(maxX, x + size.width)
      maxY = math.max(maxY, y + size.height)
      any = true
    end
  end
  if not any then
    return nil
  end
  local totalW = math.max(1, maxX - minX)
  local totalH = math.max(1, maxY - minY)
  local scale = math.min(MAP_WIDTH / totalW, MAP_HEIGHT / totalH)

  local items = {}
  for index, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local size = displayLogicalSize(display)
      local x, y = effectivePosition(display)
      table.insert(items, {
        index = index,
        label = display.port,
        x = (x - minX) * scale,
        y = (y - minY) * scale,
        w = math.max(44, size.width * scale),
        h = math.max(18, size.height * scale),
      })
    end
  end

  table.sort(items, function(a, b) return a.y < b.y end)
  local rows = {}
  for _, item in ipairs(items) do
    local placed = false
    for _, row in ipairs(rows) do
      if item.y < row.bottom and row.top < item.y + item.h then
        table.insert(row.items, item)
        if item.y < row.top then row.top = item.y end
        if item.y + item.h > row.bottom then row.bottom = item.y + item.h end
        placed = true
        break
      end
    end
    if not placed then
      table.insert(rows, { top = item.y, bottom = item.y + item.h, items = { item } })
    end
  end
  table.sort(rows, function(a, b) return a.top < b.top end)
  for _, row in ipairs(rows) do
    table.sort(row.items, function(a, b) return a.x < b.x end)
  end

  local rowNodes = {}
  local previousBottom = 0
  for rowIndex, row in ipairs(rows) do
    if rowIndex > 1 then
      local gap = row.top - previousBottom
      if gap > 1 then
        table.insert(rowNodes, ui.spacer({ height = math.floor(gap + 0.5) }))
      end
    end
    local cols = {}
    local cursorX = 0
    for _, item in ipairs(row.items) do
      local offset = item.x - cursorX
      if offset > 1 then
        table.insert(cols, ui.spacer({ width = math.floor(offset + 0.5) }))
      end
      local color = MAP_COLORS[item.index % #MAP_COLORS + 1] or "primary"
      local cell = {}
      local topPad = item.y - row.top
      if topPad > 1 then
        table.insert(cell, ui.spacer({ height = math.floor(topPad + 0.5) }))
      end
      table.insert(cell, ui.column({
        width = math.floor(item.w + 0.5),
        height = math.floor(item.h + 0.5),
        fill = color .. "/0.35",
        border = color .. "/0.6",
        borderWidth = 1,
        radius = 4,
        align = "center",
        justify = "center",
        paddingH = 2,
      }, {
        ui.label({
          text = item.label,
          fontSize = 8,
          fontWeight = "bold",
          color = "on_surface",
          maxLines = 1,
        }),
      }))
      table.insert(cols, ui.column({ gap = 0, align = "start" }, cell))
      cursorX = item.x + item.w
    end
    table.insert(rowNodes, ui.row({ gap = 0, align = "start" }, cols))
    previousBottom = row.bottom
  end

  return ui.column({ gap = 0, align = "center" }, rowNodes)
end

local function layoutSection(displays)
  if enabledCount() == 0 then
    return nil
  end

  local header = ui.column({
    fill = "surface_container/0.28",
    border = "outline_variant/0.50",
    borderWidth = 1,
    radius = 12,
    align = "stretch",
  }, {
    ui.button({
      text = tr("panel.layout"),
      glyph = layoutExpanded and "chevron-down" or "chevron-right",
      variant = "ghost",
      fontSize = 12,
      contentAlign = "start",
      flexGrow = 1,
      onClick = function()
        layoutExpanded = not layoutExpanded
        savePanelUi()
        render()
      end,
    }),
  })

  if not layoutExpanded then
    return ui.column({ gap = 4, align = "stretch" }, { header })
  end

  local targetPort = defaultSelectedPort(displays)
  local map = layoutMap(displays)
  local children = {}

  if map ~= nil then
    table.insert(children, ui.column({
      fill = "surface_container/0.22",
      border = "outline_variant/0.42",
      borderWidth = 1,
      radius = 10,
      padding = 10,
      align = "center",
    }, { map }))
  end

  -- 地图下方的端口按钮：点一下就把布局编辑目标切到这块屏。
  local targetButtons = {}
  for _, display in ipairs(displays) do
    if display.enabled then
      table.insert(targetButtons, ui.button({
        text = display.port,
        variant = "outline",
        selected = display.port == targetPort,
        fontSize = 10,
        onClick = function()
          if selectedPort ~= display.port then
            selectLayoutOutput(display.port)
            savePanelUi()
            render()
          end
        end,
      }))
    end
  end
  if #targetButtons > 1 then
    table.insert(children, ui.row({ gap = 6, align = "center", justify = "center" }, targetButtons))
  end

  local selected = nil
  if targetPort ~= nil then
    for _, display in ipairs(displays) do
      if display.port == targetPort and display.enabled then
        selected = display
        break
      end
    end
  end

  if selected ~= nil then
    local ref = referenceDisplay(displays, selected.port)
    if ref ~= nil then
      local canMove = canChangeDisplays()

      local options = {}
      local optionPorts = {}
      local selectedIndex = 0
      for _, display in ipairs(displays) do
        if display.enabled then
          table.insert(optionPorts, display.port)
          table.insert(options, display.name .. " · " .. display.port)
          if display.port == selected.port then
            selectedIndex = #optionPorts - 1
          end
        end
      end

      local refSize = displayLogicalSize(ref)
      local selectedSize = displayLogicalSize(selected)
      local offsetMin = 0
      local offsetMax = 0
      local hasDirection = layoutDirection ~= nil
      if hasDirection then
        if layoutDirection == "right" or layoutDirection == "left" then
          local half = (refSize.height - selectedSize.height) / 2
          offsetMin = -math.floor(math.max(0, half))
          offsetMax = math.floor(math.max(0, half))
        else
          local half = (refSize.width - selectedSize.width) / 2
          offsetMin = -math.floor(math.max(0, half))
          offsetMax = math.floor(math.max(0, half))
        end
      end

      table.insert(children, ui.column({ gap = 8, align = "stretch" }, {
        ui.row({ gap = 10, align = "center" }, {
          field(tr("panel.position"), ui.select({
            options = options,
            selectedIndex = selectedIndex,
            enabled = canMove,
            onChange = function(index)
              local port = optionPorts[index + 1]
              if port ~= nil and port ~= selectedPort then
                selectLayoutOutput(port)
                savePanelUi()
                render()
              end
            end,
          })),
          ui.column({ gap = 4, align = "center" }, {
            ui.row({ gap = 4, align = "center" }, {
              ui.spacer({ width = 32 }),
              ui.button({ glyph = "chevron-up", width = 32, height = 32, enabled = canMove, onClick = function() setDirection(selected, ref, "top") end }),
              ui.spacer({ width = 32 }),
            }),
            ui.row({ gap = 4, align = "center" }, {
              ui.button({ glyph = "chevron-left", width = 32, height = 32, enabled = canMove, onClick = function() setDirection(selected, ref, "left") end }),
              ui.spacer({ width = 32 }),
              ui.button({ glyph = "chevron-right", width = 32, height = 32, enabled = canMove, onClick = function() setDirection(selected, ref, "right") end }),
            }),
            ui.row({ gap = 4, align = "center" }, {
              ui.spacer({ width = 32 }),
              ui.button({ glyph = "chevron-down", width = 32, height = 32, enabled = canMove, onClick = function() setDirection(selected, ref, "bottom") end }),
              ui.spacer({ width = 32 }),
            }),
          }),
          ui.column({ gap = 6, align = "stretch", width = 120 }, {
            ui.label({ text = tr("panel.position_offset"), fontSize = 11, color = "on_surface_variant" }),
            ui.slider({
              min = offsetMin,
              max = offsetMax,
              step = POSITION_STEP,
              value = layoutOffset,
              enabled = canMove and hasDirection,
              onChange = function(value)
                changeLayoutOffset(selected, ref, value)
              end,
            }),
          }),
        }),
        ui.button({
          text = tr("panel.apply"),
          variant = "outline",
          glyph = "check",
          enabled = canMove and hasDirection,
          onClick = function()
            commitPosition(selected)
          end,
        }),
      }))
    end
  end

  return ui.column({ gap = 8, align = "stretch" }, {
    header,
    ui.column({
      gap = 10,
      align = "stretch",
      fill = "surface_container/0.22",
      border = "outline_variant/0.42",
      borderWidth = 1,
      radius = 10,
      padding = 10,
    }, children),
  })
end

local function badge(text, color)
  return ui.row({ fill = color .. "/0.16", radius = 8, paddingH = 7, paddingV = 2, align = "center" }, {
    ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = color }),
  })
end

field = function(label, control)
  return ui.column({ gap = 5, flexGrow = 1, align = "stretch" }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
    control,
  })
end


-- 卡片标题只放厂商与型号，端口单独一行灰色小字——两列并排时这样不会把型号撑断。
local function displayName(display)
  local parts = {}
  if type(display.make) == "string" and display.make ~= "" then
    table.insert(parts, display.make)
  end
  if type(display.model) == "string" and display.model ~= "" then
    table.insert(parts, display.model)
  end
  if #parts == 0 then
    return display.port
  end
  return table.concat(parts, " · ")
end

-- 与内置「屏幕」页同样的摘要格式：2560×1600 @ 111%
local function modeSummary(display)
  if not display.enabled or display.width == 0 or display.height == 0 then
    return tr("panel.disabled")
  end
  return string.format("%d×%d @ %d%%", display.width, display.height,
    math.floor((display.scale or 1) * 100 + 0.5))
end

-- 行网格与第一版一致：标签在上、控件整宽在下。下拉用 ui.select（值在左、箭头在右，
-- 点开是原生选项列表），三种字段长得一样，卡片不会出现两套对齐逻辑。
local function switchRow(caption, checked, enabled, onChange)
  return ui.row({ align = "center", justify = "space_between", gap = 10 }, {
    ui.label({ text = caption, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
    ui.toggle({ checked = checked, enabled = enabled, onChange = onChange }),
  })
end

local function displayCard(display, position, compact)
  local resolutions = resolutionChoices(display)
  for _, choice in ipairs(resolutions) do
    local automaticScale = presetFor(display.port, choice.width, choice.height)
    if automaticScale ~= nil then
      choice.text ..= " · " .. formatScale(automaticScale) .. "×"
    end
  end
  local refreshes = refreshChoices(display, display.width, display.height)

  local canChange = canChangeDisplays()
  local enabled = display.enabled and canChange
  -- Refuse to black out the session: the final lit output cannot be switched off.
  local isLastEnabled = display.enabled and enabledCount() <= 1
  local scale = scaleDraft[display.port] or display.scale
  local minScale = 0.5
  local maxScale = 3.0

  local collapsed = collapsedPorts[display.port] == true
  -- 展开时下方字段已经逐项显示当前值，标题行只留型号与端口，避免重复。
  local titleChildren = {
    ui.label({ text = displayName(display), fontSize = 12, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
    ui.label({
      text = collapsed and modeSummary(display) or display.port,
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    }),
  }

  local headerChildren = {
    badge(tostring(position), display.focused and "primary" or "on_surface_variant"),
    ui.glyph({ name = "device-desktop", size = 18, color = display.focused and "on_surface" or "on_surface_variant" }),
    ui.column({ gap = 0, flexGrow = 1 }, titleChildren),
  }
  if display.focused then
    table.insert(headerChildren, badge(tr("panel.focused"), "primary"))
  end
  if not display.enabled then
    table.insert(headerChildren, badge(tr("panel.disabled"), "on_surface_variant"))
  end
  local isPrimary = primaryPort == display.port
  table.insert(headerChildren, ui.button({
    glyph = isPrimary and "star-filled" or "star",
    selected = isPrimary,
    enabled = canChange,
    tooltip = tr("panel.primary_hint"),
    onClick = function()
      setPrimary(display)
    end,
  }))
  table.insert(headerChildren, ui.button({
    glyph = collapsed and "chevron-down" or "chevron-up",
    onClick = function()
      collapsedPorts[display.port] = not collapsed
      savePanelUi()
      render()
    end,
  }))

  local resolutionOptions = optionsFromChoices(resolutions)
  local refreshOptions = optionsFromChoices(refreshes)
  if #refreshOptions == 0 then
    refreshOptions = { "—" }
  end
  local transformOptions = optionsFromChoices(TRANSFORM_OPTIONS)

  local enabledSwitch = switchRow(tr(isLastEnabled and "panel.last_display" or "panel.enabled"), display.enabled,
    canChange and not isLastEnabled,
    function(value)
      changeEnabled(display, value == "true")
    end)
  local resolutionField = field(tr("panel.resolution"), ui.select({
    options = resolutionOptions,
    selectedIndex = selectedResolutionIndex(display, resolutions),
    enabled = enabled and #resolutions > 0,
    onChange = function(index)
      changeResolution(display, resolutions, index)
    end,
  }))
  local refreshField = field(tr("panel.refresh_rate"), ui.select({
    options = refreshOptions,
    selectedIndex = selectedRefreshIndex(display, refreshes),
    enabled = enabled and #refreshes > 0,
    onChange = function(index)
      changeRefresh(display, refreshes, index)
    end,
  }))
  local rotationField = field(tr("panel.rotation"), ui.select({
    options = transformOptions,
    selectedIndex = selectedTransformIndex(display),
    enabled = enabled,
    onChange = function(index)
      changeTransform(display, index)
    end,
  }))
  local scaleField = ui.column({
    gap = 4,
    align = "stretch",
    flexGrow = compact and 1 or nil,
  }, {
    ui.row({ align = "center", justify = "space_between", gap = 10 }, {
      ui.label({ text = tr("panel.scale_range"), fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = formatScale(scale) .. "×", fontSize = 11, fontWeight = "bold", color = "on_surface" }),
    }),
    ui.slider({
      min = minScale,
      max = maxScale,
      step = 0.05,
      value = scale,
      enabled = enabled,
      onChange = function(value)
        changeScaleDraft(display, value)
      end,
      onDragEnd = function()
        commitScale(display)
      end,
    }),
  })
  local vrrSwitch = switchRow(tr("panel.vrr"), display.vrr_enabled,
    enabled,
    function(value)
      changeVrr(display, value == "true")
    end)

  -- 单卡整行时字段两列排布，少占半屏高度；两张卡并排时继续逐项纵向排列。
  local body
  if compact then
    body = {
      enabledSwitch,
      ui.row({ gap = 10, align = "start" }, { resolutionField, refreshField }),
      ui.row({ gap = 10, align = "start" }, { rotationField, scaleField }),
    }
    if display.vrr_supported then
      table.insert(body, vrrSwitch)
    end
  else
    body = { enabledSwitch, resolutionField, refreshField, rotationField }
    if display.vrr_supported then
      table.insert(body, vrrSwitch)
    end
    table.insert(body, scaleField)
  end

  local cardChildren = {
    ui.row({ gap = 8, align = "center" }, headerChildren),
  }
  if not collapsed then
    -- 关掉的屏整块压暗一档，省得一堆灰控件抢焦点屏的注意力
    table.insert(cardChildren, ui.column({
      gap = 8,
      align = "stretch",
      opacity = display.enabled and 1 or 0.78,
    }, body))
  end

  return ui.column({
    key = "display:" .. display.port,
    fill = display.focused and "surface_container/0.34" or "surface_container/0.24",
    border = display.focused and "primary/0.45" or "outline_variant/0.50",
    borderWidth = display.focused and 2 or 1,
    radius = 12,
    padding = 10,
    gap = 9,
    align = "stretch",
    flexGrow = 1,
    minWidth = 190,
  }, cardChildren)
end

local function body()
  local displays = snapshot.displays
  if #displays == 0 then
    if snapshot.status == "error" then
      return ui.column(CENTERED_LAYOUT, {
        ui.glyph({ name = "alert-circle", size = 38, color = "error" }),
        ui.label({ text = tr("error.title"), fontWeight = "bold", color = "error" }),
        ui.label({ text = snapshot.error_message, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
        ui.button({
          text = tr("panel.retry"),
          glyph = "refresh",
          variant = "outline",
          onClick = function()
            noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
          end,
        }),
      })
    elseif snapshot.status == "ok" then
      return ui.column(CENTERED_LAYOUT, {
        ui.glyph({ name = "device-desktop-off", size = 38, color = "on_surface_variant" }),
        ui.label({ text = tr("panel.empty"), color = "on_surface_variant", textAlign = "center" }),
      })
    end
    return ui.column(CENTERED_LAYOUT, {
      ui.glyph({ name = "loader-2", size = 36, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }),
    })
  end

  local cards = {}
  local cardCount = math.min(#displays, MAX_DISPLAYS)
  for index, display in ipairs(displays) do
    if index <= MAX_DISPLAYS then
      -- 一行两张卡；最后剩一张时给它整行宽，并把字段排成两列。
      local compact = cardCount == 1 or (index == cardCount and cardCount % 2 == 1)
      table.insert(cards, displayCard(display, index, compact))
    end
  end
  if #displays > MAX_DISPLAYS then
    table.insert(cards, ui.label({
      text = tr("panel.more_displays", { count = #displays - MAX_DISPLAYS }),
      color = "on_surface_variant",
      textAlign = "center",
    }))
  end

  local scrollChildren = {}

  table.insert(scrollChildren, policySection())

  local layout = layoutSection(displays)
  if layout ~= nil then
    table.insert(scrollChildren, layout)
  end

  -- 两张卡并排一行（第一版就是这个密度），最多 12 块屏。
  local currentRow = {}
  for _, card in ipairs(cards) do
    table.insert(currentRow, card)
    if #currentRow == 2 then
      table.insert(scrollChildren, ui.row({ gap = 10, align = "start" }, currentRow))
      currentRow = {}
    end
  end
  if #currentRow > 0 then
    table.insert(scrollChildren, ui.row({ gap = 10, align = "start" }, currentRow))
  end

  return ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, scrollChildren)
end

render = function()
  if not isOpen then
    return
  end
  local children = {
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "device-desktop", size = 22, color = "on_surface_variant" }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.screen_title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = tr("panel.subtitle"), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({
        text = snapshot.updated_at ~= "" and tr("panel.updated", { time = snapshot.updated_at }) or "",
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.button({
        glyph = "refresh",
        onClick = function()
          noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
        end,
      }),
      ui.button({ glyph = "close", onClick = panel.close }),
    }),
  }

  local hasBuiltin, hasExternal = false, false
  for _, display in ipairs(snapshot.displays) do
    if isBuiltinPort(display.port) then
      hasBuiltin = true
    else
      hasExternal = true
    end
  end

  local canChange = canChangeDisplays()
  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text = tr("panel.solo_all"),
      flexGrow = 1,
      glyph = "layout-grid",
      enabled = canChange and #snapshot.displays > 0,
      onClick = function()
        applyPreset("all")
      end,
    }),
    ui.button({
      text = tr("panel.preset_laptop"),
      flexGrow = 1,
      glyph = "device-laptop",
      enabled = canChange and hasBuiltin,
      tooltip = not hasBuiltin and tr("panel.preset_need_builtin") or nil,
      onClick = function()
        applyPreset("laptop")
      end,
    }),
    ui.button({
      text = tr("panel.preset_external"),
      flexGrow = 1,
      glyph = "device-desktop",
      enabled = canChange and hasExternal,
      tooltip = not hasExternal and tr("panel.preset_need_external") or nil,
      onClick = function()
        applyPreset("external")
      end,
    }),
    ui.button({
      text = tr("panel.preset_dual"),
      flexGrow = 1,
      glyph = "layout-columns",
      enabled = canChange and hasBuiltin and hasExternal,
      tooltip = not (hasBuiltin and hasExternal) and tr("panel.preset_need_two") or nil,
      onClick = function()
        applyPreset("dual")
      end,
    }),
  }))

  if actionError ~= "" then
    table.insert(children, ui.label({ text = actionError, color = "error", fontSize = 11, maxLines = 3 }))
  elseif snapshot.status == "error" and #snapshot.displays > 0 then
    table.insert(children, ui.label({ text = snapshot.error_message, color = "error", fontSize = 11, maxLines = 3 }))
  end

  table.insert(children, body())

  -- 底部常驻说明条（第一版那种），把「立即生效 / 写回哪个文件」固定在一个位置。
  local configuredPath = noctalia.getConfig("outputs_file")
  local path = type(configuredPath) == "string" and noctalia.string.trim(configuredPath) or ""
  if path == "" then
    path = "~/.config/niri/outputs.kdl"
  end
  table.insert(children, ui.row({
    gap = 8,
    align = "center",
    paddingH = 10,
    paddingV = 6,
    fill = "surface_container/0.28",
    border = "outline_variant/0.50",
    borderWidth = 1,
    radius = 10,
  }, {
    ui.glyph({ name = "info-circle", size = 13, color = "on_surface_variant" }),
    ui.label({ text = tr("panel.temporary_note", { path = path }), fontSize = 10, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 5, align = "stretch" }, children))
end

noctalia.state.watch("display_snapshot", function()
  syncFromState()
  render()
end)

noctalia.state.watch("primary_port", function(value)
  primaryPort = value
  render()
end)

noctalia.state.watch("displays_policy", function()
  syncFromState()
  render()
end)

noctalia.state.watch("preset_status", function(value)
  presetStatus = value or {}
  if presetStatus.pending then
    actionError = ""
    layoutDirection = nil
    layoutOffset = 0
    positionDraft = {}
  elseif presetStatus.error_message and presetStatus.error_message ~= "" then
    actionError = presetStatus.error_message
  end
  render()
end)

function onOpen(_context)
  scaleEditing = {}
  presetStatus = noctalia.state.get("preset_status") or {}
  loadPanelUi()
  syncFromState()
  isOpen = true
  noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
  render()
end

function onClose()
  isOpen = false
  scaleEditing = {}
  positionDraft = {}
  layoutDirection = nil
  layoutOffset = 0
  savePanelUi()
end

function onExit()
  if actionPending then
    noctalia.state.set("display_action_pending", false)
  end
end

function onConfigChanged()
  render()
end
