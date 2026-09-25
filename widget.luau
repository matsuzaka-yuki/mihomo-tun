--!nonstrict
-- widget.luau —— 状态栏小部件：左键开关代理，右键打开管理面板。
-- 右键绑定声明在 plugin.toml 的 [widget.actions]（绑定优先于 onRightClick）。
-- 状态来自 service.luau 写入的 state("mihomo")，本入口自己不 spawn 进程。

local st = noctalia.state.get("mihomo") or { ok = false, service = "unknown", now = "" }
local pending = false
local pending_at = 0
local nonce = 0

local function cfg_bool(key, default)
  local v = noctalia.getConfig(key)
  if v == nil then return default end
  return v == true or v == "true"
end

local function cfg_str(key, default)
  local v = noctalia.getConfig(key)
  if type(v) == "string" and v ~= "" then return v end
  return default
end


-- [2026-09-25 补丁] 短名：去掉 "AUTO → " 前缀与 " | IEPL | x2" 后缀，避免撑爆布局
local function short_node(n)
  local x = tostring(n or "")
  x = x:gsub("^%s+", ""):gsub("%s+$", "")
  x = x:gsub("^.-→%s*", "")   -- 前缀
  x = x:gsub("%s*|.*$", "")   -- 后缀
  if x == "" then x = tostring(n or "") end
  return x
end

local function render()
  local on = st.ok == true
  local node = tostring(st.now or "")
  local active_color = cfg_str("active_color", "primary")
  local inactive_color = cfg_str("inactive_color", "on_surface_variant")
  local vertical = barWidget.isVertical()
  local children = {
    ui.glyph({
      key = "mihomo-bar-glyph",
      name = on and "shield-lock" or "plug-off",
      size = 16,
      color = on and active_color or inactive_color,
    }),
  }

  if pending then
    table.insert(children, ui.label({
      key = "mihomo-bar-label",
      text = "…",
      color = "tertiary",
      maxWidth = vertical and 0 or 132,
      maxLines = 1,
    }))
  elseif cfg_bool("show_label", true) then
    local text
    local color
    if on then
      text = node ~= "" and short_node(node) or noctalia.tr("widget.unknown")
      color = "on_surface"
    else
      text = noctalia.tr("widget.off")
      color = inactive_color
    end
    table.insert(children, ui.label({
      key = "mihomo-bar-label",
      text = text,
      color = color,
      maxWidth = vertical and 0 or 132,
      maxLines = 1,
    }))
  end

  local container = vertical and ui.column or ui.row
  barWidget.render(container({ key = "mihomo-bar", gap = 6, align = "center" }, children))

  if pending then
    barWidget.setTooltip(noctalia.tr("widget.working"))
  elseif on then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_on", { node = node ~= "" and node or "?" }))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip_off"))
  end
end

local function send(method, args)
  nonce += 1
  pending = true
  pending_at = os.time()
  render()
  noctalia.state.set("cmd", {
    method = method,
    args = args or {},
    nonce = tostring(nonce) .. ":" .. tostring(os.time()),
    at = os.time(),
  })
end

noctalia.state.watch("mihomo", function(value)
  if type(value) == "table" then
    st = value
    pending = false
    render()
  end
end)

local asked_once = false

function update()
  noctalia.setUpdateInterval(2000)
  -- 首次 tick 主动要一次状态：否则登录后到服务第一次轮询之间会先闪一下"已关闭"
  if not asked_once then
    asked_once = true
    noctalia.state.set("cmd", { method = "watch", args = {}, nonce = "boot:" .. tostring(os.time()), at = os.time() })
  end
  -- 服务挂掉时的兜底：别让 "…" 永远转下去
  if pending and os.time() - pending_at > 8 then
    pending = false
    st = { ok = false, service = "unknown", now = "", error = "后端无响应" }
  end
  render()
end

function onClick()
  send("toggle")
end
