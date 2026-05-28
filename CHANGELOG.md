# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `selinux-tui.sh`: a menu-driven (TUI) front-end that drives the other scripts.
  Now at full parity with the CLI — every command (including `relabel`, `import`,
  `edit-config`, `restore-config`, and the audit `log`) is reachable from the
  menu, with confirmation dialogs for destructive actions and a session-wide
  dry-run toggle.
- `selinux-config.sh`: configuration and change-audit tool (`customizations`,
  `snapshot`, `diff`, `where`, `export`, `import`, `backup`, `restore-config`).
- Global `--dry-run` / `-n` flag on `selinux-toolkit.sh` and `selinux-config.sh`
  that previews changes without applying them.
- Global `--yes` / `-y` flag for non-interactive use (skips confirmation
  prompts); used internally by the TUI, which runs its own dialogs.
- Change audit log: state-changing actions are appended to
  `/var/log/selinux-management.log` (override with `SELINUX_LOGFILE`), viewable
  with the new `log` subcommand.
- GitHub Actions workflow that runs ShellCheck on every push and pull request.
- `install.sh` now installs all three scripts.

### Changed
- Help text examples now use the correct `./script.sh` invocation and note the
  installed command name.

## [1.0.0] - 2026-05-28

### Added
- Initial release of `selinux-toolkit.sh` with subcommands: `status`, `mode`,
  `denials`, `explain`, `suggest`, `bool`, `fcontext`, `port`, `module`,
  `relabel`, `healthcheck`, `troubleshoot`, and `deps`.
- README, MIT license, contributing guide, and installer.

[Unreleased]: https://github.com/rajibcse94/SELinux-management/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/rajibcse94/SELinux-management/releases/tag/v1.0.0
