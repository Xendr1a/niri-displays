--!nonstrict
-- Headless service: reads the authoritative output state from Niri's JSON IPC
-- and publishes a normalized snapshot for the bar widget and panel.

local STATE_KEY = "display_snapshot"
local DEFAULT_FALLBACK_INTERVAL_S = 30
local MIN_FALLBACK_INTERVAL_S = 5
local FOCUS_CHECK_INTERVAL_MS = 100
local COMMAND_TIMEOUT_MS = 5000

local fetching = false
local refreshQueued = false
local generation = 0
local lastRefreshNonce = noctalia.state.get("refresh_requested") or 0
local lastFullRefreshAt = 0
local lastResolutionByPort = {}
local resolutionStateReady = false
local presetApplying = {}
-- Enforce a matching preset once when the service starts or hot-reloads. This
-- also repairs a mode change that completed while the service was unavailable.
local forcePresetCheck = true
local startRefresh

local tr = noctalia.tr

local function initialSnapshot(status, message)
  return {
    revision = 0,
    status = status,
    error_message = message,
    focused_output = nil,
    displays = {},
    updated_at = "",
  }
end

local function shallowCopy(value)
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = item
  end
  return copy
end

local function readFallbackIntervalSeconds()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or DEFAULT_FALLBACK_INTERVAL_S
  return math.max(MIN_FALLBACK_INTERVAL_S, seconds)
end

local function quoteShellArgument(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function formatScale(value)
  local text = string.format("%.4f", value)
  text = text:gsub("0+$", ""):gsub("%.$", "")
  return text
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

local function displayLabel(output, connector)
  local make = noctalia.string.trim(output.make or "")
  local model = noctalia.string.trim(output.model or "")
  if make ~= "" and model ~= "" then
    return make .. " " .. model
  elseif model ~= "" then
    return model
  elseif make ~= "" then
    return make
  end
  return connector
end

local function normalizeModes(rawModes)
  local modes = {}
  for _, raw in ipairs(rawModes or {}) do
    local width = tonumber(raw.width)
    local height = tonumber(raw.height)
    local refresh = tonumber(raw.refresh_rate)
    if width ~= nil and height ~= nil and refresh ~= nil then
      table.insert(modes, {
        width = width,
        height = height,
        refresh_rate = refresh,
        preferred = raw.is_preferred == true,
      })
    end
  end
  return modes
end

-- Map Niri's JSON transform names to the values accepted by
-- `niri msg output <connector> transform <value>`.
local function normalizeTransform(rawTransform)
  local mapping = {
    Normal = "normal",
    ["90"] = "90",
    ["180"] = "180",
    ["270"] = "270",
    Flipped = "flipped",
    Flipped90 = "flipped-90",
    Flipped180 = "flipped-180",
    Flipped270 = "flipped-270",
  }
  if type(rawTransform) == "string" then
    return mapping[rawTransform] or "normal"
  end
  return "normal"
end

-- ── 持久化：把当前布局写回 niri 的 include 文件 ────────────────────────────
-- 面板每次成功执行 niri 命令后会 bump `persist_requested`，服务刷新到最新快照
-- 之后再把 layout 写成 KDL 片段。config.kdl 用 include 引入该文件。
local DEFAULT_OUTPUTS_FILE = "~/.config/niri/outputs.kdl"
local persistPending = false
local primaryPort = nil

local function outputsFilePath()
  local configured = noctalia.getConfig("outputs_file")
  if type(configured) ~= "string" or noctalia.string.trim(configured) == "" then
    configured = DEFAULT_OUTPUTS_FILE
  end
  return noctalia.expandPath(noctalia.string.trim(configured))
end

-- ── 连接行为策略 ────────────────────────────────────────────────────────────
-- 两件事要跨开机记住，又不能写进 outputs.kdl（那是纯 KDL 布局，而且「关闭」状态
-- 不允许持久化）：接外屏时焦点是否跟过去、接外屏时是否熄内屏。单独存一份 JSON，
-- 和 outputs_file 放同一个目录。
local policy = {
  focus_external = true,              -- 默认：接上外屏就把焦点让过去
  internal_off_with_external = false, -- 默认：内屏保持点亮
}
local policyEpoch = nil      -- 当前这一轮「外接屏集合」；变化时才执行动作，避免抢回手动操作
local forcePolicyApply = false

local function isBuiltinPort(port)
  return type(port) == "string"
    and (port:match("^eDP%-") ~= nil
      or port:match("^LVDS%-") ~= nil
      or port:match("^DSI%-") ~= nil)
end

local function policyFilePath()
  local path = outputsFilePath()
  local dir = path:match("^(.*)[/\\][^/\\]*$") or "."
  return dir .. "/displays-policy.json"
end

local function publishPolicy()
  noctalia.state.set("displays_policy", {
    focus_external = policy.focus_external == true,
    internal_off_with_external = policy.internal_off_with_external == true,
  })
end

local function loadPolicy()
  local raw = noctalia.readFile(policyFilePath())
  if type(raw) == "string" and raw ~= "" then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      if type(decoded.focus_external) == "boolean" then
        policy.focus_external = decoded.focus_external
      end
      if type(decoded.internal_off_with_external) == "boolean" then
        policy.internal_off_with_external = decoded.internal_off_with_external
      end
    end
  end
  publishPolicy()
end

local function savePolicy()
  local encoded = noctalia.json.encode(policy)
  if type(encoded) == "string" then
    local ok, err = noctalia.writeFile(policyFilePath(), encoded .. "\n")
    if not ok then
      noctalia.log("niri-displays: policy write failed: " .. tostring(err))
    end
  end
  publishPolicy()
end

-- 读回上次写出的文件：拿到主屏标记，并为当前关掉的输出保留上次的 mode/scale 等。
local function readExistingBlocks()
  local blocks = {}
  local text = noctalia.readFile(outputsFilePath())
  if type(text) ~= "string" then
    return blocks
  end
  for port, bodyText in text:gmatch('output%s+"([^"]+)"%s*{([^}]*)}') do
    local block = {}
    block.mode = bodyText:match('mode%s+"([^"]+)"')
    block.scale = bodyText:match('scale%s+([%d%.]+)')
    block.transform = bodyText:match('transform%s+"([^"]+)"')
    block.x, block.y = bodyText:match('position%s+x%s*=%s*(-?%d+)%s+y%s*=%s*(-?%d+)')
    block.vrr = bodyText:find("variable-refresh-rate", 1, true) ~= nil
    if bodyText:find("focus-at-startup", 1, true) ~= nil then
      block.primary = true
      -- 文件里可能同时标了外接屏和内置屏（先出现者优先级更高），主屏只认第一个。
      if primaryPort == nil then
        primaryPort = port
      end
    end
    blocks[port] = block
  end
  return blocks
end

local function writeOutputsFile(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.displays) ~= "table" then
    return false, "no snapshot"
  end
  local existing = readExistingBlocks()
  local requestedPrimary = noctalia.state.get("primary_port")
  if type(requestedPrimary) == "string" and requestedPrimary ~= "" then
    primaryPort = requestedPrimary
  end

  local lines = {
    "// 本文件由 Noctalia 插件 xendr1a/niri-displays 自动生成；改布局请用面板（右上角显示器图标）。",
    "// 关闭(off)状态不会被写入，避免拔掉外接屏后一个可用的输出都没有。",
    "// 开机焦点按 focus-at-startup 出现的先后决定：接了外接屏就落在它上面，没接就落在内置屏。",
    "",
  }

  -- focus-at-startup 的优先级由配置里的书写顺序决定（先出现者先赢，见 niri 文档
  -- Configuration: Outputs），所以外接屏写在前面、内置屏写在后面：
  --   两块都接着 → 外接屏；只接笔记本 → 内置屏。两块都不亮 → niri 自己按名字挑。
  local focusFlags = {}
  local preferredExternal = nil
  if type(primaryPort) == "string" and primaryPort ~= "" and not isBuiltinPort(primaryPort) then
    preferredExternal = primaryPort
  elseif type(primaryPort) ~= "string" or primaryPort == "" then
    -- 没设过主屏：默认挑一块外接屏，先把「接了显示器就开机落在外屏」变成默认行为。
    for _, display in ipairs(snapshot.displays) do
      if display.enabled and not isBuiltinPort(display.port) then
        preferredExternal = display.port
        break
      end
    end
    if preferredExternal == nil then
      for _, display in ipairs(snapshot.displays) do
        if not isBuiltinPort(display.port) then
          preferredExternal = display.port
          break
        end
      end
    end
  end
  if preferredExternal ~= nil then
    focusFlags[preferredExternal] = true
    primaryPort = preferredExternal
  end
  for _, display in ipairs(snapshot.displays) do
    if isBuiltinPort(display.port) then
      focusFlags[display.port] = true
    end
  end
  if preferredExternal == nil and type(primaryPort) == "string" and primaryPort ~= "" then
    focusFlags[primaryPort] = true -- 用户把主屏钉在内置屏上
  end
  -- 把最终生效的主屏发布出去，面板的星标才能反映「服务自动选的外接屏」而不只是手点过的。
  if type(primaryPort) == "string" and primaryPort ~= "" then
    noctalia.state.set("primary_port", primaryPort)
  end

  local entries = {}
  local seenPorts = {}
  for _, display in ipairs(snapshot.displays) do
    local port = display.port
    seenPorts[port] = true
    local old = existing[port] or {}
    local live = display.enabled and display.width > 0 and display.height > 0
    table.insert(entries, {
      port = port,
      mode = live
          and string.format("%dx%d@%.3f", display.width, display.height, display.refresh_rate / 1000)
        or old.mode,
      scale = live and formatScale(display.scale) or old.scale,
      transform = live and display.transform or old.transform,
      vrr = live and display.vrr_enabled or old.vrr,
      x = live and tostring(math.floor(display.x + 0.5)) or old.x,
      y = live and tostring(math.floor(display.y + 0.5)) or old.y,
    })
  end
  -- 当前没接的输出保留上次的布局：拔掉再插回来、或者下次开机时直接沿用，
  -- 不用重新调分辨率/缩放/位置。
  for port, old in pairs(existing) do
    if not seenPorts[port] then
      table.insert(entries, {
        port = port,
        mode = old.mode,
        scale = old.scale,
        transform = old.transform,
        x = old.x,
        vrr = old.vrr,
        y = old.y,
      })
    end
  end

  -- 外接屏在前、内置屏在后，保证 niri 取到的是「外接屏优先」那一条。
  table.sort(entries, function(a, b)
    local function rank(entry)
      if entry.port == preferredExternal then
        return 0
      elseif isBuiltinPort(entry.port) then
        return 1
      end
      return 2
    end
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then
      return ra < rb
    end
    return a.port < b.port
  end)

  for _, entry in ipairs(entries) do
    local port = entry.port
    if entry.mode ~= nil or entry.transform ~= nil then
      table.insert(lines, 'output "' .. port .. '" {')
      if entry.mode ~= nil then
        table.insert(lines, '    mode "' .. entry.mode .. '"')
      end
      if entry.scale ~= nil then
        table.insert(lines, "    scale " .. entry.scale)
      end
      if entry.transform ~= nil then
        table.insert(lines, '    transform "' .. entry.transform .. '"')
      end
      if entry.x ~= nil and entry.y ~= nil then
        table.insert(lines, "    position x=" .. entry.x .. " y=" .. entry.y)
      end
      if entry.vrr == true then
        table.insert(lines, "    variable-refresh-rate")
      end
      if focusFlags[port] then
        table.insert(lines, "    focus-at-startup")
      end
      table.insert(lines, "}")
      table.insert(lines, "")
    end
  end

  local path = outputsFilePath()
  local content = table.concat(lines, "\n")
  -- 先留一份上一版，写完立刻让 niri 校验整份配置；不合法就整份回滚，
  -- 免得下次重载配置因为这一小段 KDL 直接失败。
  local previous = noctalia.readFile(path)
  if type(previous) == "string" and previous ~= "" then
    noctalia.writeFile(path .. ".bak", previous)
  end

  local ok, err = noctalia.writeFile(path, content)
  if not ok then
    noctalia.log("niri-displays: layout write failed: " .. tostring(err))
    return false, err
  end

  local started = noctalia.runAsync("niri validate", function(result)
    if result.exitCode == 0 then
      noctalia.log("niri-displays: layout written + verified: " .. path)
      return
    end
    local firstLine = noctalia.string.trim(result.stderr or ""):match("^[^\n]*") or ""
    if type(previous) == "string" and previous ~= "" then
      noctalia.writeFile(path, previous)
      noctalia.log("niri-displays: niri rejected generated layout, rolled back: " .. firstLine)
      noctalia.notify("显示器布局未写入", "niri 校验失败，已回滚上一版：" .. firstLine)
    else
      noctalia.log("niri-displays: niri rejected generated layout, no backup to restore: " .. firstLine)
      noctalia.notify("显示器布局未写入", "niri 校验失败：" .. firstLine)
    end
  end, 8000)

  if not started then
    noctalia.log("niri-displays: could not start niri validate")
  end

  return true
end

local function normalizeOutputs(rawOutputs, focusedName, revision)
  local displays = {}
  for connector, raw in pairs(rawOutputs) do
    if type(raw) == "table" then
      local modes = normalizeModes(raw.modes)
      local currentIndex = tonumber(raw.current_mode)
      local currentMode = nil
      if currentIndex ~= nil then
        currentMode = modes[currentIndex + 1]
      end
      local logical = type(raw.logical) == "table" and raw.logical or nil
      table.insert(displays, {
        name = displayLabel(raw, connector),
        port = connector,
        make = raw.make or "",
        model = raw.model or "",
        serial = raw.serial or "",
        focused = connector == focusedName,
        enabled = logical ~= nil and currentMode ~= nil,
        x = logical and (tonumber(logical.x) or 0) or 0,
        y = logical and (tonumber(logical.y) or 0) or 0,
        scale = logical and (tonumber(logical.scale) or 1) or 1,
        transform = logical and normalizeTransform(logical.transform) or "normal",
        width = currentMode and currentMode.width or 0,
        height = currentMode and currentMode.height or 0,
        refresh_rate = currentMode and currentMode.refresh_rate or 0,
        modes = modes,
        vrr_supported = raw.vrr_supported == true,
        vrr_enabled = raw.vrr_enabled == true,
      })
    end
  end

  table.sort(displays, function(a, b)
    if a.enabled ~= b.enabled then
      return a.enabled
    elseif a.x ~= b.x then
      return a.x < b.x
    elseif a.y ~= b.y then
      return a.y < b.y
    end
    return a.port < b.port
  end)

  return {
    revision = revision,
    status = "ok",
    error_message = "",
    focused_output = focusedName,
    displays = displays,
    updated_at = noctalia.formatTime("%H:%M:%S"),
  }
end

local function commandError(result, fallback)
  if result.timedOut then
    return tr("error.timeout")
  end
  local message = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]*") or ""
  if message ~= "" then
    return message
  end
  return fallback
end

local function applyPresetsForResolutionChanges(snapshot)
  -- A Niri mode switch can temporarily remove an output from `outputs`
  -- altogether. Keep the last mode for known connectors so the reconnect is
  -- still recognized as a resolution change instead of a brand-new display.
  local nextResolutions = {}
  for port, resolution in pairs(lastResolutionByPort) do
    nextResolutions[port] = resolution
  end
  for _, display in ipairs(snapshot.displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local resolution = tostring(display.width) .. "x" .. tostring(display.height)
      nextResolutions[display.port] = resolution
      local previous = lastResolutionByPort[display.port]
      if forcePresetCheck or (resolutionStateReady and previous ~= nil and previous ~= resolution) then
        local targetScale = presetFor(display.port, display.width, display.height)
        if targetScale ~= nil and math.abs(display.scale - targetScale) > 0.001
          and presetApplying[display.port] ~= targetScale then
          local port = display.port
          presetApplying[port] = targetScale
          local command = "niri msg output " .. quoteShellArgument(port)
            .. " scale " .. quoteShellArgument(formatScale(targetScale))
          noctalia.log("niri-displays: resolution changed on " .. port .. " to " .. resolution
            .. "; applying scale preset " .. formatScale(targetScale))
          local started = noctalia.runAsync(command, function(result)
            presetApplying[port] = nil
            if result.exitCode ~= 0 then
              noctalia.log("niri-displays: automatic scale failed for " .. port .. ": "
                .. commandError(result, tr("error.command")))
            else
              startRefresh()
            end
          end, COMMAND_TIMEOUT_MS)
          if not started then
            presetApplying[port] = nil
            noctalia.log("niri-displays: could not start automatic scale command for " .. port)
          end
        end
      end
    end
  end
  lastResolutionByPort = nextResolutions
  resolutionStateReady = true
  forcePresetCheck = false
end

local function syncFocusedOutput()
  local focusedName = noctalia.focusedOutputName()
  if type(focusedName) ~= "string" or focusedName == "" then
    return
  end
  local current = noctalia.state.get(STATE_KEY)
  if type(current) ~= "table" or type(current.displays) ~= "table"
    or current.focused_output == focusedName then
    return
  end

  local nextSnapshot = shallowCopy(current)
  nextSnapshot.focused_output = focusedName
  nextSnapshot.displays = {}
  for _, display in ipairs(current.displays) do
    local nextDisplay = shallowCopy(display)
    nextDisplay.focused = display.port == focusedName
    table.insert(nextSnapshot.displays, nextDisplay)
  end
  noctalia.state.set(STATE_KEY, nextSnapshot)
end

-- ── 连接行为：接上/拔掉外接屏时做一次动作 ──────────────────────────────────
-- 只在「亮着的外接屏集合」变化时执行，所以之后手动打开内屏、或把焦点切回笔记本，
-- 都不会被反复抢回去。开机时第一次快照算一次变化，于是「接着显示器开机」也能落在
-- 外接屏上。
local function applyConnectionPolicy(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.displays) ~= "table" then
    return
  end
  if snapshot.status ~= "ok" then
    return
  end

  local builtinPort, builtinEnabled = nil, false
  local externals, enabledTotal = {}, 0
  for _, display in ipairs(snapshot.displays) do
    if display.enabled then
      enabledTotal += 1
    end
    if isBuiltinPort(display.port) then
      builtinPort = display.port
      builtinEnabled = display.enabled
    elseif display.enabled then
      table.insert(externals, display.port)
    end
  end

  local key = table.concat(externals, ",")
  if key == policyEpoch and not forcePolicyApply then
    return
  end
  local forced = forcePolicyApply
  policyEpoch = key
  forcePolicyApply = false

  local commands, labels = {}, {}

  if #externals > 0 then
    if policy.internal_off_with_external and builtinPort ~= nil and builtinEnabled
      and enabledTotal > 1 then
      table.insert(commands, "niri msg output " .. quoteShellArgument(builtinPort) .. " off")
      table.insert(labels, "关闭内置屏")
    elseif forced and not policy.internal_off_with_external and builtinPort ~= nil
      and not builtinEnabled then
      table.insert(commands, "niri msg output " .. quoteShellArgument(builtinPort) .. " on")
      table.insert(labels, "打开内置屏")
    end
    if policy.focus_external and snapshot.focused_output ~= externals[1]
      and (snapshot.focused_output == nil or isBuiltinPort(snapshot.focused_output)) then
      table.insert(commands, "niri msg action focus-monitor " .. quoteShellArgument(externals[1]))
      table.insert(labels, "焦点移到 " .. externals[1])
    end
  elseif policy.internal_off_with_external and builtinPort ~= nil and not builtinEnabled then
    -- 外接屏全拔了：把内屏开回来，别留一块黑屏
    table.insert(commands, "niri msg output " .. quoteShellArgument(builtinPort) .. " on")
    table.insert(labels, "恢复内置屏")
  end

  for index, command in ipairs(commands) do
    local label = labels[index]
    noctalia.log("niri-displays: policy " .. label .. ": " .. command)
    local started = noctalia.runAsync(command, function(result)
      if result.exitCode ~= 0 then
        local message = commandError(result, tr("error.command"))
        noctalia.log("niri-displays: policy command failed: " .. message)
        noctalia.notify(tr("policy.failed"), label .. "失败：" .. message)
      end
      startRefresh()
    end, COMMAND_TIMEOUT_MS)
    if not started then
      noctalia.log("niri-displays: could not start policy command: " .. command)
    end
  end
end

-- ── 相邻保持：一块屏逻辑尺寸变了，邻屏跟着重新推导位置 ─────────────────────
-- niri 按字面坐标摆输出，不吸附：缩放/分辨率/旋转让逻辑宽高变化后，原来贴边的
-- 邻屏会留下指针穿不过去的死区。这里按「原来的边间距」重推邻屏位置，只动原本
-- 在该轴上贴边/分离的屏，重叠的跳过；手动摆的位置（尺寸没变）不会被碰。
local lastGeometryByPort = {}
local repositionBusy = false

local function isRotatedSideways(transform)
  return transform == "90" or transform == "270"
    or transform == "flipped-90" or transform == "flipped-270"
end

local function logicalSizeOf(display)
  local scale = display.scale > 0 and display.scale or 1
  local width = display.width / scale
  local height = display.height / scale
  if isRotatedSideways(display.transform) then
    return height, width
  end
  return width, height
end

local function planNeighborMoves(displays)
  local rects = {}
  local changed = nil
  for _, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local w, h = logicalSizeOf(display)
      rects[display.port] = { x = display.x, y = display.y, w = w, h = h }
      local old = lastGeometryByPort[display.port]
      if changed == nil and old ~= nil
        and (math.abs(old.w - w) > 0.5 or math.abs(old.h - h) > 0.5) then
        changed = display.port
      end
    end
  end
  if changed == nil then
    return {}
  end

  local oldP = lastGeometryByPort[changed]
  local newP = rects[changed]
  local moves = {}
  for _, display in ipairs(displays) do
    local port = display.port
    local newO = rects[port]
    if port ~= changed and newO ~= nil then
      local oldO = lastGeometryByPort[port] or newO
      local x, y = newO.x, newO.y
      local gapRight = oldO.x - (oldP.x + oldP.w)
      local gapLeft = oldP.x - (oldO.x + oldO.w)
      local gapBottom = oldO.y - (oldP.y + oldP.h)
      local gapTop = oldP.y - (oldO.y + oldO.h)
      if gapRight >= -1 then
        x = newP.x + newP.w + gapRight
      elseif gapLeft >= -1 then
        x = newP.x - oldO.w - gapLeft
      elseif gapBottom >= -1 then
        y = newP.y + newP.h + gapBottom
      elseif gapTop >= -1 then
        y = newP.y - oldO.h - gapTop
      end
      x, y = math.floor(x + 0.5), math.floor(y + 0.5)
      if math.abs(x - newO.x) > 0.5 or math.abs(y - newO.y) > 0.5 then
        table.insert(moves, { port = port, x = x, y = y })
      end
    end
  end
  return moves
end

local function rememberGeometry(displays)
  for _, display in ipairs(displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local w, h = logicalSizeOf(display)
      lastGeometryByPort[display.port] = { x = display.x, y = display.y, w = w, h = h }
    end
  end
end

local function repositionNeighbors(displays)
  if repositionBusy then
    return
  end
  local moves = planNeighborMoves(displays)
  rememberGeometry(displays)
  if #moves == 0 then
    return
  end
  local parts = {}
  for _, move in ipairs(moves) do
    table.insert(parts, "niri msg output " .. quoteShellArgument(move.port)
      .. " position set -- " .. move.x .. " " .. move.y)
    noctalia.log("niri-displays: keep adjacency, move " .. move.port
      .. " to " .. move.x .. "," .. move.y)
  end
  repositionBusy = true
  local started = noctalia.runAsync(table.concat(parts, " && "), function(result)
    repositionBusy = false
    if result.exitCode ~= 0 then
      noctalia.log("niri-displays: adjacency move failed: "
        .. commandError(result, tr("error.command")))
    else
      persistPending = true
    end
    startRefresh()
  end, COMMAND_TIMEOUT_MS)
  if not started then
    repositionBusy = false
  end
end

-- ── 一键布局：IPC / 快捷入口共用的命令生成与执行 ────────────────────────────
-- 逻辑与面板按钮一致：缺内置屏或外接屏时直接报错，绝不生成「全关」命令。
local function modeLogicalSize(display)
  if display.enabled and display.width > 0 and display.height > 0 then
    return logicalSizeOf(display)
  end
  local mode = nil
  for _, candidate in ipairs(display.modes or {}) do
    if candidate.preferred then
      mode = candidate
      break
    end
  end
  mode = mode or (display.modes or {})[1]
  if mode == nil then
    return { width = 0, height = 0 }
  end
  local scale = display.scale > 0 and display.scale or 1
  local width, height = mode.width / scale, mode.height / scale
  if isRotatedSideways(display.transform) then
    return { width = height, height = width }
  end
  return { width = width, height = height }
end

local function presetCommands(kind, displays)
  local external, builtin = nil, nil
  for _, display in ipairs(displays) do
    if isBuiltinPort(display.port) then
      builtin = builtin or display
    else
      external = external or display
    end
  end

  local commands = {}
  if kind == "dual" then
    if external == nil or builtin == nil then
      return nil, "panel.preset_need_two"
    end
    local extSize = modeLogicalSize(external)
    if not external.enabled then
      table.insert(commands, "niri msg output " .. quoteShellArgument(external.port) .. " on")
    end
    table.insert(commands, "niri msg output " .. quoteShellArgument(external.port) .. " position set -- 0 0")
    if not builtin.enabled then
      table.insert(commands, "niri msg output " .. quoteShellArgument(builtin.port) .. " on")
    end
    table.insert(commands, "niri msg output " .. quoteShellArgument(builtin.port)
      .. " position set -- " .. tostring(math.floor(extSize.width + 0.5)) .. " 0")
  elseif kind == "laptop" or kind == "external" then
    local wantBuiltin = kind == "laptop"
    if wantBuiltin and builtin == nil then
      return nil, "panel.preset_need_builtin"
    end
    if not wantBuiltin and external == nil then
      return nil, "panel.preset_need_external"
    end
    for _, display in ipairs(displays) do
      local keep = isBuiltinPort(display.port) == wantBuiltin
      if display.enabled ~= keep then
        table.insert(commands, "niri msg output " .. quoteShellArgument(display.port) .. (keep and " on" or " off"))
      end
    end
  elseif kind == "all" then
    for _, display in ipairs(displays) do
      if not display.enabled then
        table.insert(commands, "niri msg output " .. quoteShellArgument(display.port) .. " on")
      end
    end
  else
    return nil, "panel.preset_need_two"
  end
  return commands
end

local function applyPreset(kind)
  if type(kind) ~= "string" or kind == "" then
    return
  end
  local snapshot = noctalia.state.get(STATE_KEY)
  if type(snapshot) ~= "table" or type(snapshot.displays) ~= "table" then
    return
  end
  local commands, errKey = presetCommands(kind, snapshot.displays)
  if commands == nil then
    noctalia.notify(tr("policy.failed"), tr(errKey))
    return
  end
  if #commands == 0 then
    startRefresh()
    return
  end
  local command = table.concat(commands, " && ")
  noctalia.log("niri-displays: preset " .. kind .. ": " .. command)
  local started = noctalia.runAsync(command, function(result)
    if result.exitCode == 0 then
      persistPending = true
      startRefresh()
    else
      noctalia.notify(tr("policy.failed"), commandError(result, tr("error.command")))
    end
  end, COMMAND_TIMEOUT_MS)
  if not started then
    noctalia.notify(tr("policy.failed"), tr("error.command"))
  end
end

startRefresh = function()
  if fetching then
    refreshQueued = true
    return
  end
  if not noctalia.commandExists("niri") then
    noctalia.state.set(STATE_KEY, initialSnapshot("error", tr("error.niri_missing")))
    return
  end

  fetching = true
  lastFullRefreshAt = tonumber(noctalia.formatTime("%s")) or 0
  generation += 1
  local thisGeneration = generation
  local pending = 2
  local rawOutputs = nil
  local focusedName = nil
  local outputsError = ""

  local previous = shallowCopy(noctalia.state.get(STATE_KEY))
  previous.status = #previous.displays > 0 and "refreshing" or "loading"
  previous.error_message = ""
  noctalia.state.set(STATE_KEY, previous)

  local function completeOne()
    if thisGeneration ~= generation then
      return
    end
    pending -= 1
    if pending > 0 then
      return
    end

    fetching = false
    if rawOutputs == nil then
      local stale = shallowCopy(noctalia.state.get(STATE_KEY))
      stale.status = "error"
      stale.error_message = outputsError ~= "" and outputsError or tr("error.outputs")
      noctalia.state.set(STATE_KEY, stale)
    else
      local nextSnapshot = normalizeOutputs(rawOutputs, focusedName, thisGeneration)
      applyPresetsForResolutionChanges(nextSnapshot)
      repositionNeighbors(nextSnapshot.displays)
      noctalia.state.set(STATE_KEY, nextSnapshot)
      if persistPending then
        persistPending = false
        writeOutputsFile(nextSnapshot)
      end
      applyConnectionPolicy(nextSnapshot)
    end

    if refreshQueued then
      refreshQueued = false
      startRefresh()
    end
  end

  local outputsStarted = noctalia.runAsync("niri msg --json outputs", function(result)
    if thisGeneration ~= generation then
      return
    end
    if result.exitCode == 0 and not result.stdoutTruncated then
      local decoded = noctalia.json.decode(result.stdout or "")
      if type(decoded) == "table" then
        rawOutputs = decoded
      else
        outputsError = tr("error.parse_outputs")
      end
    else
      outputsError = commandError(result, tr("error.outputs"))
    end
    completeOne()
  end, COMMAND_TIMEOUT_MS)
  if not outputsStarted then
    outputsError = tr("error.outputs")
    completeOne()
  end

  local focusStarted = noctalia.runAsync("niri msg --json focused-output", function(result)
    if thisGeneration ~= generation then
      return
    end
    if result.exitCode == 0 and not result.stdoutTruncated then
      local decoded = noctalia.json.decode(result.stdout or "")
      if type(decoded) == "table" and type(decoded.name) == "string" then
        focusedName = decoded.name
      end
    end
    completeOne()
  end, COMMAND_TIMEOUT_MS)
  if not focusStarted then
    completeOne()
  end
end

noctalia.setUpdateInterval(FOCUS_CHECK_INTERVAL_MS)

noctalia.state.watch("refresh_requested", function(value)
  local nonce = tonumber(value) or 0
  if nonce ~= lastRefreshNonce then
    lastRefreshNonce = nonce
    startRefresh()
  end
end)

-- 面板改完布局后 bump：等这一轮刷新拿到最新快照，再把它写进 include 文件。
local lastPersistNonce = noctalia.state.get("persist_requested") or 0
noctalia.state.watch("persist_requested", function(value)
  local nonce = tonumber(value) or 0
  if nonce ~= lastPersistNonce then
    lastPersistNonce = nonce
    persistPending = true
    startRefresh()
  end
end)

-- 面板拨开关 → 这里落盘，并立刻重新跑一遍策略（force：即使外接屏集合没变也执行）。
local lastPolicyNonce = tonumber(noctalia.state.get("policy_requested")) or 0
noctalia.state.watch("policy_requested", function(value)
  local nonce = tonumber(value) or 0
  if nonce == lastPolicyNonce then
    return
  end
  lastPolicyNonce = nonce
  local requested = noctalia.state.get("policy_set")
  if type(requested) == "table" then
    if type(requested.focus_external) == "boolean" then
      policy.focus_external = requested.focus_external
    end
    if type(requested.internal_off_with_external) == "boolean" then
      policy.internal_off_with_external = requested.internal_off_with_external
    end
  end
  savePolicy()
  forcePolicyApply = true
  policyEpoch = nil
  startRefresh()
end)

-- 快捷入口 / 面板外部触发：bump preset_requested + 写 preset_kind。
local lastPresetNonce = tonumber(noctalia.state.get("preset_requested")) or 0
noctalia.state.watch("preset_requested", function(value)
  local nonce = tonumber(value) or 0
  if nonce == lastPresetNonce then
    return
  end
  lastPresetNonce = nonce
  local kind = noctalia.state.get("preset_kind")
  if type(kind) == "string" and kind ~= "" then
    applyPreset(kind)
  end
end)

loadPolicy()
noctalia.state.set(STATE_KEY, initialSnapshot("loading", ""))
startRefresh()

function update()
  syncFocusedOutput()
  if (tonumber(noctalia.formatTime("%s")) or 0) - lastFullRefreshAt >= readFallbackIntervalSeconds() then
    startRefresh()
  end
end

function onConfigChanged()
  forcePresetCheck = true
  startRefresh()
end

-- Native Noctalia service hook. Niri output mode, scale, and hotplug changes
-- propagate through wl_output and arrive here without waiting for the fallback
-- polling interval.
function onOutputsChanged()
  noctalia.log("niri-displays: output change hook")
  startRefresh()
end

function onIpc(event, payload)
  if event == "refresh" then
    startRefresh()
  elseif event == "save" then
    writeOutputsFile(noctalia.state.get(STATE_KEY))
  elseif event == "primary" then
    if type(payload) == "string" and payload ~= "" then
      noctalia.state.set("primary_port", payload)
      primaryPort = payload
      writeOutputsFile(noctalia.state.get(STATE_KEY))
    end
  elseif event == "policy" then
    -- 空 payload：打印当前策略；JSON payload：直接改（脚本化验证用，等价于面板拨开关）
    if type(payload) == "string" and payload ~= "" then
      local decoded = noctalia.json.decode(payload)
      if type(decoded) == "table" then
        if type(decoded.focus_external) == "boolean" then
          policy.focus_external = decoded.focus_external
        end
        if type(decoded.internal_off_with_external) == "boolean" then
          policy.internal_off_with_external = decoded.internal_off_with_external
        end
        savePolicy()
        forcePolicyApply = true
        policyEpoch = nil
        startRefresh()
      else
        noctalia.log("niri-displays: policy payload is not JSON")
      end
    else
      noctalia.log("niri-displays: policy " .. (noctalia.json.encode(policy) or "?")
        .. " epoch=" .. tostring(policyEpoch) .. " file=" .. policyFilePath())
    end
  elseif event == "preset" then
    if type(payload) == "string" and payload ~= "" then
      applyPreset(payload)
    end
  elseif event == "dump" then
    local snapshot = noctalia.state.get(STATE_KEY)
    noctalia.log("niri-displays: " .. (noctalia.json.encode(snapshot) or "?"))
  end
end
