# Changelog

All notable changes to this project are documented here.

## [1.2.1] - 2026-09-26

### Fixed

- Align subscription and direct-rule list cards with the page header by removing
  the scroll view's extra horizontal inset.
- Replace the static processing glyph with a frame-based rotating spinner.

## [1.2.0] - 2026-09-25

### Added

- Add, edit, rename, and delete managed subscriptions from the subscription
  page.
- A focused `apply-subscription-change.py` helper used through `pkexec` for
  each privileged subscription change.
- Confirmation controls for provider deletion.

### Changed

- Align subscription and direct-rule pages to the same full-width card layout.
- Increase the floating panel to `600 × 780`.

## [1.1.1] - 2026-09-25

### Fixed

- Store the generated rule-provider YAML under `/etc/mihomo/noctalia`, which is
  accepted by Mihomo's `SAFE_PATHS`.
- Let the one-time setup helper create and own that directory as the invoking
  desktop user.

## [1.1.0] - 2026-09-25

### Added

- Subscription management page with provider quotas, expiry, node counts, and
  per-provider or bulk updates.
- Domestic direct-rule page for domains, exact domains, IPv4, IPv6, and CIDR
  networks.
- Managed `noctalia-direct` rule-provider integration.
- One-time `configure-direct-rules.py` setup helper with config backup and
  validation.
- Standalone CLI commands for provider and direct-rule management.

## [1.0.0] - 2026-09-25

### Added

- Initial standalone project.
- Noctalia bar widget, floating control panel, and control-center shortcut.
- Systemd service start, stop, and toggle support.
- Controller secret-file authentication without storing the secret in settings.
- Proxy mode, group, node, latency, provider update, and exit IP actions.
- Standalone `mihomo-ctl.py` JSON CLI.
- English and Simplified Chinese interface strings.
- Fake-controller unit tests and GitHub Actions CI.
