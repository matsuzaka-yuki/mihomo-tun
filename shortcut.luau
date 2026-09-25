--!nonstrict
-- shortcut.luau —— 控制中心快捷开关（在 设置 → 控制中心 里添加）。
-- setIcon(on, off) 一次给两个图标，具体显示哪个由 setActive 决定。

local st = noctalia.state.get("mihomo") or { ok = false, now = "" }
local pending = false
local pending_at = 0
local nonce = 0

local function render()
  local on = st.ok == true
  shortcut.setIcon("shield-lock", "plug-off")
  shortcut.setActive(on)
  shortcut.setEnabled(true)
  if pending then
    shortcut.setLabel(noctalia.tr("widget.working"))
  elseif on then
    local node = tostring(st.now or "")
    shortcut.setLabel(node ~= "" and node or noctalia.tr("shortcut.on"))
  else
    shortcut.setLabel(noctalia.tr("shortcut.off"))
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
  if pending and os.time() - pending_at > 8 then
    pending = false
    st = { ok = false, now = "" }
  end
  render()
end

function onClick()
  send("toggle")
end
