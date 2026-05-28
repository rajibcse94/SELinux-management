# SELinux Management Toolkit

[![ShellCheck](https://github.com/rajibcse94/SELinux-management/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/rajibcse94/SELinux-management/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A single-file, dependency-light Bash toolkit that wraps the standard SELinux
userspace tools into one safe, consistent command-line interface for day-to-day
administration and troubleshooting.

It turns scattered commands like `getenforce`, `setenforce`, `semanage`,
`restorecon`, `ausearch`, `audit2allow`, `audit2why`, and `semodule` into a
single tool with sensible safety guards, readable output, and a guided
troubleshooter.

```
sudo ./selinux-toolkit.sh status
./selinux-toolkit.sh troubleshoot httpd
```

The repo ships **three** scripts:

| Script | Purpose |
| --- | --- |
| `selinux-toolkit.sh` | Day-to-day administration & troubleshooting |
| `selinux-config.sh`  | Changing configuration safely **and** auditing *what changed* |
| `selinux-tui.sh`     | A menu-driven (TUI) front-end for both of the above |

See [Configuration & change auditing](#configuration--change-auditing) for the
second tool and [Menu interface](#menu-interface) for the third.

## Features

- **status / healthcheck** — full status report and a read-only diagnostic
  (current mode, boot-config drift, recent denials, mislabeled files, loaded
  policy modules).
- **mode** — switch between enforcing / permissive / disabled, optionally
  persistent (backs up the config first; warns before disabling).
- **denials / explain / suggest** — summarize AVC denials, explain *why* they
  were blocked (`audit2why`), and draft a policy module (`audit2allow`).
  Generation and installation are deliberately separate steps.
- **bool** — list, read, and set SELinux booleans, with `--persistent` support.
- **fcontext / relabel** — add file-context rules, restore contexts, and
  compare expected vs. actual labels.
- **port** — list and label network ports (auto-falls back to modify).
- **module** — list, install, and remove policy modules with confirmation guards.
- **troubleshoot &lt;service&gt;** — gathers a service's denials, booleans, and port
  labels, then points to the next steps.
- **deps** — checks which tools are installed and prints the exact install
  command for your distro.

## Requirements

The toolkit calls standard SELinux userspace utilities. Install them with:

**RHEL / Fedora / Rocky / AlmaLinux / CentOS Stream**

```bash
sudo dnf install -y policycoreutils policycoreutils-python-utils \
     setools-console audit setroubleshoot-server
```

**Debian / Ubuntu** (SELinux is uncommon there; AppArmor is the default)

```bash
sudo apt install -y policycoreutils selinux-utils selinux-basics auditd
```

Run `./selinux-toolkit.sh deps` at any time to see what is present or missing.

## Installation

Clone and run directly:

```bash
git clone https://github.com/rajibcse94/SELinux-management.git
cd SELinux-management
chmod +x selinux-toolkit.sh
sudo ./selinux-toolkit.sh status
```

Optional — install system-wide so you can call it from anywhere:

```bash
sudo ./install.sh           # installs to /usr/local/bin/selinux-toolkit
selinux-toolkit status
```

## Usage

```
selinux-toolkit.sh <command> [options]
```

| Command | Description |
| --- | --- |
| `status` | Comprehensive status report |
| `mode <state> [--persistent]` | Set mode: `enforcing` \| `permissive` \| `disabled` |
| `denials [--since T] [--raw]` | Analyze AVC denials (default window: recent) |
| `explain` | Explain recent denials (`audit2why`) |
| `suggest [--name NAME]` | Draft a policy module from denials (does **not** install) |
| `bool list [filter]` | List booleans, optionally filtered |
| `bool get <name>` | Show one boolean |
| `bool set <name> <on\|off> [-p]` | Set a boolean (`-p` to persist) |
| `fcontext add <type> <path>` | Add a file-context rule |
| `fcontext restore <path>` | Apply contexts (`restorecon -Rv`) |
| `fcontext check <path>` | Compare expected vs. actual context |
| `port list [filter]` | List port labels |
| `port add <type> <tcp\|udp> <port>` | Label a network port |
| `module list [filter]` | List loaded policy modules |
| `module install <file.pp>` | Install a compiled policy module |
| `module remove <name>` | Remove a policy module |
| `relabel <path>` | Restore contexts recursively |
| `healthcheck` | Read-only diagnostic summary |
| `troubleshoot <service>` | Guided troubleshooting for a service |
| `deps` | Check tool dependencies |

### Examples

```bash
# Temporarily go permissive while debugging, surviving a reboot
sudo ./selinux-toolkit.sh mode permissive --persistent

# See what was denied today, grouped by process and class
./selinux-toolkit.sh denials --since today

# Let Apache make outbound network connections, persistently
sudo ./selinux-toolkit.sh bool set httpd_can_network_connect on --persistent

# Allow Apache to listen on a custom port
sudo ./selinux-toolkit.sh port add http_port_t tcp 8088

# Draft (review, then install) a policy fix for recent denials
./selinux-toolkit.sh suggest --name httpd_local
sudo ./selinux-toolkit.sh module install /tmp/selinux-suggest.XXXX/httpd_local.pp

# End-to-end help with one service
./selinux-toolkit.sh troubleshoot httpd
```

Set `NO_COLOR=1` to disable colored output (useful in logs and cron).

## Configuration & change auditing

`selinux-config.sh` is a companion tool focused on two things: changing SELinux
configuration safely, and showing exactly **what has changed** — either from the
shipped defaults or since a saved baseline. This works because SELinux tracks
your *local* customizations separately from the policy that ships with the OS.

### See what changed

```bash
# Show every place SELinux configuration comes from
./selinux-config.sh where

# Show only what YOU changed from the defaults (no setup needed)
./selinux-config.sh customizations

# Snapshot a baseline, make changes, then see precisely what moved
sudo ./selinux-config.sh snapshot before-tuning
sudo setsebool -P httpd_can_network_connect on
sudo ./selinux-config.sh diff before-tuning
```

### Change configuration

```bash
sudo ./selinux-config.sh set-mode permissive   # edits config + runtime, backs up first
sudo ./selinux-config.sh edit-config           # opens config in $EDITOR, backs up + diffs
sudo ./selinux-config.sh backup                # full backup of config + state
```

### Move customizations between hosts

```bash
sudo ./selinux-config.sh export my-policy.conf   # on host A
sudo ./selinux-config.sh import my-policy.conf   # on host B
```

| Command | Description |
| --- | --- |
| `where` | Show every file/source SELinux config comes from |
| `customizations` | Show everything changed from the shipped defaults |
| `snapshot [name]` | Save a full-state baseline |
| `list-snapshots` | List saved baselines |
| `diff [base] [base2]` | Compare baseline → current (or two baselines) |
| `export [file]` | Export local customizations to a portable file |
| `import <file>` | Apply customizations exported from another host |
| `set-mode <state>` | Set mode persistently (`enforcing`/`permissive`/`disabled`) |
| `edit-config` | Edit the config file in `$EDITOR` (auto-backup + diff) |
| `backup [dir]` | Full backup (config + state + customizations) |
| `restore-config <file>` | Restore the config file from a backup |

Snapshots and backups are stored under `/var/lib/selinux-config-audit`
(override with `SELINUX_STATE_DIR=/path`).

## Menu interface

`selinux-tui.sh` is a terminal menu front-end (a "GUI in the terminal") that
drives the other two scripts — handy if you prefer pointing and selecting over
typing commands. It works over SSH and needs no desktop environment.

It requires `whiptail` (package `newt`) or `dialog`:

```bash
sudo dnf install -y newt        # RHEL/Fedora
sudo apt install -y whiptail    # Debian/Ubuntu
```

Run it (keep all three scripts in the same directory):

```bash
chmod +x selinux-tui.sh
sudo ./selinux-tui.sh
```

```
┌─────────────────── Main Menu ───────────────────┐
│  SELinux Management — choose an area:            │
│    1   Status & Health                           │
│    2   Mode (enforcing/permissive/disabled)      │
│    3   Booleans                                  │
│    4   File Contexts                             │
│    5   Ports                                     │
│    6   Policy Modules                            │
│    7   Denials & Troubleshooting                 │
│    8   Config & Change Audit                     │
│    Q   Quit                                      │
└──────────────────────────────────────────────────┘
```

Navigate with the arrow keys, Enter to select, Esc/Back to go up a level.

> Prefer a graphical desktop GUI? RHEL-family systems ship native ones:
> `system-config-selinux` (install `policycoreutils-gui`), `sepolicy gui`, or the
> [Cockpit](https://cockpit-project.org/) web console, which has an SELinux panel.

## Safety notes

- Use `--dry-run` (or `-n`) on `selinux-toolkit.sh` and `selinux-config.sh` to
  preview exactly what a command would do without changing anything.
- Every state-changing action is recorded to an audit log
  (`/var/log/selinux-management.log`, override with `SELINUX_LOGFILE`). View it
  with `selinux-toolkit log` or `selinux-config log`.

- Actions that modify the system require root and prompt for confirmation when
  destructive (disabling SELinux, full relabel, removing a module).
- `mode --persistent` backs up `/etc/selinux/config` before editing it.
- `suggest` only **generates** a policy module — it never auto-installs.
  Reflexively allowing every denial defeats the purpose of SELinux, so review
  the generated `.te` rules before installing the `.pp`.
- Disabling SELinux is discouraged; prefer `permissive`, which logs without
  enforcing.

> This tooling targets the RHEL-family policy layout, where SELinux is standard.
> It runs on any system with the SELinux userspace installed, but most workflows
> assume the `targeted` policy.

## Contributing

Issues and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

Released under the [MIT License](LICENSE).
