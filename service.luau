--!nonstrict
-- Headless service: reads the authoritative output state from Niri's JSON IPC
-- and publishes a normalized snapshot for the bar widget and panel.

local STATE_KEY = "display_snapshot"
-- 兜底轮询：onOutputsChanged 钩子是主路径（本机 2026-11-27 验证会触发），
-- 轮询只负责兜底，默认 90s 以减少 niri 子进程；钩子不可靠的环境把 refresh_interval 设回 30。
local DEFAULT_FALLBACK_INTERVAL_S = 90
local MIN_FALLBACK_INTERVAL_S = 5
-- 焦点变化 500ms 内被看到足够；100ms 时每秒 10 次唤醒没有可见收益。
local FOCUS_CHECK_INTERVAL_MS = 500
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
local presetOperation = nil

local tr = noctalia.tr

-- 单次 host 回调抛错不应带走整个 service：记日志后继续。
-- 包裹 update / onIpc / 每个 runAsync 回调，异常只损失这一轮刷新。
local function guarded(label, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      noctalia.log("niri-displays: " .. label .. " failed: " .. tostring(err))
    end
  end
end

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
  return math.clamp(seconds, MIN_FALLBACK_INTERVAL_S, 300)
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
  local make = noctalia.string.trim(type(output.make) == "string" and output.make or "")
  local model = noctalia.string.trim(type(output.model) == "string" and output.model or "")
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
  local byIndex = {}
  for index, raw in ipairs(type(rawModes) == "table" and rawModes or {}) do
    if type(raw) == "table" then
      local width = tonumber(raw.width)
      local height = tonumber(raw.height)
      local refresh = tonumber(raw.refresh_rate)
      if width and width > 0 and height and height > 0 and refresh and refresh > 0 then
        local mode = {
          width = width,
          height = height,
          refresh_rate = refresh,
          preferred = raw.is_preferred == true,
        }
        table.insert(modes, mode)
        byIndex[index - 1] = mode
      end
    end
  end
  return modes, byIndex
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
local OUTPUTS_HEADER = "// 本文件由 Noctalia 插件 xendr1a/niri-displays 自动生成；改布局请用面板（右上角显示器图标）。"
local AUTO_PRIMARY_MARKER = "// startup-primary: auto"
local persistPending = false
local layoutCandidate = nil

local function outputsFilePath()
  local configured = noctalia.getConfig("outputs_file")
  if type(configured) ~= "string" or noctalia.string.trim(configured) == "" then
    configured = DEFAULT_OUTPUTS_FILE
  end
  local path = noctalia.expandPath(noctalia.string.trim(configured))
  if path:sub(1, 1) ~= "/" then
    local directory = noctalia.pluginDir()
    if directory then
      return directory .. "/" .. path
    end
  end
  return path
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
local loadedPolicyPath = nil

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
  local path = policyFilePath()
  if path == loadedPolicyPath then
    return
  end
  forcePolicyApply = loadedPolicyPath ~= nil
  loadedPolicyPath = path
  policyEpoch = nil
  policy.focus_external = true
  policy.internal_off_with_external = false
  local raw = noctalia.readFile(path)
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
      noctalia.notify(tr("policy.failed"), tostring(err))
    end
  end
  publishPolicy()
end

-- 读回上次写出的文件：拿到主屏标记，并为当前关掉的输出保留上次的 mode/scale 等。
local function readExistingBlocks(text)
  local blocks = {}
  local firstPrimary = nil
  if type(text) ~= "string" then
    return blocks, firstPrimary
  end
  for port, bodyText in text:gmatch('output%s+"([^"]+)"%s*{([^}]*)}') do
    local block = {}
    block.mode = bodyText:match('mode%s+"([^"]+)"')
    block.scale = bodyText:match('scale%s+([%d%.]+)')
    block.transform = bodyText:match('transform%s+"([^"]+)"')
    block.x, block.y = bodyText:match('position%s+x%s*=%s*(-?%d+)%s+y%s*=%s*(-?%d+)')
    block.vrr = bodyText:find("variable-refresh-rate", 1, true) ~= nil
    if firstPrimary == nil and bodyText:find("focus-at-startup", 1, true) ~= nil then
      firstPrimary = port
    end
    blocks[port] = block
  end
  if text:find("\n" .. AUTO_PRIMARY_MARKER .. "\n", 1, true) then
    firstPrimary = nil
  end
  return blocks, firstPrimary
end

local function layoutError(path, key, detail)
  local message = path .. "\n" .. tr(key)
  if detail ~= nil and detail ~= "" then
    message = message .. "\n" .. detail
  end
  noctalia.log("niri-displays: " .. message)
  noctalia.notify(tr("error.layout_write"), message)
end

local function managedLayout(text)
  return type(text) == "string" and (not text:find("%S") or text:match("^[^\r\n]*") == OUTPUTS_HEADER)
end

local function loadPrimary()
  local path = outputsFilePath()
  if noctalia.state.get("primary_layout_path") == path then
    return
  end
  local text = noctalia.readFile(path)
  local savedPrimary = nil
  if managedLayout(text) then
    local _, primary = readExistingBlocks(text)
    savedPrimary = primary
  end
  noctalia.state.set("primary_port", savedPrimary or "")
  noctalia.state.set("primary_layout_path", path)
end

local function writeOutputsFile(snapshot)
  if snapshot.status ~= "ok" or #snapshot.displays == 0 then
    return
  end

  local path = outputsFilePath()
  local previous, readError = noctalia.readFile(path)
  if previous == nil and noctalia.fileExists(path) then
    layoutError(path, "error.layout_write", readError)
    return
  elseif previous ~= nil and not managedLayout(previous) then
    layoutError(path, "error.layout_unmanaged")
    return
  end

  local existing = readExistingBlocks(previous)
  local requestedPrimary = noctalia.state.get("primary_port")
  local primaryPort = type(requestedPrimary) == "string" and requestedPrimary ~= "" and requestedPrimary or nil

  local lines = {
    OUTPUTS_HEADER,
    "// 关闭(off)状态不会被写入，避免拔掉外接屏后一个可用的输出都没有。",
    "// 开机焦点按 focus-at-startup 出现的先后决定。",
  }
  if primaryPort == nil then
    table.insert(lines, AUTO_PRIMARY_MARKER)
  end
  table.insert(lines, "")

  -- Niri 以文件顺序决定开机焦点。未指定主屏时，选一块外接屏优先，内置屏兜底。
  local focusFlags = {}
  if primaryPort == nil then
    for _, display in ipairs(snapshot.displays) do
      if not isBuiltinPort(display.port) then
        primaryPort = display.port
        break
      end
    end
  end
  if primaryPort ~= nil then
    focusFlags[primaryPort] = true
  end
  for _, display in ipairs(snapshot.displays) do
    if isBuiltinPort(display.port) then
      focusFlags[display.port] = true
    end
  end
  local entries = {}
  local seenPorts = {}
  for _, display in ipairs(snapshot.displays) do
    local port = display.port
    seenPorts[port] = true
    local old = existing[port] or {}
    local live = display.enabled and display.width > 0 and display.height > 0
    local vrr = old.vrr
    if live then
      vrr = display.vrr_enabled
    end
    table.insert(entries, {
      port = port,
      mode = live
          and string.format("%dx%d@%.3f", display.width, display.height, display.refresh_rate / 1000)
        or old.mode,
      scale = live and formatScale(display.scale) or old.scale,
      transform = live and display.transform or old.transform,
      vrr = vrr,
      x = live and tostring(math.floor(display.x + 0.5)) or old.x,
      y = live and tostring(math.floor(display.y + 0.5)) or old.y,
    })
  end
  -- 当前没接的输出保留上次的布局：拔掉再插回来、或者下次开机时直接沿用，
  -- 不用重新调分辨率/缩放/位置。
  for port, old in pairs(existing) do
    if not seenPorts[port] then
      if isBuiltinPort(port) then
        focusFlags[port] = true
      end
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

  -- 主屏放在首位，其余内置屏作为开机焦点的兜底。
  table.sort(entries, function(a, b)
    local function rank(entry)
      if entry.port == primaryPort then
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
    if entry.mode ~= nil or entry.transform ~= nil or focusFlags[port] then
      local escapedPort = port:gsub('[\\"]', '\\%0')
      table.insert(lines, 'output "' .. escapedPort .. '" {')
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

  local content = table.concat(lines, "\n")
  if previous == content then
    return
  end

  -- 校验同目录的临时文件，避免 niri 在校验前加载到未完成的布局。
  local candidate = path .. string.format(".tmp-%.0f-%d", noctalia.nowMs(), math.random(100000, 999999))
  local ok, err = noctalia.writeFile(candidate, content)
  if not ok then
    noctalia.removeFile(candidate)
    layoutError(path, "error.layout_write", err)
    return
  end

  local function finishLayoutWrite(key, detail)
    noctalia.removeFile(candidate)
    layoutCandidate = nil
    if key ~= nil then
      layoutError(path, key, detail)
    end
    if persistPending then
      startRefresh()
    end
  end

  layoutCandidate = candidate
  local started = noctalia.runAsync({ "niri", "validate", "--config", candidate }, guarded("validate-layout", function(result)
    if result.exitCode ~= 0 or result.timedOut then
      local details = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]*") or ""
      finishLayoutWrite("error.layout_invalid", details)
      return
    end
    if outputsFilePath() ~= path or noctalia.readFile(path) ~= previous
      or (previous == nil and noctalia.fileExists(path)) then
      finishLayoutWrite("error.layout_changed")
      return
    end
    if persistPending or presetOperation or noctalia.state.get("display_action_pending") == true then
      persistPending = true
      finishLayoutWrite()
      return
    end
    if previous ~= nil then
      local backup = candidate .. ".bak"
      local copied, backupError = noctalia.writeFile(backup, previous)
      if copied then
        copied, backupError = noctalia.renameFile(backup, path .. ".bak")
      end
      if not copied then
        noctalia.removeFile(backup)
        finishLayoutWrite("error.layout_write", backupError)
        return
      end
    end

    local replaced, replaceError = noctalia.renameFile(candidate, path)
    if not replaced then
      finishLayoutWrite("error.layout_write", replaceError)
      return
    end
    noctalia.log("niri-displays: validated and saved layout: " .. path)
    finishLayoutWrite()
  end), 8000)

  if not started then
    finishLayoutWrite("error.layout_invalid", tr("error.command"))
  end
end

local function normalizeOutputs(rawOutputs, focusedName, revision)
  local displays = {}
  for connector, raw in pairs(rawOutputs) do
    if type(connector) == "string" and type(raw) == "table" then
      local modes, modesByIndex = normalizeModes(raw.modes)
      local currentIndex = tonumber(raw.current_mode)
      local currentMode = currentIndex and modesByIndex[currentIndex] or nil
      local logical = type(raw.logical) == "table" and raw.logical or nil
      table.insert(displays, {
        name = displayLabel(raw, connector),
        port = connector,
        make = type(raw.make) == "string" and raw.make or "",
        model = type(raw.model) == "string" and raw.model or "",
        serial = type(raw.serial) == "string" and raw.serial or "",
        focused = connector == focusedName,
        enabled = logical ~= nil and currentMode ~= nil,
        x = logical and (tonumber(logical.x) or 0) or 0,
        y = logical and (tonumber(logical.y) or 0) or 0,
        scale = logical and (tonumber(logical.scale) or 1) or 1,
        transform = logical and normalizeTransform(logical.transform) or "normal",
        width = currentMode and currentMode.width or 0,
        height = currentMode and currentMode.height or 0,
        logical_width = logical and tonumber(logical.width) or nil,
        logical_height = logical and tonumber(logical.height) or nil,
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
          local started = noctalia.runAsync(command, guarded("auto-scale", function(result)
            presetApplying[port] = nil
            if result.exitCode ~= 0 then
              noctalia.log("niri-displays: automatic scale failed for " .. port .. ": "
                .. commandError(result, tr("error.command")))
            end
            startRefresh()
          end), COMMAND_TIMEOUT_MS)
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
local policyCommandsPending = 0

local function connectionPolicyKey(displays)
  local ports = {}
  for _, display in ipairs(displays) do
    if display.enabled and not isBuiltinPort(display.port) then
      table.insert(ports, display.port)
    end
  end
  table.sort(ports)
  return table.concat(ports, ",")
end

local function applyConnectionPolicy(snapshot)
  if policyCommandsPending > 0 or snapshot.status ~= "ok" then
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

  local key = connectionPolicyKey(snapshot.displays)
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
      table.insert(labels, tr("policy.turn_internal_off"))
    elseif forced and not policy.internal_off_with_external and builtinPort ~= nil
      and not builtinEnabled then
      table.insert(commands, "niri msg output " .. quoteShellArgument(builtinPort) .. " on")
      table.insert(labels, tr("policy.turn_internal_on"))
    end
    if policy.focus_external and snapshot.focused_output ~= externals[1]
      and (snapshot.focused_output == nil or isBuiltinPort(snapshot.focused_output)) then
      table.insert(commands, "niri msg action focus-monitor " .. quoteShellArgument(externals[1]))
      table.insert(labels, tr("policy.focus_output", { port = externals[1] }))
    end
  elseif policy.internal_off_with_external and builtinPort ~= nil and not builtinEnabled then
    -- 外接屏全拔了：把内屏开回来，别留一块黑屏
    table.insert(commands, "niri msg output " .. quoteShellArgument(builtinPort) .. " on")
    table.insert(labels, tr("policy.restore_internal"))
  end

  for index, command in ipairs(commands) do
    local label = labels[index]
    noctalia.log("niri-displays: policy " .. label .. ": " .. command)
    policyCommandsPending += 1
    local started = noctalia.runAsync(command, guarded("connection-policy", function(result)
      policyCommandsPending -= 1
      if result.exitCode ~= 0 then
        local message = commandError(result, tr("error.command"))
        noctalia.log("niri-displays: policy command failed: " .. message)
        noctalia.notify(tr("policy.failed"), label .. "\n" .. message)
      end
      startRefresh()
    end), COMMAND_TIMEOUT_MS)
    if not started then
      policyCommandsPending -= 1
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
  if display.logical_width and display.logical_width > 0
    and display.logical_height and display.logical_height > 0 then
    return display.logical_width, display.logical_height
  end
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
    local oldO = lastGeometryByPort[port]
    if port ~= changed and newO ~= nil and oldO ~= nil then
      local x, y = newO.x, newO.y
      local gapRight = oldO.x - (oldP.x + oldP.w)
      local gapLeft = oldP.x - (oldO.x + oldO.w)
      local gapBottom = oldO.y - (oldP.y + oldP.h)
      local gapTop = oldP.y - (oldO.y + oldO.h)
      local verticalOverlap = oldO.y < oldP.y + oldP.h and oldP.y < oldO.y + oldO.h
      local horizontalOverlap = oldO.x < oldP.x + oldP.w and oldP.x < oldO.x + oldO.w
      if verticalOverlap and gapRight >= -1 then
        x = newP.x + newP.w + gapRight
      elseif verticalOverlap and gapLeft >= -1 then
        x = newP.x - newO.w - gapLeft
      elseif horizontalOverlap and gapBottom >= -1 then
        y = newP.y + newP.h + gapBottom
      elseif horizontalOverlap and gapTop >= -1 then
        y = newP.y - newO.h - gapTop
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
  local started = noctalia.runAsync(table.concat(parts, " && "), guarded("adjacency-move", function(result)
    repositionBusy = false
    if result.exitCode ~= 0 then
      noctalia.log("niri-displays: adjacency move failed: "
        .. commandError(result, tr("error.command")))
    else
      persistPending = true
    end
    startRefresh()
  end), COMMAND_TIMEOUT_MS)
  if not started then
    repositionBusy = false
  end
end

local function presetTargetPorts(kind, displays)
  local ports = {}
  local external, builtin = nil, nil
  for _, display in ipairs(displays) do
    local port = display.port
    if isBuiltinPort(port) then
      builtin = builtin or port
    else
      external = external or port
    end
    if kind == "all" or isBuiltinPort(port) == (kind == "laptop") then
      ports[port] = true
    end
  end

  if kind == "dual" then
    if external == nil or builtin == nil then
      return nil, "panel.preset_need_two"
    end
    return { [builtin] = true, [external] = true }
  elseif kind == "laptop" and builtin == nil then
    return nil, "panel.preset_need_builtin"
  elseif kind == "external" and external == nil then
    return nil, "panel.preset_need_external"
  end
  return ports
end

local function publishPresetStatus(pending, message)
  noctalia.state.set("preset_status", { pending = pending, error_message = message or "" })
  if message then
    noctalia.notify(tr("error.preset_title"), message)
  end
end

local function finishPreset(snapshot, message)
  local operation = presetOperation
  presetOperation = nil
  if snapshot and not message then
    -- The user chose this layout. Resume automatic policy at the next change.
    policyEpoch = connectionPolicyKey(snapshot.displays)
    if operation.kind == "dual" then
      persistPending = true
    end
  end
  if snapshot and forcePolicyApply then
    refreshQueued = true
  end
  publishPresetStatus(false, message)
end

local function requestPresetSnapshot(stage)
  presetOperation.stage = stage
  presetOperation.snapshotAfter = generation
  startRefresh()
end

local function runPresetCommands(commands, stage)
  presetOperation.stage = nil
  local command = table.concat(commands, " && ")
  noctalia.log("niri-displays: preset " .. presetOperation.kind .. ": " .. command)
  local started = noctalia.runAsync(command, guarded("preset-command", function(result)
    if result.exitCode ~= 0 then
      presetOperation.error_message = commandError(result, tr("error.command"))
    end
    requestPresetSnapshot(stage)
  end), COMMAND_TIMEOUT_MS)
  if not started then
    presetOperation.error_message = tr("error.command")
    requestPresetSnapshot(stage)
  end
end

local function presetCanAdvance(snapshot)
  return presetOperation.stage ~= nil and snapshot.revision > presetOperation.snapshotAfter
    and policyCommandsPending == 0 and not repositionBusy and next(presetApplying) == nil
    and noctalia.state.get("display_action_pending") ~= true
end

local function retryPresetSnapshot()
  if presetOperation.retries == 0 then
    return false
  end
  presetOperation.retries -= 1
  requestPresetSnapshot(presetOperation.stage)
  return true
end

local function advancePreset(snapshot)
  if not presetCanAdvance(snapshot) then
    return
  end
  local operation = presetOperation
  if operation.error_message then
    finishPreset(snapshot, operation.error_message)
    return
  end

  if operation.stage == "prepare" then
    local ports, errorKey = presetTargetPorts(operation.kind, snapshot.displays)
    if not ports then
      finishPreset(snapshot, tr(errorKey))
      return
    end
    operation.ports = ports
    local enable = {}
    for _, display in ipairs(snapshot.displays) do
      if ports[display.port] and not display.enabled then
        table.insert(enable, "niri msg output " .. quoteShellArgument(display.port) .. " on")
      end
    end
    if #enable > 0 then
      operation.retries = 2
      runPresetCommands(enable, "enabled")
      return
    end
  end

  local active = {}
  local commands = {}
  for _, display in ipairs(snapshot.displays) do
    if display.enabled then
      active[display.port] = display
      if (operation.kind == "laptop" or operation.kind == "external")
        and isBuiltinPort(display.port) ~= (operation.kind == "laptop") then
        table.insert(commands, "niri msg output " .. quoteShellArgument(display.port) .. " off")
      end
    end
  end
  for port in pairs(operation.ports) do
    if not active[port] then
      if not retryPresetSnapshot() then
        finishPreset(snapshot, tr("error.preset_enable"))
      end
      return
    end
  end

  if operation.kind == "dual" then
    local builtin, external
    for port in pairs(operation.ports) do
      if isBuiltinPort(port) then
        builtin = active[port]
      else
        external = active[port]
      end
    end
    local logicalWidth = logicalSizeOf(external)
    local width = math.floor(logicalWidth + 0.5)
    if external.x ~= 0 or external.y ~= 0 or builtin.x ~= width or builtin.y ~= 0 then
      table.insert(commands, "niri msg output " .. quoteShellArgument(external.port) .. " position set -- 0 0")
      table.insert(commands, "niri msg output " .. quoteShellArgument(builtin.port)
        .. " position set -- " .. tostring(width) .. " 0")
    end
  end

  if #commands == 0 then
    finishPreset(snapshot)
  elseif operation.stage == "verify" then
    if not retryPresetSnapshot() then
      finishPreset(snapshot, tr("error.preset_incomplete"))
    end
  else
    operation.retries = 2
    runPresetCommands(commands, "verify")
  end
end

local function applyPreset(kind)
  if presetOperation then
    return
  end
  if kind ~= "laptop" and kind ~= "external" and kind ~= "dual" and kind ~= "all" then
    publishPresetStatus(false, tr("error.preset_unavailable"))
    return
  end
  presetOperation = { kind = kind, retries = 0 }
  publishPresetStatus(true)
  requestPresetSnapshot("prepare")
end

local function automaticActionsPending()
  return policyCommandsPending > 0 or repositionBusy or next(presetApplying) ~= nil
end

startRefresh = function()
  if fetching then
    refreshQueued = true
    return
  end
  lastFullRefreshAt = tonumber(noctalia.formatTime("%s")) or 0
  if not noctalia.commandExists("niri") then
    local message = tr("error.niri_missing")
    local stale = shallowCopy(noctalia.state.get(STATE_KEY))
    stale.status = "error"
    stale.error_message = message
    stale.actions_pending = automaticActionsPending()
    noctalia.state.set(STATE_KEY, stale)
    if presetOperation and presetOperation.stage then
      finishPreset(nil, message)
    end
    return
  end

  fetching = true
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

    if rawOutputs == nil then
      local stale = shallowCopy(noctalia.state.get(STATE_KEY))
      stale.status = "error"
      stale.error_message = outputsError ~= "" and outputsError or tr("error.outputs")
      stale.actions_pending = automaticActionsPending()
      noctalia.state.set(STATE_KEY, stale)
      if not refreshQueued and presetOperation and presetOperation.stage then
        finishPreset(nil, presetOperation.error_message or stale.error_message)
      end
    else
      local nextSnapshot = normalizeOutputs(rawOutputs, focusedName, thisGeneration)
      local applyingPreset = presetOperation ~= nil
      local panelBusy = noctalia.state.get("display_action_pending") == true
      if not refreshQueued and not panelBusy then
        if not applyingPreset or presetOperation.stage == "prepare" or presetOperation.stage == "enabled" then
          applyPresetsForResolutionChanges(nextSnapshot)
        end
        if applyingPreset then
          rememberGeometry(nextSnapshot.displays)
          advancePreset(nextSnapshot)
        elseif next(presetApplying) == nil then
          repositionNeighbors(nextSnapshot.displays)
          if not repositionBusy then
            applyConnectionPolicy(nextSnapshot)
          end
        end
      end
      nextSnapshot.actions_pending = automaticActionsPending()
      noctalia.state.set(STATE_KEY, nextSnapshot)
      if persistPending and not refreshQueued and not panelBusy and not layoutCandidate
        and not presetOperation and not nextSnapshot.actions_pending then
        persistPending = false
        writeOutputsFile(nextSnapshot)
      end
    end

    fetching = false
    if refreshQueued then
      refreshQueued = false
      startRefresh()
    end
  end

  local outputsStarted = noctalia.runAsync("niri msg --json outputs", guarded("refresh.outputs", function(result)
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
  end), COMMAND_TIMEOUT_MS)
  if not outputsStarted then
    outputsError = tr("error.outputs")
    completeOne()
  end

  local focusStarted = noctalia.runAsync("niri msg --json focused-output", guarded("refresh.focus", function(result)
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
  end), COMMAND_TIMEOUT_MS)
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

noctalia.state.watch("display_action_pending", function(value)
  if value == false then
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

loadPrimary()
loadPolicy()
publishPresetStatus(false)
noctalia.state.set(STATE_KEY, initialSnapshot("loading", ""))
startRefresh()

local function updateTick()
  syncFocusedOutput()
  if (tonumber(noctalia.formatTime("%s")) or 0) - lastFullRefreshAt >= readFallbackIntervalSeconds() then
    startRefresh()
  end
end

local updateGuarded = guarded("update", updateTick)

function update()
  updateGuarded()
end

function onConfigChanged()
  loadPrimary()
  loadPolicy()
  forcePresetCheck = true
  startRefresh()
end

function onExit()
  if layoutCandidate then
    noctalia.removeFile(layoutCandidate)
  end
end

-- Native Noctalia service hook. Niri output mode, scale, and hotplug changes
-- propagate through wl_output and arrive here without waiting for the fallback
-- polling interval.
function onOutputsChanged()
  noctalia.log("niri-displays: output change hook")
  startRefresh()
end

local function ipcHandler(event, payload)
  if event == "refresh" then
    startRefresh()
  elseif event == "save" then
    persistPending = true
    startRefresh()
  elseif event == "primary" then
    local snapshot = noctalia.state.get(STATE_KEY)
    for _, display in ipairs(snapshot.displays) do
      if display.port == payload then
        noctalia.state.set("primary_port", payload)
        persistPending = true
        startRefresh()
        break
      end
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

local ipcGuarded = guarded("ipc", ipcHandler)

function onIpc(event, payload)
  ipcGuarded(event, payload)
end
