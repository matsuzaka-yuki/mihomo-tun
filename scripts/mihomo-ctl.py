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
import hashlib
import ipaddress
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CTL = os.environ.get("MIHOMO_CONTROLLER", "http://127.0.0.1:9090").rstrip("/")
SECRET_FILE = os.environ.get("MIHOMO_SECRET_FILE", "/etc/mihomo/.controller-secret")
UNIT = os.environ.get("MIHOMO_UNIT", "mihomo.service")
TIMEOUT = float(os.environ.get("MIHOMO_API_TIMEOUT", "6"))
MAX_NODES = int(os.environ.get("MIHOMO_MAX_NODES", "60"))
DELAY_TEST_URL = os.environ.get("MIHOMO_DELAY_URL", "https://www.gstatic.com/generate_204")
CONFIG_FILE = os.environ.get("MIHOMO_CONFIG_FILE", "/etc/mihomo/config.yaml")


def default_plugin_data_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "noctalia", "plugins", "data", "LyraVoid", "mihomo-tun")


PLUGIN_DATA_DIR = os.environ.get("MIHOMO_PLUGIN_DATA_DIR") or default_plugin_data_dir()
DIRECT_STORE = os.path.join(PLUGIN_DATA_DIR, "direct-rules.json")
SUBSCRIPTION_OP_FILE = os.path.join(PLUGIN_DATA_DIR, "subscription-op.json")
DIRECT_PROVIDER_FILE = os.environ.get(
    "MIHOMO_DIRECT_RULES_FILE", "/etc/mihomo/noctalia/direct-rules.yaml"
)
DIRECT_PROVIDER_NAME = "noctalia-direct"
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


def write_json_atomic(path, payload):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def write_text_atomic(path, text, mode=0o600):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def direct_load():
    try:
        with open(DIRECT_STORE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return []
    except (OSError, json.JSONDecodeError):
        return []
    entries = data.get("entries") if isinstance(data, dict) else None
    return entries if isinstance(entries, list) else []


def direct_rule(entry):
    kind = str(entry.get("kind") or "")
    value = str(entry.get("value") or "")
    if kind == "domain":
        if entry.get("match") == "exact":
            return "DOMAIN," + value
        return "DOMAIN-SUFFIX," + value
    if kind == "ipv4":
        return "IP-CIDR,%s,no-resolve" % value
    if kind == "ipv6":
        return "IP-CIDR6,%s,no-resolve" % value
    return ""


def direct_provider_text(entries):
    lines = [
        "# Generated by Mihomo TUN Control. Do not edit by hand.",
        "# The matching RULE-SET points to DIRECT.",
        "payload:",
    ]
    for entry in entries:
        rule = direct_rule(entry)
        if rule:
            lines.append("  - " + json.dumps(rule, ensure_ascii=False))
    return "\n".join(lines) + "\n"


def provider_exists():
    try:
        providers = api("/providers/rules").get("providers") or {}
        return DIRECT_PROVIDER_NAME in providers
    except Exception:
        return False


def sync_direct_provider(entries):
    if not provider_exists():
        return False
    write_text_atomic(DIRECT_PROVIDER_FILE, direct_provider_text(entries))
    api("/providers/rules/" + urllib.parse.quote(DIRECT_PROVIDER_NAME, safe=""), method="PUT")
    return True


def normalize_direct_value(raw):
    value = str(raw or "").strip()
    if not value:
        raise ValueError("请输入域名或 IP")
    if any(ch in value for ch in "\r\n,\t "):
        raise ValueError("域名或 IP 不能包含空格、逗号或换行")
    if "://" in value:
        parsed = urllib.parse.urlsplit(value)
        if not parsed.hostname or parsed.path not in ("", "/"):
            raise ValueError("请输入域名或 IP，不要带路径")
        value = parsed.hostname

    exact = value.startswith("=")
    if exact:
        value = value[1:].strip()
    if value.startswith("*."):
        value = value[2:]
        exact = False

    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError:
        network = None
    if network is not None:
        kind = "ipv4" if network.version == 4 else "ipv6"
        normalized = str(network)
        identity = "%s|%s" % (kind, normalized)
        return {
            "id": hashlib.sha1(identity.encode("utf-8")).hexdigest()[:12],
            "kind": kind,
            "value": normalized,
            "display": normalized,
            "created_at": int(time.time()),
        }

    domain = value.rstrip(".").lower()
    try:
        domain = domain.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise ValueError("域名格式无效：%s" % exc) from exc
    domain_re = re.compile(
        r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
        r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
    )
    if not domain_re.fullmatch(domain):
        raise ValueError("域名格式无效")
    match = "exact" if exact else "suffix"
    identity = "domain|%s|%s" % (match, domain)
    return {
        "id": hashlib.sha1(identity.encode("utf-8")).hexdigest()[:12],
        "kind": "domain",
        "match": match,
        "value": domain,
        "display": ("=" if exact else "") + domain,
        "created_at": int(time.time()),
    }


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


def provider_snapshot():
    proxies = api("/proxies").get("proxies") or {}
    groups = {
        name for name, meta in proxies.items()
        if meta.get("type") in GROUP_TYPES and name != "GLOBAL"
    }
    raw = api("/providers/proxies").get("providers") or {}
    providers = []
    for name, meta in raw.items():
        if name in groups or name in BUILTIN:
            continue
        info = meta.get("subscriptionInfo") or meta.get("subscription-info") or {}
        updated = str(meta.get("updatedAt") or meta.get("updated-at") or "")
        if not info and (not updated or updated.startswith("0001-01-01")):
            continue
        providers.append({
            "name": name,
            "node_count": len(meta.get("proxies") or []),
            "updated_at": updated,
            "subscription": {
                "upload": int(info.get("Upload") or info.get("upload") or 0),
                "download": int(info.get("Download") or info.get("download") or 0),
                "total": int(info.get("Total") or info.get("total") or 0),
                "expire": int(info.get("Expire") or info.get("expire") or 0),
            },
        })
    providers.sort(key=lambda item: item["name"])
    return providers


def cmd_providers():
    try:
        providers = provider_snapshot()
    except Exception as exc:
        fail("读取订阅列表失败：%s" % exc)
    out({"ok": True, "providers": providers})


def update_provider(name):
    api("/providers/proxies/%s" % urllib.parse.quote(name, safe=""), method="PUT")


def cmd_provider_update(argv):
    if not argv:
        fail("provider-update 需要 <名称|all>")
    name = argv[0]
    if name == "all":
        try:
            providers = provider_snapshot()
            for provider in providers:
                update_provider(provider["name"])
        except Exception as exc:
            fail("更新全部订阅失败：%s" % exc)
        out({"ok": True, "updated": [item["name"] for item in providers],
             "message": "已触发更新 %d 个订阅" % len(providers)})
    try:
        update_provider(name)
    except Exception as exc:
        fail("更新订阅 %s 失败：%s" % (name, exc))
    out({"ok": True, "provider": name, "message": "订阅已触发更新"})


def apply_subscription_change(op):
    pkexec = os.environ.get("MIHOMO_PKEXEC") or shutil.which("pkexec")
    if not pkexec:
        fail("找不到 pkexec，无法执行需要管理员授权的配置更新")
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apply-subscription-change.py")
    write_json_atomic(SUBSCRIPTION_OP_FILE, op)
    command = [
        pkexec,
        sys.executable,
        helper,
        "--config", CONFIG_FILE,
        "--op-file", SUBSCRIPTION_OP_FILE,
        "--mihomo-bin", os.environ.get("MIHOMO_BIN", "/usr/bin/mihomo"),
        "--service", UNIT,
    ]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    except subprocess.TimeoutExpired:
        fail("管理员配置操作超时")
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        fail(detail[-1000:] or "管理员配置操作被取消或失败")
    try:
        return json.loads(completed.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        fail("配置助手没有返回有效结果")


def cmd_subscription_upsert(argv):
    if len(argv) < 2:
        fail("subscription-upsert 需要 <名称> <订阅地址> [原名称]")
    name, url = argv[0], argv[1]
    original_name = argv[2] if len(argv) > 2 else ""
    result = apply_subscription_change({
        "op": "upsert",
        "name": name,
        "url": url,
        "original_name": original_name,
    })
    out({
        "ok": True,
        "name": result.get("name", name),
        "message": "订阅已保存，Mihomo 已重新加载",
    })


def cmd_subscription_delete(argv):
    if not argv:
        fail("subscription-delete 需要 <名称>")
    name = argv[0]
    result = apply_subscription_change({"op": "delete", "name": name})
    out({
        "ok": True,
        "name": result.get("name", name),
        "message": "订阅已删除，Mihomo 已重新加载",
    })


def direct_setup_command():
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "configure-direct-rules.py")
    return "sudo python3 %s --config %s --rules-path %s --mihomo-bin /usr/bin/mihomo --service %s" % (
        shlex.quote(helper),
        shlex.quote(CONFIG_FILE),
        shlex.quote(DIRECT_PROVIDER_FILE),
        shlex.quote(UNIT),
    )


def direct_snapshot():
    entries = direct_load()
    return {
        "entries": entries,
        "configured": provider_exists(),
        "path": DIRECT_PROVIDER_FILE,
        "setup_command": direct_setup_command(),
    }


def cmd_direct_list():
    out({"ok": True, **direct_snapshot()})


def cmd_direct_add(argv):
    if not argv:
        fail("direct-add 需要 <域名或 IP>")
    try:
        entry = normalize_direct_value(argv[0])
    except ValueError as exc:
        fail(str(exc))
    entries = direct_load()
    if any(item.get("id") == entry["id"] for item in entries):
        fail("这个直连规则已经存在")
    entries.append(entry)
    entries.sort(key=lambda item: (item.get("kind") or "", item.get("value") or ""))
    write_json_atomic(DIRECT_STORE, {"version": 1, "entries": entries})
    try:
        configured = sync_direct_provider(entries)
    except Exception as exc:
        fail("规则已保存，但刷新 rule-provider 失败：%s" % exc,
             configured=provider_exists())
    out({
        "ok": True,
        "configured": configured,
        "entry": entry,
        "message": "已添加直连规则" if configured else "规则已保存，等待首次配置 Mihomo 规则提供器",
    })


def cmd_direct_remove(argv):
    if not argv:
        fail("direct-remove 需要 <规则 ID>")
    wanted = argv[0]
    entries = direct_load()
    kept = [item for item in entries if str(item.get("id") or "") != wanted]
    if len(kept) == len(entries):
        fail("找不到这条直连规则")
    write_json_atomic(DIRECT_STORE, {"version": 1, "entries": kept})
    try:
        configured = sync_direct_provider(kept)
    except Exception as exc:
        fail("规则已删除，但刷新 rule-provider 失败：%s" % exc,
             configured=provider_exists())
    out({"ok": True, "configured": configured, "message": "已删除直连规则"})


def cmd_direct_clear():
    write_json_atomic(DIRECT_STORE, {"version": 1, "entries": []})
    try:
        configured = sync_direct_provider([])
    except Exception as exc:
        fail("列表已清空，但刷新 rule-provider 失败：%s" % exc,
             configured=provider_exists())
    out({"ok": True, "configured": configured, "message": "已清空直连规则"})


def cmd_direct_sync():
    entries = direct_load()
    try:
        configured = sync_direct_provider(entries)
    except Exception as exc:
        fail("刷新直连规则失败：%s" % exc, configured=provider_exists())
    out({"ok": True, "configured": configured, "entries": entries,
         "message": "直连规则已刷新" if configured else "尚未配置 Mihomo rule-provider"})


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
                                  "|providers|provider-update <name|all>|update-provider [name]"
                                  "|subscription-upsert <name> <url> [old]|subscription-delete <name>"
                                  "|direct-list|direct-add <domain|ip>|direct-remove <id>|direct-clear|direct-sync"
                                  "|ip|secret"})
    cmd, rest = argv[0], argv[1:]
    handlers = {
        "watch": lambda: cmd_watch(),
        "status": lambda: cmd_status(),
        "toggle": lambda: cmd_toggle(),
        "mode": lambda: cmd_mode(rest),
        "select": lambda: cmd_select(rest),
        "group": lambda: cmd_group(rest),
        "delay": lambda: cmd_delay(rest),
        "providers": lambda: cmd_providers(),
        "provider-update": lambda: cmd_provider_update(rest),
        "update-provider": lambda: cmd_update_provider(rest),
        "subscription-upsert": lambda: cmd_subscription_upsert(rest),
        "subscription-delete": lambda: cmd_subscription_delete(rest),
        "direct-list": lambda: cmd_direct_list(),
        "direct-add": lambda: cmd_direct_add(rest),
        "direct-remove": lambda: cmd_direct_remove(rest),
        "direct-clear": lambda: cmd_direct_clear(),
        "direct-sync": lambda: cmd_direct_sync(),
        "ip": lambda: cmd_ip(),
        "secret": lambda: cmd_secret(),
    }
    if cmd not in handlers:
        fail("未知子命令：%s" % cmd)
    handlers[cmd]()


if __name__ == "__main__":
    main()
