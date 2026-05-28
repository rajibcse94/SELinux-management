#!/usr/bin/env bash
#===============================================================================
# selinux-toolkit.sh — SELinux management & diagnostic toolkit
#
# A single-file wrapper around the standard SELinux userspace tools that makes
# day-to-day administration and troubleshooting safer and faster.
#
# Subcommands:
#   status                         Comprehensive SELinux status report
#   mode <state> [--persistent]    Set mode: enforcing | permissive | disabled
#   denials [opts]                 Analyze AVC denials from the audit log
#   explain                        Run audit2why on recent denials
#   suggest [--name NAME]          Generate (don't install) a policy module
#   bool <list|get|set> ...        Manage SELinux booleans
#   fcontext <add|restore|check>   Manage file contexts
#   port <list|add> ...            Manage network port labeling
#   module <list|install|remove>   Manage SELinux policy modules
#   relabel <path>                 Restore file contexts recursively
#   healthcheck                    Full read-only diagnostic
#   troubleshoot <service>         Guided troubleshooting for a service
#   deps                           Check required tool dependencies
#
# Dependencies (install on RHEL/Fedora/Rocky/Alma):
#   dnf install -y policycoreutils policycoreutils-python-utils \
#                  setools-console audit setroubleshoot-server
# On Debian/Ubuntu (SELinux is uncommon there):
#   apt install -y policycoreutils selinux-utils selinux-basics auditd
#===============================================================================

set -uo pipefail

#--- constants ----------------------------------------------------------------
PROG="${0##*/}"
VERSION="1.0.0"

SELINUX_CONFIG="/etc/selinux/config"
[[ -f "$SELINUX_CONFIG" ]] || SELINUX_CONFIG="/etc/sysconfig/selinux"

# colors (disabled if not a TTY or NO_COLOR set)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RST=$'\e[0m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'
    C_YLW=$'\e[33m'; C_BLU=$'\e[34m'; C_BLD=$'\e[1m'
else
    C_RST=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''
fi

#--- output helpers -----------------------------------------------------------
info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
hdr()   { printf '\n%s%s== %s ==%s\n' "$C_BLD" "$C_BLU" "$*" "$C_RST"; }
die()   { err "$*"; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    have "$1" || die "Required command '$1' not found. Run: $PROG deps"
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This action requires root. Re-run with sudo: sudo $PROG $*"
    fi
}

confirm() {
    local prompt="${1:-Are you sure?}"
    local reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

#--- guard: SELinux must be present at all -------------------------------------
selinux_present() {
    have getenforce && [[ "$(getenforce 2>/dev/null)" != "Disabled" || -d /sys/fs/selinux ]]
}

#==============================================================================
# status
#==============================================================================
cmd_status() {
    hdr "SELinux Status"
    if ! have getenforce; then
        err "SELinux userspace tools not installed (getenforce missing)."
        info "Install with: $PROG deps"
        return 1
    fi

    local mode; mode="$(getenforce 2>/dev/null)"
    case "$mode" in
        Enforcing)  ok  "Current mode: ${C_GRN}Enforcing${C_RST}" ;;
        Permissive) warn "Current mode: Permissive (policy logged, not enforced)" ;;
        Disabled)   err "Current mode: Disabled" ;;
        *)          warn "Current mode: unknown ($mode)" ;;
    esac

    if [[ -f "$SELINUX_CONFIG" ]]; then
        local boot_mode boot_policy
        boot_mode="$(grep -E '^SELINUX=' "$SELINUX_CONFIG" | head -1 | cut -d= -f2)"
        boot_policy="$(grep -E '^SELINUXTYPE=' "$SELINUX_CONFIG" | head -1 | cut -d= -f2)"
        info "Mode at next boot : ${boot_mode:-unset}  (from $SELINUX_CONFIG)"
        info "Policy type       : ${boot_policy:-unset}"
        if [[ "$mode" != "${boot_mode^}" && -n "$boot_mode" ]]; then
            warn "Runtime mode differs from boot config — change is not persistent."
        fi
    fi

    if have sestatus; then
        hdr "sestatus"
        sestatus
    fi

    hdr "Recent denials (last 10 min)"
    local n=0
    if have ausearch; then
        n="$(ausearch -m avc,user_avc -ts recent 2>/dev/null | grep -c 'type=.*AVC' || true)"
    fi
    if [[ "$n" -gt 0 ]]; then
        warn "$n AVC denial record(s) found recently. Run: $PROG denials"
    else
        ok "No recent AVC denials detected."
    fi
}

#==============================================================================
# mode
#==============================================================================
cmd_mode() {
    local state="${1:-}" persistent=0
    shift || true
    for arg in "$@"; do
        case "$arg" in
            --persistent|-p) persistent=1 ;;
            *) die "Unknown option: $arg" ;;
        esac
    done
    [[ -n "$state" ]] || die "Usage: $PROG mode <enforcing|permissive|disabled> [--persistent]"
    need_root "mode $state"
    require_cmd setenforce

    case "$state" in
        enforcing|Enforcing|1)
            setenforce 1 && ok "Runtime mode set to Enforcing."
            [[ $persistent -eq 1 ]] && persist_mode enforcing
            ;;
        permissive|Permissive|0)
            setenforce 0 && ok "Runtime mode set to Permissive."
            [[ $persistent -eq 1 ]] && persist_mode permissive
            ;;
        disabled|Disabled)
            warn "Disabling SELinux is strongly discouraged and cannot be done at runtime."
            warn "It only takes effect after a reboot and requires a full relabel to re-enable."
            confirm "Write SELINUX=disabled to $SELINUX_CONFIG anyway?" || { info "Aborted."; return 0; }
            persist_mode disabled
            warn "Reboot required. Consider 'permissive' instead — it logs without enforcing."
            ;;
        *) die "Invalid state '$state'. Use enforcing | permissive | disabled." ;;
    esac
}

persist_mode() {
    local want="$1"
    [[ -f "$SELINUX_CONFIG" ]] || die "Config file not found: $SELINUX_CONFIG"
    cp -a "$SELINUX_CONFIG" "${SELINUX_CONFIG}.bak.$(date +%s)" \
        && info "Backed up config."
    if grep -qE '^SELINUX=' "$SELINUX_CONFIG"; then
        sed -i -E "s/^SELINUX=.*/SELINUX=${want}/" "$SELINUX_CONFIG"
    else
        printf 'SELINUX=%s\n' "$want" >> "$SELINUX_CONFIG"
    fi
    ok "Persistent mode set to '$want' (effective next boot)."
}

#==============================================================================
# denials
#==============================================================================
cmd_denials() {
    local since="recent" view="summary"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since) since="${2:?--since needs a value}"; shift 2 ;;
            --summary) view="summary"; shift ;;
            --raw) view="raw"; shift ;;
            *) die "Unknown option: $1 (try --since, --summary, --raw)" ;;
        esac
    done
    require_cmd ausearch

    hdr "AVC denials since: $since"
    local raw
    raw="$(ausearch -m avc,user_avc -ts "$since" 2>/dev/null)"
    if [[ -z "$raw" ]]; then
        ok "No AVC denials found in the selected window."
        return 0
    fi

    if [[ "$view" == "raw" ]]; then
        printf '%s\n' "$raw"
        return 0
    fi

    # Human summary: who got denied doing what to what
    printf '%s\n' "$raw" \
      | grep -oE 'comm="[^"]*"|scontext=[^ ]*|tcontext=[^ ]*|tclass=[^ ]*|denied[[:space:]]*\{[^}]*\}' \
      | awk '
          /^comm=/      { comm=$0 }
          /^denied/     { act=$0 }
          /^scontext=/  { s=$0 }
          /^tcontext=/  { t=$0 }
          /^tclass=/    { c=$0;
              key=comm" | "act" | "c;
              count[key]++ }
          END {
              for (k in count) printf "  %4d x  %s\n", count[k], k
          }' | sort -rn

    echo
    info "Tip: '$PROG explain' shows *why*, '$PROG suggest' drafts a policy fix."
}

#==============================================================================
# explain (audit2why)
#==============================================================================
cmd_explain() {
    require_cmd ausearch
    have audit2why || die "audit2why not found (part of policycoreutils-python-utils)."
    hdr "Why were recent denials blocked?"
    ausearch -m avc,user_avc -ts recent 2>/dev/null | audit2why \
        || ok "No recent denials to explain."
}

#==============================================================================
# suggest (audit2allow — generate only, never auto-install)
#==============================================================================
cmd_suggest() {
    local name="local_avc"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="${2:?--name needs a value}"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    require_cmd ausearch
    have audit2allow || die "audit2allow not found (policycoreutils-python-utils)."

    local denials
    denials="$(ausearch -m avc,user_avc -ts recent 2>/dev/null)"
    [[ -n "$denials" ]] || { ok "No recent denials — nothing to suggest."; return 0; }

    hdr "Proposed policy rules (.te) for '$name'"
    warn "Review these carefully. Blindly allowing denials can defeat SELinux's purpose."
    echo
    printf '%s\n' "$denials" | audit2allow -m "$name"

    local outdir; outdir="$(mktemp -d /tmp/selinux-suggest.XXXXXX)"
    printf '%s\n' "$denials" | audit2allow -M "$name" >/dev/null 2>&1 \
        && { mv -f "${name}.te" "${name}.pp" "$outdir/" 2>/dev/null; \
             ok "Compiled module written to: $outdir/${name}.pp"; \
             info "Inspect $outdir/${name}.te, then install with:"; \
             info "  $PROG module install $outdir/${name}.pp"; }
}

#==============================================================================
# bool
#==============================================================================
cmd_bool() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        list)
            require_cmd getsebool
            local filter="${1:-}"
            if [[ -n "$filter" ]]; then
                getsebool -a | grep -i --color=never "$filter" || warn "No boolean matches '$filter'."
            else
                getsebool -a
            fi
            ;;
        get)
            require_cmd getsebool
            local name="${1:?Usage: $PROG bool get <name>}"
            getsebool "$name"
            ;;
        set)
            require_cmd setsebool
            local name="${1:?Usage: $PROG bool set <name> <on|off> [--persistent]}"
            local val="${2:?Specify on or off}"
            local persistent=""
            [[ "${3:-}" == "--persistent" || "${3:-}" == "-p" ]] && persistent="-P"
            [[ "$val" =~ ^(on|off|1|0|true|false)$ ]] || die "Value must be on/off."
            need_root "bool set $name $val ${persistent}"
            setsebool $persistent "$name" "$val" \
                && ok "Boolean '$name' set to '$val'${persistent:+ (persistent)}."
            ;;
        *)
            die "Usage: $PROG bool <list [filter]|get <name>|set <name> <on|off> [--persistent]>"
            ;;
    esac
}

#==============================================================================
# fcontext
#==============================================================================
cmd_fcontext() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        add)
            require_cmd semanage
            local type="${1:?Usage: $PROG fcontext add <selinux_type> <path-regex>}"
            local path="${2:?Specify a path or path regex}"
            need_root "fcontext add $type $path"
            semanage fcontext -a -t "$type" "$path" \
                && ok "Rule added: $path -> $type"
            info "Apply it now with: $PROG fcontext restore '$path'"
            ;;
        restore)
            require_cmd restorecon
            local path="${1:?Usage: $PROG fcontext restore <path>}"
            need_root "fcontext restore $path"
            restorecon -Rv "$path"
            ;;
        check)
            local path="${1:?Usage: $PROG fcontext check <path>}"
            if have matchpathcon; then
                info "Expected vs actual context:"
                matchpathcon -V "$path" 2>/dev/null || matchpathcon "$path"
            fi
            ls -dZ "$path" 2>/dev/null
            ;;
        *)
            die "Usage: $PROG fcontext <add <type> <path>|restore <path>|check <path>>"
            ;;
    esac
}

#==============================================================================
# port
#==============================================================================
cmd_port() {
    local sub="${1:-}"; shift || true
    require_cmd semanage
    case "$sub" in
        list)
            local filter="${1:-}"
            if [[ -n "$filter" ]]; then
                semanage port -l | grep -i --color=never "$filter" || warn "No match for '$filter'."
            else
                semanage port -l
            fi
            ;;
        add)
            local type="${1:?Usage: $PROG port add <type> <tcp|udp> <port>}"
            local proto="${2:?Specify tcp or udp}"
            local port="${3:?Specify a port number}"
            [[ "$proto" =~ ^(tcp|udp)$ ]] || die "Protocol must be tcp or udp."
            need_root "port add $type $proto $port"
            semanage port -a -t "$type" -p "$proto" "$port" \
                && ok "Labeled $proto/$port as $type" \
                || { warn "Add failed — port may already be defined; trying modify..."; \
                     semanage port -m -t "$type" -p "$proto" "$port" \
                       && ok "Modified existing rule: $proto/$port -> $type"; }
            ;;
        *)
            die "Usage: $PROG port <list [filter]|add <type> <tcp|udp> <port>>"
            ;;
    esac
}

#==============================================================================
# module
#==============================================================================
cmd_module() {
    local sub="${1:-}"; shift || true
    require_cmd semodule
    case "$sub" in
        list)
            local filter="${1:-}"
            if [[ -n "$filter" ]]; then
                semodule -l | grep -i --color=never "$filter" || warn "No module matches '$filter'."
            else
                semodule -l
            fi
            ;;
        install)
            local pp="${1:?Usage: $PROG module install <file.pp>}"
            [[ -f "$pp" ]] || die "File not found: $pp"
            [[ "$pp" == *.pp ]] || warn "Expected a compiled .pp module."
            need_root "module install $pp"
            warn "Installing custom policy: $pp"
            confirm "Proceed?" || { info "Aborted."; return 0; }
            semodule -i "$pp" && ok "Module installed."
            ;;
        remove)
            local name="${1:?Usage: $PROG module remove <name>}"
            need_root "module remove $name"
            confirm "Remove policy module '$name'?" || { info "Aborted."; return 0; }
            semodule -r "$name" && ok "Module '$name' removed."
            ;;
        *)
            die "Usage: $PROG module <list [filter]|install <file.pp>|remove <name>>"
            ;;
    esac
}

#==============================================================================
# relabel
#==============================================================================
cmd_relabel() {
    local path="${1:?Usage: $PROG relabel <path>}"
    require_cmd restorecon
    need_root "relabel $path"
    if [[ "$path" == "/" ]]; then
        warn "Relabeling the entire filesystem is heavy and best done via reboot."
        info "Recommended: 'fixfiles -F onboot && reboot' for a full relabel."
        confirm "Run restorecon -R / now anyway?" || { info "Aborted."; return 0; }
    fi
    restorecon -Rv "$path"
}

#==============================================================================
# healthcheck (read-only)
#==============================================================================
cmd_healthcheck() {
    hdr "SELinux Health Check"
    local issues=0

    if ! have getenforce; then
        err "SELinux tools missing."; return 1
    fi

    local mode; mode="$(getenforce)"
    [[ "$mode" == "Enforcing" ]] && ok "Mode is Enforcing." \
        || { warn "Mode is $mode (not Enforcing)."; ((issues++)); }

    # config vs runtime drift
    if [[ -f "$SELINUX_CONFIG" ]]; then
        local boot; boot="$(grep -E '^SELINUX=' "$SELINUX_CONFIG" | head -1 | cut -d= -f2)"
        [[ "${boot^}" == "$mode" ]] && ok "Boot config matches runtime ($boot)." \
            || { warn "Boot config ($boot) differs from runtime ($mode)."; ((issues++)); }
    fi

    # denials in last 24h
    if have ausearch; then
        local n; n="$(ausearch -m avc,user_avc -ts today 2>/dev/null | grep -c 'AVC' || true)"
        [[ "$n" -eq 0 ]] && ok "No AVC denials today." \
            || { warn "$n AVC denial line(s) today. Run: $PROG denials --since today"; ((issues++)); }
    else
        warn "ausearch unavailable — cannot check audit log."
    fi

    # mislabeled files in key dirs (sampled)
    if have restorecon; then
        local bad; bad="$(restorecon -Rn /etc /var/www 2>/dev/null | wc -l)"
        [[ "$bad" -eq 0 ]] && ok "No mislabeled files in /etc, /var/www (dry run)." \
            || { warn "$bad file(s) would be relabeled in /etc,/var/www."; ((issues++)); }
    fi

    # custom modules
    if have semodule; then
        local cust; cust="$(semodule -l 2>/dev/null | wc -l)"
        info "Policy modules loaded: $cust"
    fi

    echo
    [[ $issues -eq 0 ]] && ok "Health check passed with no issues." \
        || warn "Health check finished with $issues issue(s) to review."
    return 0
}

#==============================================================================
# troubleshoot <service>
#==============================================================================
cmd_troubleshoot() {
    local svc="${1:?Usage: $PROG troubleshoot <service-or-keyword>}"
    hdr "Troubleshooting SELinux for: $svc"

    info "1) Denials mentioning '$svc':"
    if have ausearch; then
        ausearch -m avc,user_avc -ts recent 2>/dev/null \
            | grep -i --color=never "$svc" | head -20 \
            || info "   (none in the recent window)"
    fi

    echo
    info "2) Relevant booleans:"
    have getsebool && { getsebool -a | grep -i --color=never "$svc" || info "   (none)"; }

    echo
    info "3) Relevant port labels:"
    have semanage && { semanage port -l 2>/dev/null | grep -i --color=never "$svc" || info "   (none)"; }

    echo
    info "Next steps:"
    info "  • Explain blocks : $PROG explain"
    info "  • Draft a fix    : $PROG suggest --name ${svc}_local"
    info "  • Toggle boolean : $PROG bool set <name> on --persistent"
}

#==============================================================================
# deps
#==============================================================================
cmd_deps() {
    hdr "Dependency Check"
    local tools=(getenforce setenforce sestatus getsebool setsebool \
                 semanage restorecon matchpathcon ausearch audit2allow \
                 audit2why semodule fixfiles)
    local missing=()
    for t in "${tools[@]}"; do
        if have "$t"; then
            ok "$t"
        else
            err "$t (missing)"; missing+=("$t")
        fi
    done
    echo
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "All tools present."
    else
        warn "Missing ${#missing[@]} tool(s)."
        info "RHEL/Fedora/Rocky/Alma:"
        info "  sudo dnf install -y policycoreutils policycoreutils-python-utils \\"
        info "       setools-console audit setroubleshoot-server"
        info "Debian/Ubuntu:"
        info "  sudo apt install -y policycoreutils selinux-utils selinux-basics auditd"
    fi
}

#==============================================================================
# usage / dispatch
#==============================================================================
usage() {
    cat <<EOF
${C_BLD}$PROG${C_RST} v$VERSION — SELinux management & diagnostic toolkit

${C_BLD}USAGE${C_RST}
  $PROG <command> [options]

${C_BLD}COMMANDS${C_RST}
  status                          Comprehensive status report
  mode <state> [--persistent]     Set mode: enforcing|permissive|disabled
  denials [--since T] [--raw]      Analyze AVC denials (default window: recent)
  explain                         Explain recent denials (audit2why)
  suggest [--name NAME]           Draft a policy module from denials (no install)
  bool list [filter]              List booleans (optionally filtered)
  bool get <name>                 Show one boolean
  bool set <name> <on|off> [-p]   Set a boolean (-p / --persistent to survive reboot)
  fcontext add <type> <path>      Add a file-context rule
  fcontext restore <path>         Apply contexts (restorecon -Rv)
  fcontext check <path>           Compare expected vs actual context
  port list [filter]              List port labels
  port add <type> <tcp|udp> <p>   Label a network port
  module list [filter]            List loaded policy modules
  module install <file.pp>        Install a compiled policy module
  module remove <name>            Remove a policy module
  relabel <path>                  Restore contexts recursively
  healthcheck                     Read-only diagnostic summary
  troubleshoot <service>          Guided troubleshooting for a service
  deps                            Check tool dependencies
  help                            Show this help

${C_BLD}EXAMPLES${C_RST}
  sudo $PROG mode permissive --persistent
  $PROG denials --since today
  sudo $PROG bool set httpd_can_network_connect on --persistent
  sudo $PROG port add http_port_t tcp 8088
  $PROG troubleshoot httpd

Set NO_COLOR=1 to disable colored output.
EOF
}

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        status)        cmd_status "$@" ;;
        mode)          cmd_mode "$@" ;;
        denials)       cmd_denials "$@" ;;
        explain)       cmd_explain "$@" ;;
        suggest)       cmd_suggest "$@" ;;
        bool)          cmd_bool "$@" ;;
        fcontext)      cmd_fcontext "$@" ;;
        port)          cmd_port "$@" ;;
        module)        cmd_module "$@" ;;
        relabel)       cmd_relabel "$@" ;;
        healthcheck)   cmd_healthcheck "$@" ;;
        troubleshoot)  cmd_troubleshoot "$@" ;;
        deps)          cmd_deps "$@" ;;
        help|-h|--help) usage ;;
        version|-v|--version) echo "$PROG v$VERSION" ;;
        *) err "Unknown command: $cmd"; echo; usage; exit 1 ;;
    esac
}

main "$@"
