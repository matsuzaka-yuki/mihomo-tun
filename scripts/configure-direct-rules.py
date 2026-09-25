#!/usr/bin/env python3
"""Install the Mihomo TUN Control direct-rule provider into a Mihomo config.

Run this once with root privileges. The plugin can then update the provider
file and refresh it through the controller API without further privilege.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


PROVIDER_NAME = "noctalia-direct"
RULE_LINE = "  - RULE-SET,%s,DIRECT" % PROVIDER_NAME
START = "# BEGIN Mihomo TUN Control direct exclusions"
END = "# END Mihomo TUN Control direct exclusions"


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


def provider_entry(indent):
    prefix = " " * indent
    return [
        prefix + PROVIDER_NAME + ":",
        prefix + "  type: file",
        prefix + "  behavior: classical",
        prefix + "  format: yaml",
        prefix + "  path: " + repr(args.rules_path),
    ]


def remove_managed_provider(lines):
    first = next((index for index, line in enumerate(lines) if line == START), None)
    if first is None:
        return lines
    last = next((index for index in range(first, len(lines)) if lines[index] == END), None)
    if last is None:
        raise SystemExit("发现不完整的受管配置块：" + START)
    return lines[:first] + lines[last + 1:]


def install_provider(text):
    lines = remove_managed_provider(text.splitlines())
    section = find_section(lines, "rule-providers")
    if section is None:
        proxy_groups = find_section(lines, "proxy-groups")
        if proxy_groups is None:
            raise SystemExit("找不到顶层 proxy-groups，无法确定 rule-providers 插入位置")
        block = [START, "rule-providers:"] + provider_entry(2) + [END, ""]
        lines[proxy_groups[0]:proxy_groups[0]] = block
    else:
        start, end = section
        for index in range(start + 1, end):
            if lines[index].strip() == PROVIDER_NAME + ":":
                raise SystemExit(
                    "配置里已有未受管的 %s，请先手动移除或改名后再运行" % PROVIDER_NAME
                )
        block = [START] + provider_entry(2) + [END]
        lines[end:end] = block
    return "\n".join(lines) + "\n"


def install_rule(text):
    lines = text.splitlines()
    rules = find_section(lines, "rules")
    if rules is None:
        raise SystemExit("找不到顶层 rules")
    start, _ = rules
    for line in lines[start + 1:]:
        if line.strip() == RULE_LINE.strip():
            return "\n".join(lines) + "\n"
        if line and not line.startswith((" ", "#")):
            break
    lines[start + 1:start + 1] = [
        "  # Managed by Mihomo TUN Control; keep this rule before broad CN rules.",
        RULE_LINE,
    ]
    return "\n".join(lines) + "\n"


def render_config(text):
    return install_rule(install_provider(text))


def validate(config_path, mihomo_bin):
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
    parser.add_argument("--rules-path", required=True)
    parser.add_argument("--mihomo-bin", default="/usr/bin/mihomo")
    parser.add_argument("--service")
    parser.add_argument("--no-restart", action="store_true")
    global args
    args = parser.parse_args()

    config_path = Path(args.config)
    if os.geteuid() != 0:
        raise SystemExit("请用 root 运行，例如 sudo python3 configure-direct-rules.py ...")
    if not config_path.is_file():
        raise SystemExit("找不到配置文件：%s" % config_path)
    if not Path(args.mihomo_bin).is_file():
        raise SystemExit("找不到 mihomo：%s" % args.mihomo_bin)

    original = config_path.read_text(encoding="utf-8")
    updated = render_config(original)
    if updated == original:
        print("direct-rule provider 已配置，无需修改")
        return

    backup = config_path.with_name(
        config_path.name + ".bak.noctalia-direct." + time.strftime("%Y%m%d_%H%M%S")
    )
    shutil.copy2(config_path, backup)
    mode = config_path.stat().st_mode & 0o777

    try:
        config_path.write_text(updated, encoding="utf-8")
        os.chmod(config_path, mode)
        validate(config_path, args.mihomo_bin)
    except Exception:
        shutil.copy2(backup, config_path)
        os.chmod(config_path, mode)
        raise

    if args.service and not args.no_restart:
        subprocess.run(["systemctl", "restart", args.service], check=True)

    print("已配置 %s" % PROVIDER_NAME)
    print("规则文件：%s" % args.rules_path)
    print("配置备份：%s" % backup)


if __name__ == "__main__":
    main()
