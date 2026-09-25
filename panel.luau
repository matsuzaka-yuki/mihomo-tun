--!nonstrict
-- panel.luau —— 管理面板：开关、出口 IP、模式、策略组、节点、维护按钮。
-- 所有副作用都通过 state("cmd") 交给 service.luau 执行；本入口只读 state 与渲染。

local detail = noctalia.state.get("detail")
local mihomo = noctalia.state.get("mihomo") or { ok = false, service = "unknown", now = "" }
local groupview = noctalia.state.get("group")
local ipinfo = noctalia.state.get("ip")
local delayinfo = noctalia.state.get("delay")
local lastaction = noctalia.state.get("action")

local view_group = "PROXY"
local pending = ""
local nonce = 0

local MODES = { "rule", "global", "direct" }

-- [2026-09-25 补丁] 短名：去掉 "AUTO → " 前缀与 " | IEPL | x2" 后缀，避免撑爆布局
local function short_node(n)
  local x = tostring(n or "")
  x = x:gsub("^%s+", ""):gsub("%s+$", "")
  x = x:gsub("^.-→%s*", "")   -- 前缀
  x = x:gsub("%s*|.*$", "")   -- 后缀
  if x == "" then x = tostring(n or "") end
  return x
end

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function send(method, args, mark)
  nonce += 1
  pending = mark or method
  noctalia.state.set("cmd", {
    method = method,
    args = args or {},
    nonce = tostring(nonce) .. ":" .. tostring(os.time()),
    at = os.time(),
  })
  render()
end

-- 测速结果按节点名建索引，便于在节点行上显示延迟
local function delay_map()
  local map = {}
  if type(delayinfo) == "table" and type(delayinfo.results) == "table" then
    for _, item in ipairs(delayinfo.results) do
      if type(item) == "table" and item.name then map[item.name] = item.delay end
    end
  end
  return map
end

local function is_group(name)
  if type(detail) ~= "table" or type(detail.groups) ~= "table" then return false end
  for _, g in ipairs(detail.groups) do
    if g == name then return true end
  end
  return false
end

-- 与 Noctalia 控制中心一致：浮动面板提供外壳，内部用 surface_variant 卡片分层。
local function panel_card(children, extra)
  local props = {
    gap = 8,
    padding = 12,
    align = "stretch",
    fill = "surface_variant/0.76",
    border = "outline/0.52",
    borderWidth = 1,
    radius = 12,
  }
  for key, value in pairs(extra or {}) do props[key] = value end
  return ui.column(props, children)
end

local function section_title(text, trailing)
  local children = {
    ui.label({
      text = text,
      fontSize = 13,
      fontWeight = "semibold",
      color = "on_surface",
      flexGrow = 1,
      maxLines = 1,
    }),
  }
  if trailing then table.insert(children, trailing) end
  return ui.row({ gap = 8, align = "center" }, children)
end

local function header(rows)
  local on = mihomo.ok == true
  local node = tostring(mihomo.now or "")
  local short = node ~= "" and short_node(node) or (type(detail) == "table" and detail.mode or "")
  table.insert(rows, panel_card({
    ui.row({ gap = 12, align = "center" }, {
      ui.glyph({
        name = on and "shield-lock" or "plug-off",
        size = 24,
        color = on and "primary" or "on_surface_variant",
      }),
      ui.column({ gap = 3, flexGrow = 1 }, {
        ui.label({
          text = on and tr("panel.running") or tr("panel.stopped"),
          fontSize = 16,
          fontWeight = "bold",
          color = on and "primary" or "on_surface_variant",
          maxLines = 1,
        }),
        ui.label({
          text = short,
          fontSize = 12,
          color = "on_surface_variant",
          flexGrow = 1,
          maxLines = 1,
        }),
      }),
      ui.button({
        text = on and tr("panel.stop") or tr("panel.start"),
        glyph = on and "plug-off" or "shield-lock",
        fontSize = 12,
        variant = on and "secondary" or "primary",
        controlSize = "sm",
        enabled = pending == "",
        onClick = function() send("toggle", nil, "toggle") end,
      }),
    }),
  }))
end

local function ip_row(rows)
  local text = tr("panel.unknown")
  if type(ipinfo) == "table" and ipinfo.ip then text = tostring(ipinfo.ip) end
  table.insert(rows, panel_card({
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "world", size = 17, color = "on_surface_variant" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("panel.exit_ip"), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
        ui.label({
          text = text,
          fontSize = 14,
          fontWeight = "semibold",
          color = "on_surface",
          flexGrow = 1,
          maxLines = 1,
        }),
      }),
      ui.button({
        text = tr("panel.check_ip"),
        variant = "ghost",
        controlSize = "sm",
        fontSize = 12,
        enabled = pending == "",
        onClick = function() send("ip", nil, "ip") end,
      }),
    }),
  }))
end

local function mode_row()
  local current = (type(detail) == "table" and detail.mode) or ""
  local buttons = {}
  for _, m in ipairs(MODES) do
    table.insert(buttons, ui.button({
      text = tr("panel.mode_" .. m),
      variant = current == m and "primary" or "secondary",
      controlSize = "sm",
      fontSize = 12,
      flexGrow = 1,
      selected = current == m,
      enabled = pending == "",
      onClick = current ~= m and function() send("mode", { m }, "mode") end or nil,
    }))
  end
  return ui.column({ gap = 8, align = "stretch" }, {
    section_title(tr("panel.mode")),
    ui.row({ gap = 6, align = "stretch" }, buttons),
  })
end

local function group_row()
  if type(detail) ~= "table" or type(detail.groups) ~= "table" or #detail.groups == 0 then return nil end
  local group_rows = {}
  local current_row = {}
  for _, g in ipairs(detail.groups) do
    table.insert(current_row, ui.button({
      key = "mihomo-group-" .. g,
      text = g,
      variant = view_group == g and "primary" or "outline",
      controlSize = "sm",
      fontSize = 12,
      flexGrow = 1,
      selected = view_group == g,
      enabled = pending == "",
      onClick = view_group ~= g and function()
        view_group = g
        send("group", { g }, "group")
      end or nil,
    }))
    if #current_row == 4 then
      table.insert(group_rows, ui.row({ gap = 6, align = "stretch" }, current_row))
      current_row = {}
    end
  end
  if #current_row > 0 then
    table.insert(group_rows, ui.row({ gap = 6, align = "stretch" }, current_row))
  end
  return ui.column({ gap = 8, align = "stretch" }, {
    section_title(tr("panel.groups"), ui.label({
      text = tostring(#detail.groups),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    })),
    ui.column({ gap = 6, align = "stretch" }, group_rows),
  })
end

local function node_list(rows)
  local gv = groupview
  if type(gv) ~= "table" or gv.group ~= view_group then
    table.insert(rows, panel_card({
      section_title(tr("panel.nodes")),
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("panel.loading"), fontSize = 13, color = "on_surface_variant", flexGrow = 1 }),
        ui.button({
          text = tr("panel.refresh"),
          variant = "ghost",
          controlSize = "sm",
          fontSize = 12,
          onClick = function() send("group", { view_group }, "group") end,
        }),
      }),
    }, { flexGrow = 1 }))
    return
  end
  local delays = delay_map()
  local items = {}
  for _, name in ipairs(gv.nodes or {}) do
    local label = short_node(name)
    local d = delays[name]
    local is_current = (gv.now == name)
    local group_ref = is_group(name)
    local color = is_current and "on_primary" or "on_surface"
    local children = {
      ui.glyph({
        name = is_current and "check" or (group_ref and "corner-down-right" or "circle-filled"),
        size = 14,
        color = is_current and "on_primary" or (group_ref and "tertiary" or "outline"),
      }),
      ui.label({
        text = label,
        fontSize = 13,
        fontWeight = is_current and "semibold" or "normal",
        color = color,
        flexGrow = 1,
        maxLines = 1,
      }),
    }
    if d ~= nil then
      table.insert(children, ui.label({
        text = tostring(d) .. " ms",
        fontSize = 11,
        color = is_current and "on_primary/0.75" or "tertiary",
        maxLines = 1,
      }))
    end
    local props = {
      key = "mihomo-node-" .. name,
      gap = 8,
      align = "center",
      paddingH = 10,
      paddingV = 7,
      fill = is_current and "primary" or "surface/0.66",
      border = is_current and "primary" or "outline/0.48",
      borderWidth = 1,
      radius = 8,
    }
    -- 这里总是“选用到当前正在查看的组”，切换查看目标请用上面的策略组按钮。
    if not is_current and pending == "" then
      props.onClick = function() send("select", { view_group, name }, "select") end
    end
    table.insert(items, ui.row(props, children))
  end
  if #items == 0 then
    table.insert(rows, panel_card({
      section_title(tr("panel.nodes")),
      ui.label({ text = tr("panel.no_nodes"), fontSize = 13, color = "on_surface_variant" }),
    }, { flexGrow = 1 }))
    return
  end
  local node_children = {
    section_title(tr("panel.nodes"), ui.label({
      text = tostring(#items),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    })),
    ui.scroll({ key = "mihomo-node-scroll", flexGrow = 1, gap = 4 }, items),
  }
  if gv.truncated then
    table.insert(node_children, ui.label({
      text = tr("panel.truncated", { count = #items }),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end
  table.insert(rows, panel_card(node_children, { flexGrow = 1 }))
end

local function actions(rows)
  local common = {
    variant = "secondary",
    controlSize = "sm",
    fontSize = 12,
    flexGrow = 1,
    enabled = pending == "",
  }
  table.insert(rows, panel_card({
    ui.row({ gap = 6, align = "stretch" }, {
      ui.button({
        text = tr("panel.test_delay"),
        glyph = "gauge",
        variant = common.variant,
        controlSize = common.controlSize,
        fontSize = common.fontSize,
        flexGrow = common.flexGrow,
        enabled = common.enabled,
        onClick = function() send("delay", { view_group }, "delay") end,
      }),
      ui.button({
        text = tr("panel.web_panel"),
        glyph = "world",
        variant = common.variant,
        controlSize = common.controlSize,
        fontSize = common.fontSize,
        flexGrow = common.flexGrow,
        enabled = common.enabled,
        onClick = function() send("open-ui") end,
      }),
      ui.button({
        text = tr("panel.copy_secret"),
        glyph = "shield-check",
        variant = common.variant,
        controlSize = common.controlSize,
        fontSize = common.fontSize,
        flexGrow = common.flexGrow,
        enabled = common.enabled,
        onClick = function() send("secret") end,
      }),
    }),
    ui.row({ gap = 6, align = "stretch" }, {
      ui.button({
        text = tr("panel.update_provider"),
        glyph = "arrow-up-right",
        variant = common.variant,
        controlSize = common.controlSize,
        fontSize = common.fontSize,
        flexGrow = common.flexGrow,
        enabled = common.enabled,
        onClick = function() send("update-provider") end,
      }),
      ui.button({
        text = tr("panel.refresh"),
        glyph = "refresh",
        variant = "ghost",
        controlSize = common.controlSize,
        fontSize = common.fontSize,
        flexGrow = common.flexGrow,
        enabled = common.enabled,
        onClick = function() send("refresh") end,
      }),
    }),
  }))
end

local function status_line(rows)
  if pending ~= "" then
    table.insert(rows, ui.row({ gap = 8, paddingH = 10, paddingV = 8,
                                fill = "tertiary/0.10", border = "tertiary/0.32",
                                borderWidth = 1, radius = 10, align = "center" }, {
      ui.glyph({ name = "loader-2", size = 14, color = "tertiary" }),
      ui.label({ text = tr("panel.working"), fontSize = 12, color = "tertiary", maxLines = 1 }),
    }))
    return
  end
  local err = ""
  if type(lastaction) == "table" and lastaction.ok == false then err = tostring(lastaction.error or "") end
  if err == "" and type(detail) == "table" and detail.error then err = tostring(detail.error) end
  if err == "" and type(groupview) == "table" and groupview.error then err = tostring(groupview.error) end
  if err ~= "" then
    table.insert(rows, ui.row({ gap = 8, paddingH = 10, paddingV = 8,
                                fill = "error/0.14", border = "error/0.42",
                                borderWidth = 1, radius = 10, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 15, color = "error" }),
      ui.label({ text = err, fontSize = 12, color = "error", flexGrow = 1, maxLines = 2 }),
    }))
  end
end

function render()
  local rows = {}
  header(rows)
  ip_row(rows)
  local mode = mode_row()
  local group = group_row()
  table.insert(rows, panel_card(group and { mode, group } or { mode }))
  node_list(rows)
  actions(rows)
  status_line(rows)
  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 14, align = "stretch" }, rows))
end

local function refresh()
  send("status", nil, "status")
  send("group", { view_group }, "group")
  send("ip", nil, "ip")
end

function onOpen(context)
  refresh()
  render()
end

function onClose()
  pending = ""
end

noctalia.state.watch("detail", function(v) detail = v; pending = ""; render() end)
noctalia.state.watch("mihomo", function(v) mihomo = v; render() end)
noctalia.state.watch("group", function(v) groupview = v; pending = ""; render() end)
noctalia.state.watch("ip", function(v) ipinfo = v; pending = ""; render() end)
noctalia.state.watch("delay", function(v) delayinfo = v; pending = ""; render() end)
noctalia.state.watch("action", function(v) lastaction = v; render() end)

function update()
  noctalia.setUpdateInterval(5000)
end
