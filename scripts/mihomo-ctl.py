#!/usr/bin/env python3
"""mihomo 控制后端 —— Noctalia 插件与终端共用的唯一入口。

设计约束：
  * 每个子命令往 stdout 打**一行 JSON**（稳定契约，Luau 侧只做 json.decode）
  * 只读本地 127.0.0.1 控制器；不开新端口、不写文件
  * 除 `secret` 子命令外，任何输出都不含密钥
  * 所有失败都收敛成 {"ok":false,"error":"..."}，绝不抛栈

环境变量（测试与定制用）：
  MIHOMO_CONTROLLER     默认 http://127.0.0.1:9090
  MIHOMO_SECRET_FILE    默认 /etc/mihomo/.controller-secret
  MIHOMO_UNIT           默认 mihomo.service
  MIHOMO_MAX_NODES      默认 60（单次返回的最大节点数）
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

CTL = os.environ.get("MIHOMO_CONTROLLER", "http://127.0.0.1:9090").rstrip("/")
SECRET_FILE = os.environ.get("MIHOMO_SECRET_FILE", "/etc/mihomo/.controller-secret")
UNIT = os.environ.get("MIHOMO_UNIT", "mihomo.service")
TIMEOUT = float(os.environ.get("MIHOMO_API_TIMEOUT", "6"))
MAX_NODES = int(os.environ.get("MIHOMO_MAX_NODES", "60"))
DELAY_TEST_URL = os.environ.get("MIHOMO_DELAY_URL", "https://www.gstatic.com/generate_204")
# 出口 IP 回显端点，按顺序尝试（境外域名，确保会被规则送进代理）
IP_ECHOES = [
    "https://ipinfo.io/ip",
    "https://ifconfig.me/ip",
    "https://api.myip.com",
    "https://www.cloudflare.com/cdn-cgi/trace",
]

# 策略组类型（mihomo /proxies 里组对象的 type；GLOBAL 是内置的，排除）
GROUP_TYPES = {"Selector", "URLTest", "Fallback", "LoadBalance", "Relay"}
# mihomo 内置代理，不该出现在"可选节点"列表里
BUILTIN = {"DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL"}


def out(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def fail(msg, **extra):
    payload = {"ok": False, "error": str(msg)}
    payload.update(extra)
    out(payload, 1)


def read_secret():
    try:
        with open(SECRET_FILE, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def api(path, method="GET", body=None):
    """调 mihomo 控制器；鉴权只走 Authorization 头。

    依据 mihomo v1.19.31 hub/route/server.go:338-368：普通 HTTP 请求只认
    Authorization: Bearer <secret>，?token= 查询参数仅对 websocket upgrade 生效。
    """
    secret = read_secret()
    if not secret:
        raise RuntimeError("读不到密钥 %s（应为本用户可读，见 deploy.sh 的 0640 授权）" % SECRET_FILE)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(CTL + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + secret)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        raw = resp.read().decode("utf-8", "replace")
    return json.loads(raw) if raw.strip() else {}


def service_state():
    """systemctl is-active <unit>；返回 active/inactive/failed/unknown。"""
    try:
        proc = subprocess.run(["systemctl", "is-active", UNIT],
                              capture_output=True, text=True, timeout=5)
        return (proc.stdout or "").strip() or "unknown"
    except Exception:
        return "unknown"


def systemctl(verb):
    proc = subprocess.run(["systemctl", verb, UNIT],
                          capture_output=True, text=True, timeout=20)
    return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()


def resolve_selection(name):
    """PROXY 常见是"选中某个策略组"，此时下钻一层给出真实节点。

    返回 (显示用字符串, 是否嵌套)。查不到就原样返回，绝不抛错。
    """
    if not name:
        return name, False
    try:
        node = api("/proxies/" + urllib.parse.quote(name, safe=""))
    except Exception:
        return name, False
    if node.get("type") in GROUP_TYPES:
        inner = node.get("now") or ""
        if inner and inner != name:
            return "%s → %s" % (name, inner), True
    return name, False


def cmd_watch():
    """轻量轮询：只问服务状态和当前选中节点（面板关闭时用）。"""
    state = service_state()
    res = {"ok": state == "active", "service": state, "now": "", "nested": False, "error": ""}
    if state != "active":
        res["error"] = "mihomo 未运行"
        out(res)
    try:
        raw = api("/proxies/PROXY").get("now", "") or ""
        res["now"], res["nested"] = resolve_selection(raw)
    except urllib.error.HTTPError as exc:
        res["ok"], res["error"] = False, "控制器返回 HTTP %s" % exc.code
    except Exception as exc:
        res["ok"], res["error"] = False, str(exc)
    out(res)


def cmd_status():
    """完整快照：给面板用。节点数按 MIHOMO_MAX_NODES 截断，控制 Luau 解码压力。"""
    state = service_state()
    res = {"ok": state == "active", "service": state, "version": "", "mode": "",
           "groups": [], "group": "PROXY", "now": "", "nodes": [], "truncated": False,
           "error": ""}
    if state != "active":
        res["error"] = "mihomo 未运行"
        out(res)
    try:
        res["version"] = api("/version").get("version", "") or ""
        res["mode"] = api("/configs").get("mode", "") or ""
        # 注意：/proxies 返回的是 {"proxies": {...}} 包装，不是裸字典
        proxies = api("/proxies").get("proxies", {})
        groups = [name for name, meta in proxies.items()
                  if meta.get("type") in GROUP_TYPES and name != "GLOBAL"]
        res["groups"] = sorted(groups)
        group = "PROXY" if "PROXY" in groups else (res["groups"][0] if res["groups"] else "")
        res["group"] = group
        if group:
            node = api("/proxies/" + urllib.parse.quote(group, safe=""))
            raw = node.get("now", "") or ""
            if raw in groups:
                try:
                    inner = api("/proxies/" + urllib.parse.quote(raw, safe="")).get("now") or ""
                except Exception:
                    inner = ""
                res["now"] = "%s → %s" % (raw, inner) if inner else raw
            else:
                res["now"] = raw
            members = [n for n in (node.get("all") or [])
                       if n not in groups and n not in BUILTIN]
            res["truncated"] = len(members) > MAX_NODES
            res["nodes"] = [{"name": n, "delay": None} for n in members[:MAX_NODES]]
    except urllib.error.HTTPError as exc:
        res["ok"], res["error"] = False, "控制器返回 HTTP %s" % exc.code
    except Exception as exc:
        res["ok"], res["error"] = False, str(exc)
    out(res)


def cmd_toggle():
    state = service_state()
    verb = "stop" if state == "active" else "start"
    code, _, err = systemctl(verb)
    after = service_state()
    if code != 0:
        fail("systemctl %s %s 失败：%s" % (verb, UNIT, err or "未知错误"),
             service=after, verb=verb)
    out({"ok": True, "service": after, "verb": verb,
         "message": "代理已" + ("关闭（恢复直连）" if verb == "stop" else "开启")})


def cmd_mode(argv):
    if not argv or argv[0] not in ("rule", "global", "direct"):
        fail("mode 需要 rule|global|direct")
    try:
        api("/configs", method="PATCH", body={"mode": argv[0]})
    except Exception as exc:
        fail("切换模式失败：%s" % exc)
    out({"ok": True, "mode": argv[0], "message": "模式已切到 " + argv[0]})


def cmd_select(argv):
    if len(argv) < 2:
        fail("select 需要 <组名> <节点名>")
    group, node = argv[0], argv[1]
    try:
        api("/proxies/" + urllib.parse.quote(group, safe=""), method="PUT",
            body={"name": node})
    except Exception as exc:
        fail("切换节点失败：%s" % exc)
    out({"ok": True, "group": group, "now": node, "message": "已切到 " + node})


def cmd_group(argv):
    """返回某个策略组的成员与当前选中项（面板切换查看的组时用，响应很小）。"""
    if not argv:
        fail("group 需要 <组名>")
    name = argv[0]
    try:
        node = api("/proxies/" + urllib.parse.quote(name, safe=""))
    except urllib.error.HTTPError as exc:
        fail("组 %s 不存在或控制器返回 HTTP %s" % (name, exc.code))
    except Exception as exc:
        fail("读取组 %s 失败：%s" % (name, exc))
    members = [n for n in (node.get("all") or []) if n not in BUILTIN]
    out({"ok": True, "group": name, "now": node.get("now", "") or "",
         "nodes": members[:MAX_NODES], "truncated": len(members) > MAX_NODES})


def cmd_delay(argv):
    group = argv[0] if argv else "PROXY"
    query = "?url=%s&timeout=3000" % urllib.parse.quote(DELAY_TEST_URL, safe="")
    try:
        result = api("/group/%s/delay%s" % (urllib.parse.quote(group, safe=""), query))
    except Exception as exc:
        fail("延迟测试失败：%s" % exc)
    items = [{"name": k, "delay": v} for k, v in result.items()]
    items.sort(key=lambda it: (it["delay"] is None, it["delay"] or 0))
    out({"ok": True, "group": group, "results": items})


def cmd_update_provider(argv):
    name = argv[0] if argv else "airport"
    try:
        api("/providers/proxies/%s" % urllib.parse.quote(name, safe=""), method="PUT")
    except Exception as exc:
        fail("更新订阅失败：%s" % exc)
    out({"ok": True, "provider": name, "message": "订阅已触发更新（机场侧限流时会失败）"})


def cmd_ip():
    """取当前出口 IP。

    必须用**境外**端点：像 ip.3322.net 这类国内域名会被规则判成 DIRECT，
    用它测代理出口永远返回家宽 IP，会得出错误结论。
    实测本机 1.1.1.1:443 不可达，所以也不能用 Cloudflare trace。
    """
    errors = []
    for url in IP_ECHOES:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.5.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = resp.read().decode("utf-8", "replace")
            found = re.search(r"(\d{1,3}(?:\.\d{1,3}){3})", body)
            if found:
                out({"ok": True, "ip": found.group(1), "endpoint": url})
            errors.append("%s: 响应里没有 IP" % url)
        except Exception as exc:
            errors.append("%s: %s" % (url, exc))
    fail("拿不到出口 IP（" + "; ".join(errors) + "）")


def cmd_secret():
    secret = read_secret()
    if not secret:
        fail("读不到密钥 %s" % SECRET_FILE)
    out({"ok": True, "secret": secret, "controller": CTL})


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        out({"ok": True, "usage": "watch|status|group <g>|toggle|mode <m>|select <g> <n>|delay [g]"
                                  "|update-provider [name]|ip|secret"})
    cmd, rest = argv[0], argv[1:]
    handlers = {
        "watch": lambda: cmd_watch(),
        "status": lambda: cmd_status(),
        "toggle": lambda: cmd_toggle(),
        "mode": lambda: cmd_mode(rest),
        "select": lambda: cmd_select(rest),
        "group": lambda: cmd_group(rest),
        "delay": lambda: cmd_delay(rest),
        "update-provider": lambda: cmd_update_provider(rest),
        "ip": lambda: cmd_ip(),
        "secret": lambda: cmd_secret(),
    }
    if cmd not in handlers:
        fail("未知子命令：%s" % cmd)
    handlers[cmd]()


if __name__ == "__main__":
    main()
