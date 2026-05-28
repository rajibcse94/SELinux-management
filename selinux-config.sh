#!/usr/bin/env bash
#===============================================================================
# selinux-config.sh — SELinux configuration & change-audit tool
#
# A companion to selinux-toolkit.sh focused on TWO things:
#   1. Changing SELinux configuration safely (with automatic backups).
#   2. Seeing exactly WHAT has changed — from the shipped defaults, or since a
#      saved baseline snapshot.
#
# SELinux tracks your *local* customizations separately from the policy that
# ships with the OS, so "what did I change?" is answerable precisely:
#   - semanage boolean/fcontext/port/login -l -C  -> only YOUR changes
#   - semanage export                              -> all local mods, portable
#   - semodule -lfull                              -> modules + install priority
#
# Subcommands
#   ---- view what changed --------------------------------------------------
#   customizations           Show everything changed from the policy defaults
#   snapshot [name]          Save a baseline of the full current state
#   list-snapshots           List saved snapshots
#   diff [baseline]          Compare current state to a snapshot (or two snaps)
#   export [file]            Export local customizations (portable, re-importable)
#   ---- change configuration -----------------------------------------------
#   set-mode <state>         Set mode (enforcing|permissive|disabled), persistent
#   edit-config              Edit /etc/selinux/config in $EDITOR (with backup)
#   import <file>            Apply customizations exported from another host
#   backup [dir]             Full backup of config + customizations
#   restore-config <file>    Restore /etc/selinux/config from a backup
#   ---- misc ---------------------------------------------------------------
#   where                    Show every file/source SELinux config lives in
#   help
#===============================================================================

set -uo pipefail

PROG="${0##*/}"
VERSION="1.0.0"

SELINUX_CONFIG="/etc/selinux/config"
[[ -f "$SELINUX_CONFIG" ]] || SELINUX_CONFIG="/etc/sysconfig/selinux"

# Where snapshots/backups are stored (override with SELINUX_STATE_DIR=...)
STATE_DIR="${SELINUX_STATE_DIR:-/var/lib/selinux-config-audit}"
SNAP_DIR="$STATE_DIR/snapshots"

#--- colors -------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RST=$'\e[0m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'
    C_YLW=$'\e[33m'; C_BLU=$'\e[34m'; C_BLD=$'\e[1m'
else
    C_RST=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''
fi
info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
hdr()   { printf '\n%s%s== %s ==%s\n' "$C_BLD" "$C_BLU" "$*" "$C_RST"; }
sub()   { printf '\n%s-- %s --%s\n' "$C_BLD" "$*" "$C_RST"; }
die()   { err "$*"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
need_root() { [[ $EUID -eq 0 ]] || die "This action needs root. Re-run: sudo $PROG $*"; }
confirm() { local r; read -r -p "${1:-Are you sure?} [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }

# --dry-run support and an audit log of changes (set in main()).
DRYRUN="${DRYRUN:-0}"
LOGFILE="${SELINUX_LOGFILE:-/var/log/selinux-management.log}"

# Append an entry to the audit log (best-effort; never fails the script).
log_change() {
    [[ "$DRYRUN" == "1" ]] && return 0
    { printf '%s | %-14s | user=%s | %s\n' \
        "$(date -Is)" "$PROG" "${SUDO_USER:-${USER:-root}}" "$*" >> "$LOGFILE"; } 2>/dev/null || true
}

# Run a state-changing command, honoring --dry-run and logging it.
run() {
    if [[ "$DRYRUN" == "1" ]]; then
        info "[dry-run] would run: $*"
        return 0
    fi
    log_change "$*"
    "$@"
}

require_semanage() {
    have semanage || die "'semanage' not found. Install policycoreutils-python-utils."
}

ts() { date +%Y%m%d-%H%M%S; }

#==============================================================================
# where — show every place SELinux configuration comes from
#==============================================================================
cmd_where() {
    hdr "Where SELinux configuration lives"
    cat <<EOF
${C_BLD}Boot-time mode & policy type${C_RST}
  $SELINUX_CONFIG
      SELINUX=      -> enforcing | permissive | disabled  (mode at next boot)
      SELINUXTYPE=  -> targeted | mls | minimum           (which policy)

${C_BLD}Runtime mode (this boot only, not saved)${C_RST}
  setenforce 0|1            -> changes mode now; lost on reboot
  /sys/fs/selinux/enforce   -> live kernel value

${C_BLD}Your local customizations (tracked separately from the OS policy)${C_RST}
  Booleans      semanage boolean  -l -C   (or setsebool -P)
  File contexts semanage fcontext -l -C   stored in *.local under:
                /etc/selinux/${SELINUXTYPE:-targeted}/contexts/files/file_contexts.local
  Ports         semanage port     -l -C
  Logins        semanage login    -l -C
  Users         semanage user     -l -C

${C_BLD}Policy modules${C_RST}
  semodule -lfull          -> name + priority (custom modules = priority 400)
  /var/lib/selinux/${SELINUXTYPE:-targeted}/active/modules/

${C_BLD}Kernel boot parameters (override everything)${C_RST}
  /proc/cmdline   ->  selinux=0 disables it entirely; enforcing=0 forces permissive
EOF
    if [[ -f "$SELINUX_CONFIG" ]]; then
        sub "Current $SELINUX_CONFIG (non-comment lines)"
        grep -vE '^\s*#|^\s*$' "$SELINUX_CONFIG" || true
    fi
}

#==============================================================================
# customizations — what differs from the shipped defaults (no baseline needed)
#==============================================================================
cmd_customizations() {
    require_semanage
    hdr "Local customizations vs. shipped policy defaults"
    info "These are changes made on THIS system; defaults are not listed."

    sub "Booleans you changed"
    local b; b="$(semanage boolean -l -C 2>/dev/null)"
    if [[ -n "$b" ]]; then printf '%s\n' "$b"; else ok "None — all booleans at default."; fi

    sub "File contexts you added"
    local f; f="$(semanage fcontext -l -C 2>/dev/null)"
    if [[ -n "$f" ]]; then printf '%s\n' "$f"; else ok "None added."; fi

    sub "Ports you relabeled"
    local p; p="$(semanage port -l -C 2>/dev/null)"
    if [[ -n "$p" ]]; then printf '%s\n' "$p"; else ok "None — all ports at default."; fi

    sub "Login mappings you changed"
    local l; l="$(semanage login -l -C 2>/dev/null)"
    if [[ -n "$l" ]]; then printf '%s\n' "$l"; else ok "None."; fi

    sub "SELinux users you changed"
    local u; u="$(semanage user -l -C 2>/dev/null)"
    if [[ -n "$u" ]]; then printf '%s\n' "$u"; else ok "None."; fi

    sub "Custom policy modules (priority > 100 are admin-installed)"
    if have semodule; then
        local m; m="$(semodule -lfull 2>/dev/null | awk '$1!=100{print}')"
        if [[ -n "$m" ]]; then printf '%s\n' "$m"; else ok "Only base modules present."; fi
    fi

    echo
    info "Save this state as a baseline:   $PROG snapshot"
    info "Export it to move to another host: $PROG export selinux-custom.conf"
}

#==============================================================================
# snapshot — capture the full current state to a single diff-able file
#==============================================================================
build_snapshot() {
    # writes a full-state snapshot to stdout
    printf '### SELINUX-CONFIG-SNAPSHOT v1\n'
    printf '### timestamp: %s\n' "$(date -Is)"
    printf '### hostname : %s\n' "$(hostname)"

    printf '\n#=== MODE (runtime) ===\n'
    have getenforce && getenforce

    printf '\n#=== CONFIG FILE (%s) ===\n' "$SELINUX_CONFIG"
    [[ -f "$SELINUX_CONFIG" ]] && grep -vE '^\s*#|^\s*$' "$SELINUX_CONFIG"

    printf '\n#=== BOOLEANS (all) ===\n'
    have getsebool && getsebool -a 2>/dev/null

    printf '\n#=== LOCAL BOOLEANS (customized) ===\n'
    have semanage && semanage boolean -l -C 2>/dev/null

    printf '\n#=== LOCAL FCONTEXTS ===\n'
    have semanage && semanage fcontext -l -C 2>/dev/null

    printf '\n#=== LOCAL PORTS ===\n'
    have semanage && semanage port -l -C 2>/dev/null

    printf '\n#=== LOCAL LOGINS ===\n'
    have semanage && semanage login -l -C 2>/dev/null

    printf '\n#=== MODULES (full, name + priority) ===\n'
    have semodule && semodule -lfull 2>/dev/null
}

cmd_snapshot() {
    require_semanage
    need_root "snapshot"
    mkdir -p "$SNAP_DIR"
    local name="${1:-snapshot-$(ts)}"
    local file="$SNAP_DIR/${name}.snap"
    build_snapshot > "$file"
    ok "Snapshot saved: $file"
    info "Compare later with: $PROG diff '$name'"
}

cmd_list_snapshots() {
    hdr "Saved snapshots in $SNAP_DIR"
    if [[ -d "$SNAP_DIR" ]] && compgen -G "$SNAP_DIR/*.snap" >/dev/null; then
        local f
        for f in "$SNAP_DIR"/*.snap; do
            local when; when="$(grep -m1 '^### timestamp:' "$f" | cut -d' ' -f3-)"
            printf '  %-40s  %s\n' "$(basename "$f" .snap)" "$when"
        done
    else
        warn "No snapshots yet. Create one with: $PROG snapshot"
    fi
}

#==============================================================================
# diff — compare current state to a baseline snapshot (or two snapshots)
#==============================================================================
cmd_diff() {
    require_semanage
    local a="${1:-}" b="${2:-}"
    local fa fb tmp_current=""

    resolve_snap() {
        local n="$1"
        if [[ -f "$n" ]]; then echo "$n"
        elif [[ -f "$SNAP_DIR/${n}.snap" ]]; then echo "$SNAP_DIR/${n}.snap"
        else return 1; fi
    }

    if [[ -z "$a" ]]; then
        # most recent snapshot vs current live state
        a="$(ls -1t "$SNAP_DIR"/*.snap 2>/dev/null | head -1)" \
            || die "No snapshots found. Create one first: $PROG snapshot"
        [[ -n "$a" ]] || die "No snapshots found. Run: $PROG snapshot"
        fa="$a"
        tmp_current="$(mktemp)"; build_snapshot > "$tmp_current"; fb="$tmp_current"
        info "Comparing baseline '$(basename "$fa" .snap)' -> CURRENT live state"
    elif [[ -z "$b" ]]; then
        fa="$(resolve_snap "$a")" || die "Snapshot not found: $a"
        tmp_current="$(mktemp)"; build_snapshot > "$tmp_current"; fb="$tmp_current"
        info "Comparing baseline '$a' -> CURRENT live state"
    else
        fa="$(resolve_snap "$a")" || die "Snapshot not found: $a"
        fb="$(resolve_snap "$b")" || die "Snapshot not found: $b"
        info "Comparing '$a' -> '$b'"
    fi

    hdr "Changes (- baseline, + newer)"
    if diff -u --label "BASELINE" --label "CURRENT" "$fa" "$fb" \
        | grep -vE '^(### timestamp|### hostname|---|\+\+\+|@@)' \
        | grep -E '^[+-]' ; then
        :
    else
        ok "No differences — state matches the baseline."
    fi
    [[ -n "$tmp_current" ]] && rm -f "$tmp_current"
}

#==============================================================================
# export / import — portable customizations (move config between hosts)
#==============================================================================
cmd_export() {
    require_semanage
    need_root "export"
    local file="${1:-selinux-customizations-$(ts).conf}"
    if semanage export -f "$file" 2>/dev/null; then
        ok "Local customizations exported to: $file"
    elif semanage export -f /dev/stdout > "$file" 2>/dev/null; then
        ok "Local customizations exported to: $file"
    else
        die "semanage export failed (older semanage may not support it)."
    fi
    info "Re-apply on another host with: $PROG import '$file'"
}

cmd_import() {
    require_semanage
    need_root "import $*"
    local file="${1:?Usage: $PROG import <file>}"
    [[ -f "$file" ]] || die "File not found: $file"
    warn "This will apply SELinux customizations from: $file"
    [[ "$DRYRUN" == "1" ]] || { confirm "Proceed?" || { info "Aborted."; return 0; }; }
    run semanage import -f "$file" && ok "Customizations imported." \
        || die "Import failed."
}

#==============================================================================
# set-mode — change mode persistently (config) + runtime, with backup
#==============================================================================
cmd_set_mode() {
    local state="${1:?Usage: $PROG set-mode <enforcing|permissive|disabled>}"
    need_root "set-mode $state"
    [[ -f "$SELINUX_CONFIG" ]] || die "Config not found: $SELINUX_CONFIG"

    case "$state" in enforcing|permissive|disabled) ;; *)
        die "State must be enforcing | permissive | disabled." ;;
    esac

    if [[ "$state" == "disabled" ]]; then
        warn "Disabling SELinux is discouraged and only applies after reboot."
        [[ "$DRYRUN" == "1" ]] || { confirm "Continue anyway?" || { info "Aborted."; return 0; }; }
    fi

    if [[ "$DRYRUN" == "1" ]]; then
        info "[dry-run] would set SELINUX=$state in $SELINUX_CONFIG (with backup) and apply at runtime."
        return 0
    fi

    local backup="${SELINUX_CONFIG}.bak.$(ts)"
    cp -a "$SELINUX_CONFIG" "$backup" && info "Backed up config -> $backup"
    log_change "set-mode $state: edit $SELINUX_CONFIG + runtime apply"

    if grep -qE '^SELINUX=' "$SELINUX_CONFIG"; then
        sed -i -E "s/^SELINUX=.*/SELINUX=${state}/" "$SELINUX_CONFIG"
    else
        printf 'SELINUX=%s\n' "$state" >> "$SELINUX_CONFIG"
    fi
    ok "Boot config set: SELINUX=$state"

    # apply at runtime where possible
    if [[ "$state" == "enforcing" ]] && have setenforce; then
        setenforce 1 && ok "Runtime mode set to Enforcing."
    elif [[ "$state" == "permissive" ]] && have setenforce; then
        setenforce 0 && ok "Runtime mode set to Permissive."
    elif [[ "$state" == "disabled" ]]; then
        warn "Reboot required for 'disabled' to take effect."
    fi
    info "View the change: $PROG where"
}

#==============================================================================
# edit-config — open the config in an editor with a backup first
#==============================================================================
cmd_edit_config() {
    need_root "edit-config"
    [[ -f "$SELINUX_CONFIG" ]] || die "Config not found: $SELINUX_CONFIG"
    local backup="${SELINUX_CONFIG}.bak.$(ts)"
    cp -a "$SELINUX_CONFIG" "$backup" && info "Backup saved -> $backup"
    "${EDITOR:-vi}" "$SELINUX_CONFIG"
    ok "Done. Diff vs backup:"
    diff -u "$backup" "$SELINUX_CONFIG" && ok "No changes made." || true
}

#==============================================================================
# backup / restore-config
#==============================================================================
cmd_backup() {
    require_semanage
    need_root "backup"
    local dir="${1:-$STATE_DIR/backups/backup-$(ts)}"
    mkdir -p "$dir"
    [[ -f "$SELINUX_CONFIG" ]] && cp -a "$SELINUX_CONFIG" "$dir/config"
    build_snapshot > "$dir/full-state.snap"
    semanage export -f "$dir/customizations.conf" 2>/dev/null \
        || semanage export -f /dev/stdout > "$dir/customizations.conf" 2>/dev/null || true
    ok "Backup written to: $dir"
    ls -la "$dir"
}

cmd_restore_config() {
    need_root "restore-config $*"
    local file="${1:?Usage: $PROG restore-config <backup-file>}"
    [[ -f "$file" ]] || die "Backup not found: $file"
    if [[ "$DRYRUN" == "1" ]]; then
        info "[dry-run] would overwrite $SELINUX_CONFIG with $file (after backup)."
        return 0
    fi
    confirm "Overwrite $SELINUX_CONFIG with $file?" || { info "Aborted."; return 0; }
    cp -a "$SELINUX_CONFIG" "${SELINUX_CONFIG}.bak.$(ts)" 2>/dev/null || true
    log_change "restore-config from $file"
    cp -a "$file" "$SELINUX_CONFIG" && ok "Config restored from $file"
    warn "A reboot may be needed if the mode changed."
}

#==============================================================================
# log — show the change audit log
#==============================================================================
cmd_log() {
    hdr "Change audit log ($LOGFILE)"
    if [[ -f "$LOGFILE" ]]; then
        local n="${1:-40}"
        tail -n "$n" "$LOGFILE"
    else
        warn "No log yet at $LOGFILE — it is created the first time a change is made."
    fi
}

#==============================================================================
# usage / dispatch
#==============================================================================
usage() {
    cat <<EOF
${C_BLD}$PROG${C_RST} v$VERSION — SELinux configuration & change-audit tool

${C_BLD}SEE WHAT CHANGED${C_RST}
  customizations            Show everything changed from the shipped defaults
  snapshot [name]           Save a full-state baseline
  list-snapshots            List saved baselines
  diff [base] [base2]       Compare baseline -> current (or two baselines)
  export [file]             Export local customizations (portable file)
  where                     Show every file/source SELinux config comes from

${C_BLD}CHANGE CONFIGURATION${C_RST}
  set-mode <state>          enforcing | permissive | disabled (persistent)
  edit-config               Edit $SELINUX_CONFIG in \$EDITOR (auto-backup)
  import <file>             Apply customizations exported elsewhere
  backup [dir]              Full backup (config + state + customizations)
  restore-config <file>     Restore the config file from a backup
  log [N]                   Show the last N change-audit entries (default 40)

${C_BLD}GLOBAL FLAGS${C_RST}
  --dry-run, -n             Show what would change without doing it

${C_BLD}EXAMPLES${C_RST}
  # Preview a change without applying it:
  sudo $PROG set-mode permissive --dry-run

  # Establish a baseline today, change things, then see exactly what moved:
  sudo $PROG snapshot before-tuning
  sudo setsebool -P httpd_can_network_connect on
  sudo $PROG diff before-tuning

  # Just answer "what have I changed from defaults?"
  $PROG customizations

  # Review the audit trail of changes this tool made:
  $PROG log

  # Move all your SELinux tweaks to another server:
  sudo $PROG export my-policy.conf      # on host A
  sudo $PROG import my-policy.conf      # on host B

Snapshots/backups are stored in: $STATE_DIR
Changes are logged to: $LOGFILE  (override with SELINUX_LOGFILE=/path)
Override state dir with SELINUX_STATE_DIR=/path ; disable color with NO_COLOR=1.
EOF
}

main() {
    # Global flags can appear anywhere; strip them before dispatch.
    local args=()
    for a in "$@"; do
        case "$a" in
            --dry-run|-n) DRYRUN=1 ;;
            *) args+=("$a") ;;
        esac
    done
    set -- "${args[@]:-}"
    [[ "$DRYRUN" == "1" ]] && warn "DRY-RUN mode: no changes will be made."

    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        customizations|custom)  cmd_customizations "$@" ;;
        snapshot)               cmd_snapshot "$@" ;;
        list-snapshots|ls)      cmd_list_snapshots "$@" ;;
        diff)                   cmd_diff "$@" ;;
        export)                 cmd_export "$@" ;;
        import)                 cmd_import "$@" ;;
        where)                  cmd_where "$@" ;;
        set-mode)               cmd_set_mode "$@" ;;
        edit-config)            cmd_edit_config "$@" ;;
        backup)                 cmd_backup "$@" ;;
        restore-config)         cmd_restore_config "$@" ;;
        log)                    cmd_log "$@" ;;
        help|-h|--help)         usage ;;
        version|-v|--version)   echo "$PROG v$VERSION" ;;
        *) err "Unknown command: $cmd"; echo; usage; exit 1 ;;
    esac
}

main "$@"
