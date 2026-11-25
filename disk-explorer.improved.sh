#!/usr/bin/env bash
# GNU/Linux disk explorer. Analysis first; maintenance is explicitly opt-in.
set -uo pipefail

readonly LOG_DIR=/var/log/disk-explorer-improved
readonly MASTER_LOG="$LOG_DIR/disk-explorer.log"
TITLE='Disk Explorer'
SCAN_ROOT=/
TARGET_DIR=/
MAINTENANCE=0
WORK_DIR=''
H=20 W=76 MENU_ROWS=10
SELECTED_ACTIONS=()
LOG_FILES=()
NCDU_ARGS=()

usage() {
    cat <<'HELP'
Usage: sudo bash disk-explorer.improved.sh [OPTIONS]
  --root DIRECTORY       Initial analysis path (default: /).
  --enable-maintenance   Unlock ncdu installation and two cleanup actions:
                         APT download-cache clean, archived-journal vacuum.
  --help                 Print help; no root, terminal or writes required.
Requirements: Bash 4.4+, whiptail, GNU findutils/coreutils, tput and flock.
Target environment: Debian/Ubuntu with an interactive terminal >= 72 x 20.
Analysis mode writes private diagnostic logs but changes no scanned data.
ncdu launches with deletion and shell disabled (-r -r); newer versions also
use --ignore-config when that option is advertised by ncdu --help.
Bulk temp/log/crash deletion, syslog truncation, package purge and Snap removal
are deliberately excluded. Autoremove is a full, unfiltered simulation only.
Maintenance is system-wide; --root limits analysis, not cleanup scope.
Cleanup is irreversible. Journal vacuum affects archived journals only.
Logs: /var/log/disk-explorer-improved (directory 0700, files 0600).
Scans may be partial; read exit status and warnings, not just the first rows.
Large scans need working space for temporary records and sorting.
Exit: 0 normal menu exit, 1 fatal setup error, 130/143 interruption/termination.
Per-task exit codes are recorded in the logs; nonzero tasks return to the menu.
HELP
}

fail() { printf '[FAIL] %s\n' "$1" >&2; return 1; }
message() { whiptail --title "$TITLE" --msgbox "$1" 12 "$W"; }

calc_size() {
    local rows cols
    rows=$(tput lines 2>/dev/null) || return 1
    cols=$(tput cols 2>/dev/null) || return 1
    [[ $rows =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] || return 1
    if (( rows < 20 || cols < 72 )); then
        printf 'Resize the terminal to at least 72 columns x 20 rows.\n' >&2
        return 1
    fi
    H=$((rows - 2)); W=$((cols - 4)); MENU_ROWS=$((H - 8))
    (( H > 32 )) && H=32
    (( W > 120 )) && W=120
    (( MENU_ROWS > 10 )) && MENU_ROWS=10
    return 0
}

canonical_directory() {
    local result
    [[ $1 != *[[:cntrl:]]* ]] || return 1
    result=$(realpath -e -- "$1") || return 1
    [[ -d $result ]] || return 1
    printf '%s\n' "$result"
}

disk_status() {
    df -h -- "$TARGET_DIR"
}

show_scan_errors() {
    local line count=0
    printf '\nWARNING: partial scan; not every entry could be read.\n'
    while IFS= read -r line; do
        printf '  %q\n' "$line"
        count=$((count + 1))
        (( count >= 10 )) && break
    done <"$WORK_DIR/errors.tmp"
    printf 'At most ten scan-error lines are shown.\n'
}

emit_top_records() {
    local limit=$1 record bytes path formatted count=0
    printf '%12s  %s\n' 'SIZE' 'PATH (shell-escaped for display)'
    while IFS= read -r -d '' record; do
        bytes=${record%%$'\t'*}
        path=${record#*$'\t'}
        [[ $bytes =~ ^[0-9]+$ && $record == *$'\t'* ]] || return 1
        formatted=$(numfmt --to=iec -- "$bytes") || return 1
        printf '%12s  %q\n' "$formatted" "$path"
        count=$((count + 1))
        (( count >= limit )) && break
    done <"$WORK_DIR/sorted.tmp"
    (( count )) || printf 'No matching entries.\n'
    return 0
}

scan_files() {
    local threshold=$1 rc=0
    local conditions=(-xdev -type f)
    [[ $threshold == large ]] && conditions+=(-size +50M)
    # NUL records preserve tabs/newlines in paths; no pipeline stops sort early.
    find "$TARGET_DIR" "${conditions[@]}" -printf '%s\t%p\0' \
        >"$WORK_DIR/data.tmp" 2>"$WORK_DIR/errors.tmp" || rc=$?
    sort -z -nr -T "$WORK_DIR" -- "$WORK_DIR/data.tmp" >"$WORK_DIR/sorted.tmp" || return 1
    printf 'File ranking uses apparent byte size; hard links are separate paths.\n'
    emit_top_records 20 || return 1
    if (( rc )); then show_scan_errors; return 3; fi
}
cmd_large_files() { scan_files large; }
cmd_top_files() { scan_files all; }

cmd_directories() {
    local rc=0
    du -x -B1 --max-depth=2 --null -- "$TARGET_DIR" \
        >"$WORK_DIR/data.tmp" 2>"$WORK_DIR/errors.tmp" || rc=$?
    sort -z -nr -T "$WORK_DIR" -- "$WORK_DIR/data.tmp" >"$WORK_DIR/sorted.tmp" || return 1
    printf 'Allocated directory sizes; parent/child totals overlap and are not additive.\n'
    emit_top_records 20 || return 1
    if (( rc )); then show_scan_errors; return 3; fi
}

run_task() {
    local title=$1 func=$2 logfile rc
    logfile=$(mktemp "$LOG_DIR/run_$(date +%Y%m%d_%H%M%S).XXXXXXXX.log") || return 1
    calc_size || return 1
    whiptail --title "$TITLE" --infobox "Working: $title\n\nPlease wait; scans may take time." 9 "$W" || true
    {
        printf '=== %s ===\nDate: %s\nAnalysis root: %q\n' "$title" "$(date -Is)" "$TARGET_DIR"
        disk_status
        printf '\n'
    } >"$logfile" || return 1
    if "$func" >>"$logfile" 2>&1; then rc=0; else rc=$?; fi
    printf '\nTask exit: %s\nFinished: %s\n' "$rc" "$(date -Is)" >>"$logfile" || return 1
    cat -- "$logfile" >>"$MASTER_LOG" || return 1
    printf '\n' >>"$MASTER_LOG" || return 1
    calc_size || return 1
    if (( rc == 0 )); then title="Completed: $title"; else title="Check result (exit $rc): $title"; fi
    whiptail --title "$title" --scrolltext --textbox "$logfile" "$H" "$W" || true
    return "$rc"
}

cmd_autoremove_preview() {
    command -v apt-get >/dev/null 2>&1 || return 1
    printf 'SIMULATION ONLY: full apt-get output, no packages changed.\n\n'
    apt-get -s autoremove --purge
}

cmd_install_ncdu() {
    command -v apt-get >/dev/null 2>&1 || return 1
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y ncdu || return 1
    command -v ncdu >/dev/null 2>&1
}

install_ncdu() {
    if command -v ncdu >/dev/null 2>&1; then
        run_task 'ncdu version' cmd_ncdu_version
        return
    fi
    (( MAINTENANCE )) || { message 'Installation is locked. Restart with --enable-maintenance to allow package changes.'; return 0; }
    whiptail --title "$TITLE" --defaultno --yesno \
        'Update APT indexes and install ncdu system-wide? Package scripts may run. Continue?' 11 "$W" || return 0
    run_task 'Install ncdu' cmd_install_ncdu
}
cmd_ncdu_version() { ncdu --version; }

configure_ncdu_args() {
    local help
    NCDU_ARGS=(-r -r -x)
    help=$(ncdu --help) || return 1
    if [[ $help == *--ignore-config* ]]; then NCDU_ARGS=(--ignore-config "${NCDU_ARGS[@]}"); fi
}

run_ncdu() {
    local rc
    if ! command -v ncdu >/dev/null 2>&1; then
        message 'ncdu is not installed. Use the installation entry if maintenance is enabled.'
        return 0
    fi
    printf '\nStarting read-only ncdu at %s on %q\n' "$(date -Is)" "$TARGET_DIR" >>"$MASTER_LOG" || return 1
    # -r twice disables both deletion and the built-in shell in ncdu 1.x.
    configure_ncdu_args || return 1
    if ncdu "${NCDU_ARGS[@]}" -- "$TARGET_DIR"; then rc=0; else rc=$?; fi
    printf 'ncdu exit: %s at %s\n' "$rc" "$(date -Is)" >>"$MASTER_LOG" || return 1
    return "$rc"
}

custom_directory() {
    local input resolved
    input=$(whiptail --title "$TITLE" --inputbox 'Directory to analyze (depth 2):' 10 "$W" "$TARGET_DIR" 3>&1 1>&2 2>&3) || return 0
    resolved=$(canonical_directory "$input") || { message 'Cannot resolve an existing directory.'; return 0; }
    TARGET_DIR=$resolved
    run_task 'Directory usage, depth 2' cmd_directories
}

list_log_files() {
    local record
    LOG_FILES=()
    find "$LOG_DIR" -maxdepth 1 -type f -name 'run_*.log' -printf '%T@\t%p\0' \
        >"$WORK_DIR/logs.tmp" || return 1
    sort -z -nr -T "$WORK_DIR" -- "$WORK_DIR/logs.tmp" >"$WORK_DIR/sorted.tmp" || return 1
    while IFS= read -r -d '' record; do
        LOG_FILES+=("${record#*$'\t'}")
        (( ${#LOG_FILES[@]} >= 30 )) && break
    done <"$WORK_DIR/sorted.tmp"
    return 0
}

view_logs() {
    local choice file i
    local items=()
    list_log_files || return 1
    for ((i=0; i<${#LOG_FILES[@]}; i++)); do
        file=${LOG_FILES[i]}
        items+=("$((i + 1))" "${file##*/}")
    done
    items+=(M 'Master log' B 'Back')
    choice=$(whiptail --title 'Private task logs' --menu 'Choose a log. Deletion is not offered.' \
        "$H" "$W" "$MENU_ROWS" "${items[@]}" 3>&1 1>&2 2>&3) || return 0
    case "$choice" in
        B) return 0 ;;
        M) file=$MASTER_LOG ;;
        *)
            [[ $choice =~ ^[1-9][0-9]?$ ]] || return 1
            (( choice <= ${#LOG_FILES[@]} )) || return 1
            file=${LOG_FILES[choice-1]} ;;
    esac
    [[ -f $file && ! -L $file ]] || return 1
    whiptail --title 'Task log' --scrolltext --textbox "$file" "$H" "$W" || true
}

validate_actions() {
    local action
    (( ${#SELECTED_ACTIONS[@]} )) || return 1
    for action in "${SELECTED_ACTIONS[@]}"; do
        case "$action" in apt_clean|journal) ;; *) return 1 ;; esac
    done
}

perform_cleanup() {
    local action rc
    (( MAINTENANCE )) || { printf 'Maintenance is locked.\n'; return 1; }
    validate_actions || { printf 'Rejected an unknown or empty cleanup selection.\n'; return 1; }
    printf 'SYSTEM-WIDE maintenance. Irreversible; no rollback is available.\n'
    for action in "${SELECTED_ACTIONS[@]}"; do
        printf '\nAction: %s\n' "$action"
        case "$action" in
            apt_clean) command -v apt-get >/dev/null 2>&1 || return 1
                if apt-get clean; then rc=0; else rc=$?; fi ;;
            journal) command -v journalctl >/dev/null 2>&1 || return 1
                if journalctl --vacuum-size=100M; then rc=0; else rc=$?; fi ;;
        esac
        printf 'Action exit: %s\n' "$rc"
        if (( rc )); then printf 'Stopped after failure; earlier completed actions are not undone.\n'; return "$rc"; fi
    done
    printf '\nSelected maintenance commands completed. No recovered-byte estimate is promised.\n'
}

cleanup_guided() {
    local selected
    (( MAINTENANCE )) || { message 'Cleanup is locked. Restart with --enable-maintenance after reviewing the risks.'; return 0; }
    selected=$(whiptail --title 'System-wide maintenance' --separate-output --checklist \
        'All choices start OFF. Journal vacuum removes archived history; active journals remain.' \
        "$H" "$W" 3 apt_clean 'Clear downloaded APT package cache' OFF \
        journal 'Vacuum archived systemd journals toward 100M' OFF 3>&1 1>&2 2>&3) || return 0
    [[ -n $selected ]] || return 0
    mapfile -t SELECTED_ACTIONS <<<"$selected"
    validate_actions || return 1
    whiptail --title 'Confirm irreversible maintenance' --defaultno --yesno \
        "SYSTEM-WIDE: $selected\n\nThis is not limited by --root. No rollback is provided. Continue?" 13 "$W" || return 0
    run_task 'System-wide maintenance' perform_cleanup
}

cleanup() {
    if [[ -n $WORK_DIR ]]; then
        rm -f -- "$WORK_DIR/data.tmp" "$WORK_DIR/errors.tmp" "$WORK_DIR/sorted.tmp" "$WORK_DIR/logs.tmp"
        rmdir -- "$WORK_DIR" || true
    fi
}

setup_logs() {
    [[ ! -L $LOG_DIR ]] || { fail 'Log directory must not be a symlink.'; return 1; }
    if [[ -e $LOG_DIR ]]; then
        [[ -d $LOG_DIR && $(stat -c '%u:%a' "$LOG_DIR") == 0:700 ]] || { fail 'Log directory must be root-owned mode 0700.'; return 1; }
    else
        install -d -m 700 "$LOG_DIR" || return 1
    fi
    if [[ -e $MASTER_LOG || -L $MASTER_LOG ]]; then
        [[ -f $MASTER_LOG && ! -L $MASTER_LOG && $(stat -c '%u:%a' "$MASTER_LOG") == 0:600 ]] || return 1
    else
        : >"$MASTER_LOG" || return 1
    fi
    exec 9>"$LOG_DIR/session.lock" || return 1
    flock -n 9 || { fail 'Another improved Disk Explorer session is running.'; return 1; }
    WORK_DIR=$(mktemp -d "$LOG_DIR/.session.XXXXXXXX") || return 1
}

main_menu() {
    local choice result=0 mode_label
    while true; do
        calc_size || return 1
        if (( MAINTENANCE )); then mode_label='Maintenance enabled'; else mode_label='Analysis mode; cleanup locked'; fi
        choice=$(whiptail --title "$TITLE" --menu "$mode_label\nAnalysis path: $TARGET_DIR" \
            "$H" "$W" "$MENU_ROWS" \
            1 'Files larger than 50 MiB (top 20)' 2 'Largest files (top 20)' \
            3 'Directory usage (depth 2)' 4 'Analyze /usr (depth 2)' \
            5 'Choose a directory' 6 'Install/check ncdu' 7 'Open read-only ncdu' \
            8 'View private logs' 9 'Guided maintenance' A 'Preview APT autoremove' \
            R 'Reset analysis path' 0 'Exit' 3>&1 1>&2 2>&3) || break
        case "$choice" in
            1) run_task 'Files larger than 50 MiB' cmd_large_files; result=$? ;;
            2) run_task 'Largest files' cmd_top_files; result=$? ;;
            3) run_task 'Directory usage, depth 2' cmd_directories; result=$? ;;
            4) TARGET_DIR=/usr; run_task 'Directory usage: /usr' cmd_directories; result=$? ;;
            5) custom_directory; result=$? ;;
            6) install_ncdu; result=$? ;;
            7) run_ncdu; result=$? ;;
            8) view_logs; result=$? ;;
            9) cleanup_guided; result=$? ;;
            A) run_task 'APT autoremove simulation' cmd_autoremove_preview; result=$? ;;
            R) TARGET_DIR=$SCAN_ROOT; result=0 ;;
            0) break ;;
            *) result=1 ;;
        esac
        if (( result )); then message "Task returned $result. Inspect the result/log; success has not been assumed." || true; fi
    done
    printf 'Logs retained at %s\n' "$LOG_DIR"
    return 0
}

main() {
    local tool
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    umask 077
    while (( $# )); do
        case "$1" in
            --help) usage; return 0 ;;
            --root) (( $# >= 2 )) || { fail 'Missing --root value.'; return 1; }
                SCAN_ROOT=$2; shift 2 ;;
            --enable-maintenance) MAINTENANCE=1; shift ;;
            *) fail 'Unknown argument. Use --help.'; return 1 ;;
        esac
    done
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { fail 'Bash 4.4+ required.'; return 1; }
    [[ $EUID -eq 0 ]] || { fail 'Run explicitly with sudo bash; the script does not self-elevate.'; return 1; }
    [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]] || { fail 'An interactive terminal is required.'; return 1; }
    for tool in whiptail find du sort numfmt df realpath mktemp install stat cat date hostname tput flock rm rmdir; do
        command -v "$tool" >/dev/null 2>&1 || { fail "Missing required command: $tool"; return 1; }
    done
    SCAN_ROOT=$(canonical_directory "$SCAN_ROOT") || { fail 'Analysis root must be an existing directory.'; return 1; }
    TARGET_DIR=$SCAN_ROOT
    TITLE="Disk Explorer - $(hostname)"
    calc_size || return 1
    setup_logs || { fail 'Cannot create or validate private logs/lock.'; return 1; }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    main_menu
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
