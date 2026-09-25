# Contributing

Contributions are welcome, especially fixes for portability, privilege handling,
and controller compatibility.

## Before Opening A Pull Request

1. Run `make test`.
2. Run `make lint` if Noctalia is installed.
3. Update `CHANGELOG.md` for user-visible changes.
4. Keep the plugin's local-systemd/TUN-control scope intact. General dashboard
   features should be discussed before implementation.

## Development Principles

- The service entry owns all child processes and controller access.
- Widget, panel, and shortcut scripts only read shared state and send commands.
- Never write the controller secret to plugin state or logs.
- Keep helper output as one JSON object per invocation.
- Preserve compatibility with the declared `plugin_api`.

## Reporting Bugs

Include:

- Noctalia and Mihomo versions.
- Distribution and whether the unit is system or user scoped.
- Relevant JSON output from `mihomo-ctl.py`.
- Redacted Noctalia logs.

Never post a real controller secret, subscription URL, or full provider config.
