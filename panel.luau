--!nonstrict
-- panel.luau —— 管理面板：开关、出口 IP、模式、策略组、节点、维护按钮。
-- 所有副作用都通过 state("cmd") 交给 service.luau 执行；本入口只读 state 与渲染。

local detail = noctalia.state.get("detail")
local mihomo = noctalia.state.get("mihomo") or { ok = false, service = "unknown", now = "" }
local groupview = noctalia.state.get("group")
local ipinfo = noctalia.state.get("ip")
local delayinfo = noctalia.state.get("delay")
local lastaction = noctalia.state.get("action")
local providerinfo = noctalia.state.get("providers")
local directinfo = noctalia.state.get("direct")

local view_group = "PROXY"
local view = "main"
local pending = ""
local nonce = 0
local direct_input = ""
local direct_input_rev = 0
local subscription_editor_open = false
local subscription_edit_original = ""
local subscription_name_input = ""
local subscription_url_input = ""
local subscription_input_rev = 0
local subscription_delete_confirm = ""
local spinner_frames = { "◐", "◓", "◑", "◒" }
local spinner_index = 1
local spinner_elapsed = 0
local frame_tick_enabled = false

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

local function format_bytes(value)
  local n = tonumber(value) or 0
  local units = { "B", "KB", "MB", "GB", "TB" }
  local index = 1
  while n >= 1024 and index < #units do
    n /= 1024
    index += 1
  end
  if index == 1 then return string.format("%d %s", n, units[index]) end
  return string.format("%.1f %s", n, units[index])
end

local function format_updated(value)
  local text = tostring(value or "")
  local date, clock = text:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
  if date and clock and not text:match("^0001%-") then
    return tr("panel.updated_at", { time = date .. " " .. clock })
  end
  return tr("panel.never_updated")
end

local function set_spinner_active(active)
  if active == frame_tick_enabled then return end
  frame_tick_enabled = active
  panel.setNeedsFrameTick(active)
end

local function page_button(label, page, glyph)
  return ui.button({
    key = "mihomo-page-" .. page,
    text = label,
    glyph = glyph,
    variant = view == page and "primary" or "ghost",
    controlSize = "sm",
    fontSize = 12,
    flexGrow = 1,
    selected = view == page,
    onClick = function()
      view = page
      if page == "subscriptions" then send("providers", nil, "providers") end
      if page == "direct" then send("direct-list", nil, "direct") end
      render()
    end,
  })
end

local function navigation()
  return ui.row({ gap = 6, align = "stretch" }, {
    page_button(tr("panel.nav_main"), "main", "layout-dashboard"),
    page_button(tr("panel.nav_subscriptions"), "subscriptions", "stack-2"),
    page_button(tr("panel.nav_direct"), "direct", "route"),
  })
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
        text = tr("panel.nav_subscriptions"),
        glyph = "stack-2",
        variant = common.variant,
        controlSize = common.controlSize,
        fontSize = common.fontSize,
        flexGrow = common.flexGrow,
        enabled = common.enabled,
        onClick = function()
          view = "subscriptions"
          send("providers", nil, "providers")
        end,
      }),
      ui.button({
        text = tr("panel.nav_direct"),
        glyph = "route",
        variant = common.variant,
        controlSize = common.controlSize,
        fontSize = common.fontSize,
        flexGrow = common.flexGrow,
        enabled = common.enabled,
        onClick = function()
          view = "direct"
          send("direct-list", nil, "direct")
        end,
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
      ui.label({
        text = spinner_frames[spinner_index],
        fontSize = 16,
        fontWeight = "bold",
        color = "tertiary",
        width = 18,
        textAlign = "center",
        maxLines = 1,
      }),
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

local function page_scroll(cards, key)
  return {
    ui.scroll({ key = key, flexGrow = 1, gap = 6, paddingH = 0 }, cards),
  }
end

local function subscriptions_view()
  local cards = {}
  local providers = type(providerinfo) == "table" and providerinfo.providers or nil
  local provider_error = type(providerinfo) == "table" and providerinfo.error or ""
  local add_subscription = ui.button({
    text = tr("panel.add_subscription"),
    glyph = "plus",
    variant = "primary",
    controlSize = "sm",
    fontSize = 12,
    enabled = pending == "",
    onClick = function()
      subscription_editor_open = true
      subscription_edit_original = ""
      subscription_name_input = ""
      subscription_url_input = ""
      subscription_input_rev += 1
      render()
    end,
  })
  local update_all = ui.button({
    text = tr("panel.update_all"),
    glyph = "refresh",
    variant = "secondary",
    controlSize = "sm",
    fontSize = 12,
    enabled = pending == "" and providers ~= nil and #providers > 0,
    onClick = function() send("provider-update", { "all" }, "provider") end,
  })
  table.insert(cards, panel_card({
    section_title(tr("panel.subscriptions"), ui.row({ gap = 6, align = "center" }, {
      add_subscription,
      update_all,
    })),
  }))

  if subscription_editor_open then
    table.insert(cards, panel_card({
      ui.label({
        text = subscription_edit_original ~= "" and tr("panel.edit_subscription")
          or tr("panel.add_subscription"),
        fontSize = 13,
        fontWeight = "semibold",
        color = "on_surface",
        maxLines = 1,
      }),
      ui.input({
        key = "subscription-name-" .. tostring(subscription_input_rev),
        value = subscription_name_input,
        placeholder = tr("panel.subscription_name"),
        fontSize = 12,
        controlSize = "sm",
        enabled = pending == "",
        onChange = function(value) subscription_name_input = tostring(value or "") end,
      }),
      ui.input({
        key = "subscription-url-" .. tostring(subscription_input_rev),
        value = subscription_url_input,
        placeholder = tr("panel.subscription_url"),
        fontSize = 12,
        controlSize = "sm",
        enabled = pending == "",
        onChange = function(value) subscription_url_input = tostring(value or "") end,
        onSubmit = function(value)
          subscription_url_input = tostring(value or "")
          if subscription_name_input ~= "" and subscription_url_input ~= "" then
            local name = subscription_name_input
            local url = subscription_url_input
            local original = subscription_edit_original
            subscription_editor_open = false
            subscription_edit_original = ""
            subscription_name_input = ""
            subscription_url_input = ""
            subscription_input_rev += 1
            send("subscription-upsert", { name, url, original }, "subscription")
          end
        end,
      }),
      ui.row({ gap = 6, align = "stretch" }, {
        ui.button({
          text = tr("panel.save"),
          glyph = "check",
          variant = "primary",
          controlSize = "sm",
          fontSize = 12,
          flexGrow = 1,
          enabled = pending == "" and subscription_name_input ~= "" and subscription_url_input ~= "",
          onClick = function()
            local name = subscription_name_input
            local url = subscription_url_input
            local original = subscription_edit_original
            subscription_editor_open = false
            subscription_edit_original = ""
            subscription_name_input = ""
            subscription_url_input = ""
            subscription_input_rev += 1
            send("subscription-upsert", { name, url, original }, "subscription")
          end,
        }),
        ui.button({
          text = tr("panel.cancel"),
          variant = "ghost",
          controlSize = "sm",
          fontSize = 12,
          flexGrow = 1,
          onClick = function()
            subscription_editor_open = false
            subscription_edit_original = ""
            subscription_name_input = ""
            subscription_url_input = ""
            subscription_input_rev += 1
            render()
          end,
        }),
      }),
    }))
  end

  if providers == nil then
    table.insert(cards, panel_card({
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "loader-2", size = 16, color = "tertiary" }),
        ui.label({ text = tr("panel.loading"), fontSize = 13, color = "on_surface_variant" }),
      }),
    }, { flexGrow = 1 }))
    return page_scroll(cards, "mihomo-provider-scroll")
  end
  if provider_error ~= "" then
    table.insert(cards, panel_card({
      ui.label({ text = tostring(provider_error), fontSize = 12, color = "error", maxLines = 3 }),
    }))
    return page_scroll(cards, "mihomo-provider-scroll")
  end
  if #providers == 0 then
    table.insert(cards, panel_card({
      ui.label({ text = tr("panel.no_providers"), fontSize = 13, color = "on_surface_variant" }),
    }, { flexGrow = 1 }))
    return page_scroll(cards, "mihomo-provider-scroll")
  end

  for _, provider in ipairs(providers) do
    local provider_name = tostring(provider.name or "")
    local subscription = type(provider.subscription) == "table" and provider.subscription or {}
    local used = (tonumber(subscription.upload) or 0) + (tonumber(subscription.download) or 0)
    local total = tonumber(subscription.total) or 0
    local expire = tonumber(subscription.expire) or 0
    local actions = {}
    if subscription_delete_confirm == provider_name then
      table.insert(actions, ui.button({
        glyph = "check",
        tooltip = tr("panel.delete_confirm"),
        variant = "destructive",
        controlSize = "sm",
        enabled = pending == "",
        onClick = function()
          subscription_delete_confirm = ""
          send("subscription-delete", { provider_name }, "subscription")
        end,
      }))
      table.insert(actions, ui.button({
        glyph = "close",
        tooltip = tr("panel.cancel"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          subscription_delete_confirm = ""
          render()
        end,
      }))
    else
      table.insert(actions, ui.button({
        glyph = "refresh",
        tooltip = tr("panel.refresh"),
        variant = "ghost",
        controlSize = "sm",
        enabled = pending == "",
        onClick = function()
          send("provider-update", { provider_name }, "provider")
        end,
      }))
      table.insert(actions, ui.button({
        glyph = "pencil",
        tooltip = tr("panel.edit_subscription"),
        variant = "ghost",
        controlSize = "sm",
        enabled = pending == "",
        onClick = function()
          subscription_editor_open = true
          subscription_edit_original = provider_name
          subscription_name_input = provider_name
          subscription_url_input = ""
          subscription_input_rev += 1
          render()
        end,
      }))
      table.insert(actions, ui.button({
        glyph = "trash",
        tooltip = tr("panel.delete"),
        variant = "ghost",
        controlSize = "sm",
        enabled = pending == "",
        onClick = function()
          subscription_delete_confirm = provider_name
          render()
        end,
      }))
    end
    local children = {
      ui.row({ gap = 8, align = "center" }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({
            text = provider_name,
            fontSize = 14,
            fontWeight = "semibold",
            color = "on_surface",
            maxLines = 1,
          }),
          ui.label({
            text = tr("panel.node_count", { count = tonumber(provider.node_count) or 0 }),
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 1,
          }),
        }),
        ui.row({ gap = 4, align = "center" }, actions),
      }),
      ui.label({
        text = format_updated(provider.updated_at),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }
    if total > 0 then
      table.insert(children, ui.progress({
        progress = math.min(1, used / total),
        height = 5,
        radius = 3,
        fill = used / total >= 0.85 and "error" or "primary",
        track = "outline/0.22",
      }))
      table.insert(children, ui.label({
        text = tr("panel.quota_used", { used = format_bytes(used), total = format_bytes(total) }),
        fontSize = 11,
        color = "on_surface",
        maxLines = 1,
      }))
    else
      table.insert(children, ui.label({
        text = tr("panel.quota_unknown"),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
      }))
    end
    if expire > 0 then
      table.insert(children, ui.label({
        text = tr("panel.expires", { date = os.date("%Y-%m-%d", expire) }),
        fontSize = 11,
        color = expire <= os.time() and "error" or "on_surface_variant",
        maxLines = 1,
      }))
    end
    table.insert(cards, panel_card(children))
  end
  return page_scroll(cards, "mihomo-provider-scroll")
end

local function direct_view()
  local cards = {}
  local info = type(directinfo) == "table" and directinfo or {}
  local entries = type(info.entries) == "table" and info.entries or nil
  local configured = info.configured == true

  local clear = ui.button({
    text = tr("panel.clear_all"),
    glyph = "trash",
    variant = "ghost",
    controlSize = "sm",
    fontSize = 11,
    enabled = pending == "" and entries ~= nil and #entries > 0,
    onClick = function() send("direct-clear", nil, "direct") end,
  })
  table.insert(cards, panel_card({
    section_title(tr("panel.direct_rules"), clear),
    ui.label({
      text = tr("panel.direct_help"),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 3,
    }),
    ui.row({ gap = 6, align = "stretch" }, {
      ui.input({
        key = "mihomo-direct-input-" .. tostring(direct_input_rev),
        value = direct_input,
        placeholder = tr("panel.direct_placeholder"),
        fontSize = 12,
        controlSize = "sm",
        flexGrow = 1,
        enabled = pending == "",
        onChange = function(value) direct_input = tostring(value or "") end,
        onSubmit = function(value)
          direct_input = tostring(value or "")
          if direct_input ~= "" then
            local wanted = direct_input
            direct_input = ""
            direct_input_rev += 1
            send("direct-add", { wanted }, "direct")
          end
        end,
      }),
      ui.button({
        text = tr("panel.add_direct"),
        glyph = "plus",
        variant = "primary",
        controlSize = "sm",
        fontSize = 12,
        enabled = pending == "" and direct_input ~= "",
        onClick = function()
          if direct_input ~= "" then
            local wanted = direct_input
            direct_input = ""
            direct_input_rev += 1
            send("direct-add", { wanted }, "direct")
          end
        end,
      }),
    }),
  }))

  if not configured then
    table.insert(cards, ui.row({
      gap = 8,
      paddingH = 10,
      paddingV = 9,
      fill = "tertiary/0.12",
      border = "tertiary/0.38",
      borderWidth = 1,
      radius = 10,
      align = "center",
    }, {
      ui.glyph({ name = "info-circle", size = 16, color = "tertiary" }),
      ui.label({
        text = tr("panel.direct_not_configured"),
        fontSize = 12,
        color = "tertiary",
        flexGrow = 1,
        maxLines = 2,
      }),
      ui.button({
        text = tr("panel.copy_setup"),
        glyph = "copy",
        variant = "secondary",
        controlSize = "sm",
        fontSize = 11,
        enabled = type(info.setup_command) == "string" and info.setup_command ~= "",
        onClick = function()
          local copied = noctalia.copyToClipboard(info.setup_command or "", "text/plain;charset=utf-8")
          if copied then
            noctalia.notify(tr("panel.title"), tr("panel.setup_copied"))
          else
            noctalia.notifyError(tr("panel.title"), tr("panel.secret_failed"))
          end
        end,
      }),
    }))
  else
    table.insert(cards, ui.row({ gap = 7, paddingH = 10, paddingV = 7,
                                fill = "primary/0.10", border = "primary/0.28",
                                borderWidth = 1, radius = 9, align = "center" }, {
      ui.glyph({ name = "circle-check", size = 15, color = "primary" }),
      ui.label({ text = tr("panel.direct_configured"), fontSize = 12, color = "primary", maxLines = 1 }),
    }))
  end

  if entries == nil then
    table.insert(cards, panel_card({
      ui.label({ text = tr("panel.loading"), fontSize = 13, color = "on_surface_variant" }),
    }, { flexGrow = 1 }))
    return page_scroll(cards, "mihomo-direct-scroll")
  end
  if #entries == 0 then
    table.insert(cards, panel_card({
      ui.label({ text = tr("panel.direct_empty"), fontSize = 13, color = "on_surface_variant" }),
    }, { flexGrow = 1 }))
    return page_scroll(cards, "mihomo-direct-scroll")
  end

  local items = {}
  for _, entry in ipairs(entries) do
    local kind = entry.kind == "domain" and "DOMAIN" or "IP"
    table.insert(items, ui.row({
      key = "mihomo-direct-" .. tostring(entry.id or entry.value or ""),
      gap = 8,
      align = "center",
      paddingH = 10,
      paddingV = 7,
      fill = "surface/0.66",
      border = "outline/0.48",
      borderWidth = 1,
      radius = 8,
    }, {
      ui.label({
        text = kind,
        fontSize = 10,
        fontWeight = "bold",
        color = kind == "DOMAIN" and "tertiary" or "secondary",
        maxLines = 1,
      }),
      ui.label({
        text = tostring(entry.display or entry.value or ""),
        fontSize = 13,
        color = "on_surface",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.button({
        glyph = "trash",
        tooltip = tr("panel.remove"),
        variant = "ghost",
        controlSize = "sm",
        enabled = pending == "",
        onClick = function()
          send("direct-remove", { tostring(entry.id or "") }, "direct")
        end,
      }),
    }))
  end
  for _, item in ipairs(items) do table.insert(cards, item) end
  return page_scroll(cards, "mihomo-direct-scroll")
end

function render()
  set_spinner_active(pending ~= "")
  local rows = { navigation() }
  if view == "subscriptions" then
    local subscription_rows = subscriptions_view()
    for _, row in ipairs(subscription_rows) do table.insert(rows, row) end
  elseif view == "direct" then
    local direct_rows = direct_view()
    for _, row in ipairs(direct_rows) do table.insert(rows, row) end
  else
    header(rows)
    ip_row(rows)
    local mode = mode_row()
    local group = group_row()
    table.insert(rows, panel_card(group and { mode, group } or { mode }))
    node_list(rows)
    actions(rows)
  end
  status_line(rows)
  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 14, align = "stretch" }, rows))
end

local function refresh()
  send("status", nil, "status")
  send("group", { view_group }, "group")
  send("ip", nil, "ip")
  send("providers", nil, "providers")
  send("direct-list", nil, "direct")
end

function onOpen(context)
  refresh()
  render()
end

function onClose()
  pending = ""
  set_spinner_active(false)
  view = "main"
  direct_input = ""
  subscription_editor_open = false
  subscription_edit_original = ""
  subscription_name_input = ""
  subscription_url_input = ""
  subscription_delete_confirm = ""
end

noctalia.state.watch("detail", function(v) detail = v; pending = ""; render() end)
noctalia.state.watch("mihomo", function(v) mihomo = v; render() end)
noctalia.state.watch("group", function(v) groupview = v; pending = ""; render() end)
noctalia.state.watch("ip", function(v) ipinfo = v; pending = ""; render() end)
noctalia.state.watch("delay", function(v) delayinfo = v; pending = ""; render() end)
noctalia.state.watch("action", function(v) lastaction = v; render() end)
noctalia.state.watch("providers", function(v) providerinfo = v; pending = ""; render() end)
noctalia.state.watch("direct", function(v) directinfo = v; pending = ""; render() end)

function onFrameTick(delta)
  if pending == "" then return end
  spinner_elapsed += tonumber(delta) or 0
  if spinner_elapsed < 120 then return end
  spinner_elapsed = 0
  spinner_index = spinner_index % #spinner_frames + 1
  render()
end

function update()
  noctalia.setUpdateInterval(5000)
end
