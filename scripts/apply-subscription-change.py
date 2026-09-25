#!/usr/bin/env python3
"""Apply one managed Mihomo proxy-provider change with root privileges."""

import argparse
import json
import os
import re
import shutil
import subprocess
import time
import urllib.parse
from pathlib import Path


NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def section_end(lines, start):
    index = start + 1
    while index < len(lines):
        line = lines[index]
        if line and not line.startswith((" ", "#")):
            break
        index += 1
    return index


def find_section(lines, name):
    for index, line in enumerate(lines):
        if line == name + ":":
            return index, section_end(lines, index)
    return None


def provider_blocks(lines, start, end):
    blocks = []
    index = start + 1
    while index < end:
        match = re.match(r"^  ([^ #][^:]*):\s*$", lines[index])
        if not match:
            index += 1
            continue
        block_end = index + 1
        while block_end < end and not re.match(r"^  [^ #][^:]*:\s*$", lines[block_end]):
            block_end += 1
        blocks.append((match.group(1).strip().strip("'\""), index, block_end))
        index = block_end
    return blocks


def provider_yaml(name, url):
    path = "./providers/" + name + ".yaml"
    return [
        "  " + name + ":",
        "    type: http",
        "    url: " + json.dumps(url, ensure_ascii=False),
        "    path: " + json.dumps(path),
        "    interval: 86400",
        "    exclude-filter: " + json.dumps(
            "(?i)(剩余|到期|过期|流量|重置|订阅|官网|expire|traffic)",
            ensure_ascii=False,
        ),
        "    header:",
        "      User-Agent:",
        '        - "clash-verge/v2.0.3"',
        "    health-check:",
        "      enable: true",
        '      url: "https://www.gstatic.com/generate_204"',
        "      interval: 300",
        "      timeout: 3000",
        "      lazy: true",
    ]


def remove_provider(lines, name):
    section = find_section(lines, "proxy-providers")
    if section is None:
        raise RuntimeError("配置里没有顶层 proxy-providers")
    start, end = section
    for provider_name, block_start, block_end in provider_blocks(lines, start, end):
        if provider_name == name:
            return lines[:block_start] + lines[block_end:]
    return lines


def upsert_provider(lines, name, url):
    lines = remove_provider(lines, name)
    section = find_section(lines, "proxy-providers")
    if section is None:
        raise RuntimeError("配置里没有顶层 proxy-providers")
    _, end = section
    while end > 0 and not lines[end - 1].strip():
        end -= 1
    lines[end:end] = provider_yaml(name, url)
    return lines


def validate_op(op):
    name = str(op.get("name") or "").strip()
    operation = str(op.get("op") or "").strip()
    if operation not in ("upsert", "delete"):
        raise SystemExit("不支持的操作：%s" % operation)
    if not NAME_RE.fullmatch(name):
        raise SystemExit("订阅名称只能包含字母、数字、点、下划线和连字符")
    if operation == "upsert":
        url = str(op.get("url") or "").strip()
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise SystemExit("订阅地址必须是 http(s) URL")
        if any(ch in url for ch in "\r\n"):
            raise SystemExit("订阅地址不能包含换行")
        op["url"] = url
        original = str(op.get("original_name") or "").strip()
        if original and not NAME_RE.fullmatch(original):
            raise SystemExit("原订阅名称无效")
        op["original_name"] = original
    op["name"] = name
    return op


def validate_config(config_path, mihomo_bin):
    completed = subprocess.run(
        [mihomo_bin, "-t", "-d", str(config_path.parent)],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise RuntimeError(detail[-4000:] or "mihomo config validation failed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/etc/mihomo/config.yaml")
    parser.add_argument("--op-file", required=True)
    parser.add_argument("--mihomo-bin", default="/usr/bin/mihomo")
    parser.add_argument("--service")
    parser.add_argument("--no-restart", action="store_true")
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise SystemExit("该操作需要管理员授权")

    config_path = Path(args.config)
    op_path = Path(args.op_file)
    if not config_path.is_file() or not op_path.is_file():
        raise SystemExit("找不到配置文件或待应用操作")

    op = validate_op(json.loads(op_path.read_text(encoding="utf-8")))
    original = config_path.read_text(encoding="utf-8")
    lines = original.splitlines()

    if op["op"] == "delete":
        lines = remove_provider(lines, op["name"])
    else:
        original_name = op.get("original_name") or ""
        if original_name and original_name != op["name"]:
            lines = remove_provider(lines, original_name)
        lines = upsert_provider(lines, op["name"], op["url"])
    updated = "\n".join(lines) + "\n"

    backup = config_path.with_name(
        config_path.name + ".bak.noctalia-subscription." + time.strftime("%Y%m%d_%H%M%S")
    )
    shutil.copy2(config_path, backup)
    mode = config_path.stat().st_mode & 0o777
    try:
        config_path.write_text(updated, encoding="utf-8")
        os.chmod(config_path, mode)
        validate_config(config_path, args.mihomo_bin)
    except Exception:
        shutil.copy2(backup, config_path)
        os.chmod(config_path, mode)
        raise

    if args.service and not args.no_restart:
        subprocess.run(["systemctl", "restart", args.service], check=True)
    op_path.unlink(missing_ok=True)
    print(json.dumps({
        "ok": True,
        "op": op["op"],
        "name": op["name"],
        "backup": str(backup),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
