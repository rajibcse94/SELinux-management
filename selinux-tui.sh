#!/usr/bin/env bash
#===============================================================================
# selinux-tui.sh — menu-driven (TUI) front-end for the SELinux toolkit
#
# A "GUI in the terminal" using whiptail/dialog. Works over SSH, no desktop
# needed. It drives selinux-toolkit.sh and selinux-config.sh under the hood.
#
# Requires whiptail (package: newt) or dialog. Install one:
#   RHEL/Fedora:   sudo dnf install -y newt        # provides whiptail
#   Debian/Ubuntu: sudo apt install -y whiptail
#===============================================================================

set -uo pipefail

PROG="${0##*/}"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#--- locate the backend scripts (local dir first, then PATH) -------------------
find_backend() {
    local local_sh="$SCRIPT_DIR/$1" installed="$2"
    if [[ -x "$local_sh" ]]; then echo "$local_sh"
    elif command -v "$installed" >/dev/null 2>&1; then echo "$installed"
    elif [[ -f "$local_sh" ]]; then echo "bash $local_sh"
    else return 1; fi
}
TOOLKIT="$(find_backend selinux-toolkit.sh selinux-toolkit || true)"
CONFIG="$(find_backend selinux-config.sh selinux-config || true)"

#--- pick a dialog program -----------------------------------------------------
if command -v whiptail >/dev/null 2>&1; then
    DIALOG=whiptail
elif command -v dialog >/dev/null 2>&1; then
    DIALOG=dialog
else
    echo "Error: neither 'whiptail' nor 'dialog' is installed." >&2
    echo "Install one:" >&2
    echo "  RHEL/Fedora:   sudo dnf install -y newt" >&2
    echo "  Debian/Ubuntu: sudo apt install -y whiptail" >&2
    exit 1
fi

BACKTITLE="SELinux Management TUI v$VERSION"
HEIGHT=22; WIDTH=78; MENU_H=12

#--- dialog helpers ------------------------------------------------------------
msg()  { "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 12 "$WIDTH"; }
yesno(){ "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --yesno "$2" 10 "$WIDTH"; }

inputbox() {
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" \
        --inputbox "$2" 10 "$WIDTH" "${3:-}" 3>&1 1>&2 2>&3
}

menu() {
    local title="$1" prompt="$2"; shift 2
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" \
        --cancel-button "Back" \
        --menu "$prompt" "$HEIGHT" "$WIDTH" "$MENU_H" "$@" 3>&1 1>&2 2>&3
}

# Global dry-run toggle for the TUI session (flipped from the main menu).
TUI_DRYRUN=0

# Run a command (no colors) and show its output in a scrollable textbox.
# The TUI handles its own confirmations, so we pass ASSUME_YES=1 to the backend.
run_show() {
    local title="$1"; shift
    local out; out="$(mktemp)"
    NO_COLOR=1 ASSUME_YES=1 DRYRUN="$TUI_DRYRUN" bash -c "$*" >"$out" 2>&1
    [[ -s "$out" ]] || echo "(no output)" >"$out"
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" \
        --scrolltext --textbox "$out" "$HEIGHT" "$WIDTH"
    rm -f "$out"
}

need_toolkit() { [[ -n "$TOOLKIT" ]] || { msg "Missing" "selinux-toolkit.sh not found next to this script or in PATH."; return 1; }; }
need_config()  { [[ -n "$CONFIG"  ]] || { msg "Missing" "selinux-config.sh not found next to this script or in PATH.";  return 1; }; }

#==============================================================================
# Sub-menus
#==============================================================================
menu_status() {
    need_toolkit || return
    while :; do
        local c; c="$(menu "Status & Health" "Choose a report:" \
            status     "Comprehensive status report" \
            health     "Read-only health check" \
            deps       "Check tool dependencies")" || return
        case "$c" in
            status) run_show "Status"       "$TOOLKIT status" ;;
            health) run_show "Health Check" "$TOOLKIT healthcheck" ;;
            deps)   run_show "Dependencies" "$TOOLKIT deps" ;;
        esac
    done
}

menu_mode() {
    need_toolkit || return
    local state
    state="$("$DIALOG" --backtitle "$BACKTITLE" --title "Set Mode" \
        --radiolist "Select SELinux mode:" 12 "$WIDTH" 3 \
        enforcing  "Policy enforced (recommended)" ON \
        permissive "Logged but not enforced"       OFF \
        disabled   "Off (discouraged; needs reboot)" OFF \
        3>&1 1>&2 2>&3)" || return
    [[ -n "$state" ]] || return
    if [[ "$state" == "disabled" ]]; then
        yesno "Disable SELinux?" "Disabling SELinux is discouraged and needs a reboot.\nA safer choice is 'permissive'.\n\nReally set it to disabled?" \
            || return
    fi
    local opt=""
    if yesno "Persist?" "Make '$state' survive a reboot (write to config)?"; then
        opt="--persistent"
    fi
    run_show "Set Mode: $state" "$TOOLKIT mode $state $opt"
}

menu_bool() {
    need_toolkit || return
    while :; do
        local c; c="$(menu "Booleans" "Manage SELinux booleans:" \
            list   "List all booleans" \
            search "Search booleans by keyword" \
            set    "Turn a boolean on/off")" || return
        case "$c" in
            list)   run_show "All Booleans" "$TOOLKIT bool list" ;;
            search)
                local kw; kw="$(inputbox "Search Booleans" "Keyword (e.g. httpd):")" || continue
                [[ -n "$kw" ]] && run_show "Booleans: $kw" "$TOOLKIT bool list '$kw'" ;;
            set)
                local name; name="$(inputbox "Set Boolean" "Boolean name:")" || continue
                [[ -n "$name" ]] || continue
                local val
                val="$("$DIALOG" --backtitle "$BACKTITLE" --title "Value" \
                    --radiolist "Set '$name' to:" 10 "$WIDTH" 2 \
                    on "Enable" ON  off "Disable" OFF 3>&1 1>&2 2>&3)" || continue
                local p=""; yesno "Persist?" "Survive reboot?" && p="--persistent"
                run_show "bool set $name $val" "$TOOLKIT bool set '$name' '$val' $p" ;;
        esac
    done
}

menu_fcontext() {
    need_toolkit || return
    while :; do
        local c; c="$(menu "File Contexts" "Manage file labeling:" \
            check   "Check a path's context" \
            restore "Restore contexts on a path" \
            add     "Add a file-context rule" \
            relabel "Relabel a path recursively")" || return
        case "$c" in
            check)
                local p; p="$(inputbox "Check Context" "Path:")" || continue
                [[ -n "$p" ]] && run_show "Context: $p" "$TOOLKIT fcontext check '$p'" ;;
            restore)
                local p; p="$(inputbox "Restore Context" "Path:")" || continue
                [[ -n "$p" ]] && run_show "restorecon $p" "$TOOLKIT fcontext restore '$p'" ;;
            add)
                local t; t="$(inputbox "Add fcontext" "SELinux type (e.g. httpd_sys_content_t):")" || continue
                [[ -n "$t" ]] || continue
                local p; p="$(inputbox "Add fcontext" "Path or path regex:")" || continue
                [[ -n "$p" ]] && run_show "fcontext add" "$TOOLKIT fcontext add '$t' '$p'" ;;
            relabel)
                local p; p="$(inputbox "Relabel" "Path to relabel recursively:")" || continue
                [[ -n "$p" ]] || continue
                yesno "Relabel" "Run restorecon -R on '$p'?\nThis can take a while on large trees." \
                    && run_show "relabel $p" "$TOOLKIT relabel '$p'" ;;
        esac
    done
}

menu_port() {
    need_toolkit || return
    while :; do
        local c; c="$(menu "Ports" "Manage network port labeling:" \
            list "List port labels" \
            add  "Label a network port")" || return
        case "$c" in
            list)
                local kw; kw="$(inputbox "List Ports" "Filter (blank = all):")" || continue
                run_show "Ports" "$TOOLKIT port list '$kw'" ;;
            add)
                local t; t="$(inputbox "Add Port" "SELinux type (e.g. http_port_t):")" || continue
                [[ -n "$t" ]] || continue
                local proto; proto="$("$DIALOG" --backtitle "$BACKTITLE" --title "Protocol" \
                    --radiolist "Protocol:" 10 "$WIDTH" 2 tcp "" ON udp "" OFF 3>&1 1>&2 2>&3)" || continue
                local port; port="$(inputbox "Add Port" "Port number:")" || continue
                [[ -n "$port" ]] && run_show "port add" "$TOOLKIT port add '$t' '$proto' '$port'" ;;
        esac
    done
}

menu_modules() {
    need_toolkit || return
    while :; do
        local c; c="$(menu "Policy Modules" "Manage modules:" \
            list    "List loaded modules" \
            install "Install a .pp module" \
            remove  "Remove a module")" || return
        case "$c" in
            list)
                local kw; kw="$(inputbox "List Modules" "Filter (blank = all):")" || continue
                run_show "Modules" "$TOOLKIT module list '$kw'" ;;
            install)
                local f; f="$(inputbox "Install Module" "Path to .pp file:")" || continue
                [[ -n "$f" ]] || continue
                yesno "Install Module" "Install policy module from:\n$f ?" \
                    && run_show "module install" "$TOOLKIT module install '$f'" ;;
            remove)
                local n; n="$(inputbox "Remove Module" "Module name:")" || continue
                [[ -n "$n" ]] || continue
                yesno "Remove Module" "Remove policy module '$n'?" \
                    && run_show "module remove" "$TOOLKIT module remove '$n'" ;;
        esac
    done
}

menu_denials() {
    need_toolkit || return
    while :; do
        local c; c="$(menu "Denials & Troubleshooting" "Analyze AVC denials:" \
            recent      "Denials in the recent window" \
            today       "Denials today" \
            explain     "Explain recent denials (audit2why)" \
            suggest     "Draft a policy fix (audit2allow)" \
            troubleshoot "Guided help for a service")" || return
        case "$c" in
            recent)  run_show "Recent Denials" "$TOOLKIT denials" ;;
            today)   run_show "Denials Today"  "$TOOLKIT denials --since today" ;;
            explain) run_show "Why Blocked"    "$TOOLKIT explain" ;;
            suggest)
                local n; n="$(inputbox "Suggest Policy" "Module name:" "local_avc")" || continue
                run_show "Suggested Policy" "$TOOLKIT suggest --name '$n'" ;;
            troubleshoot)
                local s; s="$(inputbox "Troubleshoot" "Service/keyword (e.g. httpd):")" || continue
                [[ -n "$s" ]] && run_show "Troubleshoot: $s" "$TOOLKIT troubleshoot '$s'" ;;
        esac
    done
}

menu_config() {
    need_config || return
    while :; do
        local c; c="$(menu "Config & Change Audit" "Inspect / change config:" \
            customizations "What changed from defaults" \
            where          "Where config lives" \
            snapshot       "Save a baseline snapshot" \
            diff           "Compare baseline to now" \
            listsnaps      "List saved snapshots" \
            export         "Export customizations to a file" \
            import         "Import customizations from a file" \
            editconfig     "Edit the config file in an editor" \
            backup         "Full backup" \
            restore        "Restore config from a backup file" \
            log            "View the change audit log")" || return
        case "$c" in
            customizations) run_show "Customizations" "$CONFIG customizations" ;;
            where)          run_show "Where Config Lives" "$CONFIG where" ;;
            snapshot)
                local n; n="$(inputbox "Snapshot" "Name (blank = auto):")" || continue
                run_show "Snapshot" "$CONFIG snapshot $n" ;;
            diff)
                local n; n="$(inputbox "Diff" "Baseline name (blank = latest):")" || continue
                run_show "Diff vs Current" "$CONFIG diff $n" ;;
            listsnaps)      run_show "Snapshots" "$CONFIG list-snapshots" ;;
            export)
                local f; f="$(inputbox "Export" "Output file:" "selinux-custom.conf")" || continue
                run_show "Export" "$CONFIG export '$f'" ;;
            import)
                local f; f="$(inputbox "Import" "File to import:")" || continue
                [[ -n "$f" ]] || continue
                yesno "Import" "Apply customizations from:\n$f ?" \
                    && run_show "Import" "$CONFIG import '$f'" ;;
            editconfig)
                msg "Edit Config" "An editor (\$EDITOR) will open the config file with a backup. Close it to return."
                clear
                NO_COLOR=1 ASSUME_YES=1 "$CONFIG" edit-config
                read -r -p "Press Enter to return to the menu... " _ ;;
            backup)         run_show "Backup" "$CONFIG backup" ;;
            restore)
                local f; f="$(inputbox "Restore Config" "Backup file to restore:")" || continue
                [[ -n "$f" ]] || continue
                yesno "Restore Config" "Overwrite the SELinux config with:\n$f ?" \
                    && run_show "Restore Config" "$CONFIG restore-config '$f'" ;;
            log)            run_show "Audit Log" "$CONFIG log" ;;
        esac
    done
}

#==============================================================================
# Main menu
#==============================================================================
main_menu() {
    while :; do
        local c dr_label
        if [[ "$TUI_DRYRUN" == "1" ]]; then dr_label="ON  (previews only)"; else dr_label="OFF (changes apply)"; fi
        c="$(menu "Main Menu" "SELinux Management — choose an area:" \
            1 "Status & Health" \
            2 "Mode (enforcing/permissive/disabled)" \
            3 "Booleans" \
            4 "File Contexts" \
            5 "Ports" \
            6 "Policy Modules" \
            7 "Denials & Troubleshooting" \
            8 "Config & Change Audit" \
            9 "View change audit log" \
            D "Dry-run: $dr_label" \
            Q "Quit")" || break
        case "$c" in
            1) menu_status ;;
            2) menu_mode ;;
            3) menu_bool ;;
            4) menu_fcontext ;;
            5) menu_port ;;
            6) menu_modules ;;
            7) menu_denials ;;
            8) menu_config ;;
            9) need_toolkit && run_show "Change Audit Log" "$TOOLKIT log" ;;
            D) if [[ "$TUI_DRYRUN" == "1" ]]; then TUI_DRYRUN=0; else TUI_DRYRUN=1; fi ;;
            Q) break ;;
        esac
    done
    clear
    echo "Goodbye."
}

#--- startup checks ------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    yesno "Not root" "Most actions need root. Re-run with 'sudo $PROG' for full functionality.\n\nContinue in read-only mode anyway?" \
        || { clear; echo "Re-run with: sudo $PROG"; exit 0; }
fi

main_menu
