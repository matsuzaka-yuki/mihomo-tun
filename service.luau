--!nonstrict
-- service.luau —— 本插件唯一的子进程拥有者。
--
-- 为什么要有它：widget / shortcut / panel 都是独立 VM，若各自 spawn 进程就没人
-- 管并发与刷新时序。这里统一：轮询写 state("mihomo")，动作结果写 state("detail")
-- / state("action") / state("ip") / state("delay")。
-- 其他入口通过 state("cmd") 投递请求（带 nonce，值每次不同才会触发 watch）。

local PLUGIN_DIR = noctalia.pluginDir()
noctalia.log("mihomo-tun: service 已加载，脚本 = " .. PLUGIN_DIR .. "/scripts/mihomo-ctl.py")
local SCRIPT = PLUGIN_DIR .. "/scripts/mihomo-ctl.py"
local PLUGIN_DATA_DIR = noctalia.pluginDataDir() or ""

local function q(v)
  return "'" .. tostring(v == nil and "" or v):gsub("'", "'\\''") .. "'"
end

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil or v == "" then return fallback end
  return v
end

local function base_cmd()
  return "MIHOMO_SECRET_FILE=" .. q(cfg("secret_file", "/etc/mihomo/.controller-secret"))
    .. " MIHOMO_CONTROLLER=" .. q(cfg("controller", "http://127.0.0.1:9090"))
    .. " MIHOMO_UNIT=" .. q(cfg("unit", "mihomo.service"))
    .. " MIHOMO_CONFIG_FILE=" .. q(cfg("config_file", "/etc/mihomo/config.yaml"))
    .. " MIHOMO_DIRECT_RULES_FILE=" .. q(cfg("direct_rules_file", "/etc/mihomo/noctalia/direct-rules.yaml"))
    .. " MIHOMO_PLUGIN_DATA_DIR=" .. q(PLUGIN_DATA_DIR)
    .. " MIHOMO_MAX_NODES=" .. tostring(tonumber(cfg("max_nodes", 40)) or 40)
    .. " " .. q(cfg("python_bin", "python3")) .. " " .. q(SCRIPT)
end

-- 状态变化时才写日志（不是每次轮询都写），排查时 grep mihomo-tun 即可
local last_sig = ""
local function log_state(data)
  local sig = tostring(data.ok) .. "|" .. tostring(data.service) .. "|" .. tostring(data.now or "")
  if sig ~= last_sig then
    last_sig = sig
    noctalia.log(`mihomo-tun: ok={tostring(data.ok)} service={tostring(data.service)} now={tostring(data.now or "")}`)
  end
end

local inflight = 0
local MAX_INFLIGHT = 6   -- 允许一次刷新并行拉取状态、订阅和直连规则

local function run(args, key, on_done)
  if inflight >= MAX_INFLIGHT then
    noctalia.state.set("action", { ok = false, error = "上一个操作还没结束" })
    return
  end
  inflight += 1
  noctalia.runAsync(base_cmd() .. " " .. args, function(res)
    inflight -= 1
    local data = noctalia.json.decode(res.stdout or "")
    if type(data) ~= "table" then
      local err = tostring(res.stderr or ""):gsub("%s+$", "")
      data = { ok = false, error = err ~= "" and err:sub(1, 300) or "后端没有输出（检查 python_bin 设置）" }
    end
    if key == "mihomo" then log_state(data) end
    if key ~= "" then noctalia.state.set(key, data) end
    if on_done then on_done(data) end
  end, 25000)
end

local function notify_result(data)
  if type(data) ~= "table" then return end
  local msg = data.message or data.error or ""
  if msg == "" then return end
  if data.ok then
    noctalia.notify(noctalia.tr("panel.title"), msg)
  else
    noctalia.notifyError(noctalia.tr("panel.title"), msg)
  end
end

local function after_action(data)
  notify_result(data)
  run("watch", "mihomo")     -- 立刻刷新状态，不等下一个轮询周期
end

local function after_direct_action(data)
  notify_result(data)
  if type(data) == "table" and data.ok and type(data.entries) == "table" then
    noctalia.state.set("direct", data)
  else
    run("direct-list", "direct")
  end
end

-- 动作分发：state("cmd") 与 `noctalia msg plugin ...` 的 onIpc 共用这一份
local function dispatch(method, args)
  args = args or {}
  -- 动作日志：排查"点了没反应"时 grep mihomo-tun 即可看到到底有没有进来
  noctalia.log(`mihomo-tun: dispatch {tostring(method)}`)
  if method == "toggle" then
    run("toggle", "action", after_action)
  elseif method == "status" then
    run("status", "detail")
  elseif method == "group" then
    run("group " .. q(args[1] or "PROXY"), "group")
  elseif method == "watch" then
    run("watch", "mihomo")
  elseif method == "ip" then
    run("ip", "ip", notify_result)
  elseif method == "delay" then
    run("delay " .. q(args[1] or "PROXY"), "delay", function(d)
      notify_result(d)
      run("status", "detail")
    end)
  elseif method == "mode" then
    run("mode " .. q(args[1] or "rule"), "action", function(d)
      after_action(d)
      run("status", "detail")
    end)
  elseif method == "select" then
    local selected_group = args[1] or "PROXY"
    run("select " .. q(selected_group) .. " " .. q(args[2] or ""), "action", function(d)
      notify_result(d)
      if type(d) == "table" and type(d.snapshot) == "table" then
        noctalia.state.set("group", d.snapshot)
      else
        run("group " .. q(selected_group), "group")
      end
      run("watch", "mihomo")
      run("status", "detail")
    end)
  elseif method == "update-provider" then
    run("provider-update " .. q(args[1] or "airport"), "action", function(d)
      notify_result(d)
      run("providers", "providers")
    end)
  elseif method == "providers" then
    run("providers", "providers")
  elseif method == "provider-update" then
    run("provider-update " .. q(args[1] or "all"), "action", function(d)
      notify_result(d)
      run("providers", "providers")
    end)
  elseif method == "subscription-upsert" then
    run("subscription-upsert " .. q(args[1] or "") .. " " .. q(args[2] or "") .. " " .. q(args[3] or ""),
      "action", function(d)
        notify_result(d)
        run("providers", "providers")
      end)
  elseif method == "subscription-delete" then
    run("subscription-delete " .. q(args[1] or ""), "action", function(d)
      notify_result(d)
      run("providers", "providers")
    end)
  elseif method == "direct-list" then
    run("direct-list", "direct")
  elseif method == "direct-add" then
    run("direct-add " .. q(args[1] or ""), "action", function(d)
      after_direct_action(d)
    end)
  elseif method == "direct-remove" then
    run("direct-remove " .. q(args[1] or ""), "action", function(d)
      after_direct_action(d)
    end)
  elseif method == "direct-clear" then
    run("direct-clear", "action", function(d)
      after_direct_action(d)
    end)
  elseif method == "direct-sync" then
    run("direct-sync", "action", function(d)
      after_direct_action(d)
    end)
  elseif method == "secret" then
    -- 面板的"复制密钥"按钮：结果里带密钥，所以复制后立刻清掉 state，别留在内存里
    run("secret", "", function(d)   -- key 传空：密钥不进共享 state
      if type(d) == "table" and d.ok and d.secret then
        local copied = noctalia.copyToClipboard(d.secret, "text/plain;charset=utf-8")
        noctalia.state.set("secret", nil)
        if copied then
          noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.copied"))
        else
          noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.secret_failed"))
        end
      else
        notify_result(d)
      end
    end)
  elseif method == "open-ui" then
    noctalia.runAsync("xdg-open " .. q(cfg("controller", "http://127.0.0.1:9090") .. "/ui/"))
  elseif method == "refresh" then
    run("watch", "mihomo")
    run("status", "detail")
    run("providers", "providers")
    run("direct-list", "direct")
  else
    noctalia.state.set("action", { ok = false, error = "未知动作：" .. tostring(method) })
  end
end

function update()
  noctalia.setUpdateInterval(tonumber(cfg("refresh_ms", 5000)) or 5000)
  run("watch", "mihomo")
end

noctalia.state.watch("cmd", function(req)
  if type(req) ~= "table" then return end
  -- 防重放：state 里的旧命令可能在新 VM 订阅时被再次投递，
  -- 若不校验时间戳，就会出现"插件重载后自己又把代理关掉"这类怪事。
  local at = tonumber(req.at) or 0
  if at > 0 and os.time() - at > 15 then
    noctalia.log("mihomo-tun: 忽略过期命令 " .. tostring(req.method))
    return
  end
  dispatch(tostring(req.method or ""), req.args)
end)

function onIpc(event, payload)
  if event == "status" then
    dispatch("status")
    return
  end
  dispatch(tostring(event or ""), nil)
end
