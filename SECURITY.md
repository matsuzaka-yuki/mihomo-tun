# Security Policy

## Supported Versions

Security fixes are applied to the latest release and the `main` branch.

## Reporting A Vulnerability

Do not open a public issue for a vulnerability involving secret disclosure,
command execution, privilege escalation, or clipboard leakage. Send a private
report to the maintainer using the security contact listed on the repository
hosting service.

Include:

- Affected version.
- Reproduction steps.
- Whether a secret, local command execution, or service-control boundary is
  involved.
- Suggested mitigation, if known.

## Trust Boundaries

This plugin can:

- Read a configured local secret file.
- Send authenticated requests to the configured Mihomo controller.
- Run `systemctl start` and `systemctl stop` for the configured unit.
- Request `pkexec` authorization to apply add/edit/delete changes to
  `proxy-providers` in `/etc/mihomo/config.yaml`.
- Place the controller secret on the Wayland clipboard when explicitly asked.
- Launch the controller web UI through `xdg-open`.
- Write managed direct-rule metadata under the Noctalia plugin data directory
  and the user-owned provider YAML under `/etc/mihomo/noctalia`.

It does not:

- Store the secret in Noctalia settings.
- Run `sudo`.
- Install a setuid helper.
- Open a network listener.
- Modify `/etc/mihomo`, firewall rules, or routing policy.

The optional `configure-direct-rules.py` helper does modify the Mihomo config,
but it is run explicitly with root privileges. It creates a timestamped backup,
validates the candidate config, and restores the backup on failure.

`apply-subscription-change.py` follows the same rule: it is invoked through
`pkexec`, edits only the named `proxy-providers` entry, writes a timestamped
backup, validates with `mihomo -t`, and restores the backup on failure.
