#!/usr/bin/env bash
# =============================================================================
#  Disk Explorer - graphical menu (TUI) for disk analysis and cleanup
#  Requires: bash, whiptail (preinstalled on Ubuntu/Debian)
#  Usage:      sudo ./disk-explorer.sh
# =============================================================================

set -u

LOG_DIR="/var/log/disk-explorer"
MASTER_LOG="$LOG_DIR/disk-explorer.log"
TITLE="Disk Explorer - $(hostname)"

# --- Initial checks ------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Root privileges required; restarting with sudo..."
    exec sudo -E bash "$0" "$@"
fi

if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail not found. Install it with: apt install whiptail"
    exit 1
fi

mkdir -p "$LOG_DIR"
touch "$MASTER_LOG"

# --- Dynamic window dimensions ------------------------------------
calc_size() {
    LINES_T=$(tput lines 2>/dev/null || echo 24)
    COLS_T=$(tput cols 2>/dev/null || echo 80)
    H=$((LINES_T - 4)); W=$((COLS_T - 6))
    (( H < 15 )) && H=15
    (( W < 60 )) && W=60
}

# --- Commands (functions) ------------------------------------------------------
cmd_big_files_50m() {
    find / -xdev -type f -size +50M -exec ls -lh {} \; 2>/dev/null \
        | sort -k5 -h -r | head -20
}

cmd_top20_files() {
    find / -xdev -type f -printf '%s %p\n' 2>/dev/null \
        | sort -nr | head -20 | numfmt --field=1 --to=iec
}

cmd_du_root() {
    du -xh / --max-depth=2 2>/dev/null | sort -hr | head -20
}

cmd_du_usr() {
    du -xh /usr --max-depth=2 2>/dev/null | sort -hr | head -15
}

cmd_du_custom() {
    du -xh "$CUSTOM_DIR" --max-depth=2 2>/dev/null | sort -hr | head -20
}

# --- Execution with logging and display -----------------------------------
# usage: run_task "Title" function_name
run_task() {
    local title="$1" func="$2"
    local ts logfile
    ts=$(date +%Y%m%d_%H%M%S)
    logfile="$LOG_DIR/run_${ts}_${func}.log"

    calc_size
    whiptail --title "$TITLE" --infobox \
        "Running:\n\n  $title\n\nThis may take a moment..." 10 "$W"

    {
        echo "=== $title ==="
        echo "Date:     $(date '+%F %T')"
        echo "Function: $func"
        echo "Space:   $(df -h / | awk 'NR==2{print $3" used of "$2" ("$5")"}')"
        echo "-----------------------------------------------------------"
        "$func"
        echo "-----------------------------------------------------------"
        echo "Finished: $(date '+%F %T')"
    } > "$logfile" 2>&1

    cat "$logfile" >> "$MASTER_LOG"
    echo >> "$MASTER_LOG"

    calc_size
    whiptail --title "$title" --scrolltext --textbox "$logfile" "$H" "$W"
}

# --- ncdu --------------------------------------------------------------------
ncdu_installed() { command -v ncdu >/dev/null 2>&1; }

install_ncdu() {
    local logfile="$LOG_DIR/run_$(date +%Y%m%d_%H%M%S)_install_ncdu.log"
    calc_size

    if ncdu_installed; then
        whiptail --title "$TITLE" --msgbox "ncdu is already installed:\n$(ncdu --version)" 9 "$W"
        return
    fi

    whiptail --title "$TITLE" --yesno "Install ncdu using apt?" 8 50 || return

    whiptail --title "$TITLE" --infobox "Installing ncdu..." 6 "$W"
    {
        echo "=== ncdu installation ==="
        echo "Date: $(date '+%F %T')"
        echo "-----------------------------------------------------------"
        apt-get update 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y ncdu 2>&1
        echo "-----------------------------------------------------------"
        if ncdu_installed; then echo "RESULT: installation succeeded"; else echo "RESULT: ERROR"; fi
    } > "$logfile" 2>&1

    cat "$logfile" >> "$MASTER_LOG"; echo >> "$MASTER_LOG"
    whiptail --title "ncdu installation" --scrolltext --textbox "$logfile" "$H" "$W"
}

run_ncdu() {
    if ! ncdu_installed; then
        whiptail --title "$TITLE" --yesno "ncdu is not installed. Install it now?" 8 60 \
            && install_ncdu
        ncdu_installed || return
    fi
    {
        echo "=== ncdu -x / started ==="
        echo "Date: $(date '+%F %T')"
        echo
    } >> "$MASTER_LOG"

    clear
    ncdu -x /
    echo "ncdu closed: $(date '+%F %T')" >> "$MASTER_LOG"
}

# --- Custom directory -----------------------------------------------
custom_dir() {
    calc_size
    CUSTOM_DIR=$(whiptail --title "$TITLE" --inputbox \
        "Directory to analyze (depth 2):" 9 "$W" "/var" 3>&1 1>&2 2>&3) || return
    if [[ ! -d "$CUSTOM_DIR" ]]; then
        whiptail --title "$TITLE" --msgbox "Directory '$CUSTOM_DIR' does not exist." 8 "$W"
        return
    fi
    run_task "Largest directories in $CUSTOM_DIR" cmd_du_custom
}

# --- Log display -----------------------------------------------------
view_logs() {
    while true; do
        calc_size
        mapfile -t files < <(ls -1t "$LOG_DIR"/run_*.log 2>/dev/null | head -30)
        if (( ${#files[@]} == 0 )); then
            whiptail --title "$TITLE" --msgbox "No logs available." 8 40
            return
        fi

        local items=() i=1 f
        for f in "${files[@]}"; do
            items+=("$i" "$(basename "$f" .log | sed 's/^run_//')  ($(du -h "$f" | cut -f1))")
            ((i++))
        done
        items+=("M" "Complete log (all runs)")
        items+=("D" "Delete all logs")
        items+=("B" "Back")

        local choice
        choice=$(whiptail --title "Logs saved in $LOG_DIR" --menu \
            "Select a log to read:" "$H" "$W" $((H - 8)) "${items[@]}" 3>&1 1>&2 2>&3) || return

        case "$choice" in
            B) return ;;
            M) whiptail --title "Complete log" --scrolltext --textbox "$MASTER_LOG" "$H" "$W" ;;
            D)
                if whiptail --title "$TITLE" --yesno "Delete ALL logs?" 8 40; then
                    rm -f "$LOG_DIR"/run_*.log
                    : > "$MASTER_LOG"
                    whiptail --title "$TITLE" --msgbox "Logs deleted." 7 30
                fi
                ;;
            *) whiptail --title "$(basename "${files[$((choice - 1))]}")" \
                   --scrolltext --textbox "${files[$((choice - 1))]}" "$H" "$W" ;;
        esac
    done
}

# --- Cleanup -----------------------------------------------------------------
size_of() { du -sch "$@" 2>/dev/null | tail -1 | cut -f1; }

size_of_find() {   # usage: size_of_find <find arguments>
    local out
    out=$(find "$@" -print0 2>/dev/null | du -ch --files0-from=- 2>/dev/null | tail -1 | cut -f1)
    echo "${out:-0}"
}

size_journal() {
    local out
    out=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)
    echo "${out:-0}"
}

# Cleanup actions (one per checklist item: do_<tag>)
do_apt_clean()   { apt-get clean 2>&1; echo "APT cache cleared."; }
do_journal()     { journalctl --vacuum-size=100M 2>&1; }
do_rotated()     { find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -print -delete 2>&1; echo "Rotated logs deleted."; }
do_tmp()         { find /tmp /var/tmp -xdev -type f -mtime +7 -print -delete 2>&1; echo "Old temporary files deleted."; }
do_crash()       { find /var/crash -type f -print -delete 2>&1; echo "Crash reports deleted."; }
do_syslog()      { truncate -s 0 /var/log/syslog && echo "syslog cleared."; }
do_autoremove()  { DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y 2>&1; }
do_snap() {
    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r name rev; do
        echo "Removing $name (revision $rev)"
        snap remove "$name" --revision="$rev" 2>&1
    done
}

cmd_autoremove_preview() {
    echo "SIMULATION: no changes are made."
    echo
    apt-get -s autoremove --purge 2>&1 | grep -E '^(Remv|Purg|The following|[0-9]+ upgraded)' || echo "No packages to remove."
    echo
    echo "Running kernel: $(uname -r)"
    echo "Installed kernels:"
    dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/{print "  " $2 "  " $3}'
}

cleanup_guided() {
    calc_size
    whiptail --title "$TITLE" --infobox "Calculating estimated reclaimable space..." 6 "$W"

    local rot_find=(/var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \))
    local tmp_find=(/tmp /var/tmp -xdev -type f -mtime +7)

    local items=(
        apt_clean  "APT package cache ($(size_of /var/cache/apt))" ON
        journal    "systemd journal, retain 100M ($(size_journal) current)" ON
        rotated    "Rotated .gz/.1/.old logs in /var/log ($(size_of_find "${rot_find[@]}"))" ON
        tmp        "Files in /tmp and /var/tmp older than 7 days ($(size_of_find "${tmp_find[@]}"))" OFF
        crash      "Crash reports in /var/crash ($(size_of /var/crash))" OFF
        syslog     "Empty /var/log/syslog ($(size_of /var/log/syslog))" OFF
        autoremove "Unused packages and old kernels (autoremove --purge)" OFF
    )
    command -v snap >/dev/null 2>&1 && items+=(snap "Disabled Snap revisions" OFF)

    local sel
    sel=$(whiptail --title "Cleanup space" --checklist \
        "Space = select, Enter = confirm.\nEstimated reclaimable space is shown in parentheses." \
        "$H" "$W" $((H - 8)) "${items[@]}" 3>&1 1>&2 2>&3) || return
    sel=${sel//\"/}
    [[ -z "${sel// /}" ]] && return

    whiptail --title "$TITLE" --yesno \
        "Run cleanup of the selected items?\n\n  $sel\n\nThis operation is irreversible." 12 "$W" || return

    local ts logfile before after
    ts=$(date +%Y%m%d_%H%M%S)
    logfile="$LOG_DIR/run_${ts}_cleanup.log"
    whiptail --title "$TITLE" --infobox "Cleanup in corso..." 6 "$W"

    before=$(df -B1 --output=used / | tail -1 | tr -d ' ')
    {
        echo "=== Cleanup space ==="
        echo "Date:   $(date '+%F %T')"
        echo "Items:   $sel"
        echo "Before:  $(disk_status)"
        echo "-----------------------------------------------------------"
        local tag
        for tag in $sel; do
            echo
            echo ">>> $tag"
            "do_$tag"
        done
        echo
        echo "-----------------------------------------------------------"
        after=$(df -B1 --output=used / | tail -1 | tr -d ' ')
        echo "After:   $(disk_status)"
        echo "Reclaimed: $(numfmt --to=iec $((before - after)))"
    } > "$logfile" 2>&1

    cat "$logfile" >> "$MASTER_LOG"; echo >> "$MASTER_LOG"
    calc_size
    whiptail --title "Cleanup result" --scrolltext --textbox "$logfile" "$H" "$W"
}

cleanup_menu() {
    while true; do
        calc_size
        local choice
        choice=$(whiptail --title "Cleanup space" --menu \
            "Disk /: $(disk_status)" 16 "$W" 4 \
            "1" "Cleanup guided (multiple selection)" \
            "2" "Autoremove preview (no changes)" \
            "B" "Back" 3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) cleanup_guided ;;
            2) run_task "APT autoremove preview" cmd_autoremove_preview ;;
            B) return ;;
        esac
    done
}

# --- Disk status in the menu ----------------------------------------------------
disk_status() {
    df -h / | awk 'NR==2{print $3" used / "$2" ("$5") - free: "$4}'
}

# --- Main menu ---------------------------------------------------------
main_menu() {
    while true; do
        calc_size
        local ncdu_label="Install ncdu"
        ncdu_installed && ncdu_label="ncdu already installed (reinstall/check)"

        local choice
        choice=$(whiptail --title "$TITLE" --menu \
            "Disk /: $(disk_status)\n\nChoose an operation:" 24 "$W" 12 \
            "1" "Files larger than 50 MB (top 20)" \
            "2" "20 largest files (no threshold)" \
            "3" "Largest directories in / (depth 2)" \
            "4" "Largest directories in /usr" \
            "5" "Analyze a chosen directory" \
            "6" "$ncdu_label" \
            "7" "Start ncdu on / (interactive)" \
            "8" "View logs" \
            "9" "Cleanup space (cache, logs, temporary files...)" \
            "0" "Exit" 3>&1 1>&2 2>&3) || break

        case "$choice" in
            1) run_task "Files larger than 50 MB" cmd_big_files_50m ;;
            2) run_task "20 largest files" cmd_top20_files ;;
            3) run_task "Largest directories in /" cmd_du_root ;;
            4) run_task "Largest directories in /usr" cmd_du_usr ;;
            5) custom_dir ;;
            6) install_ncdu ;;
            7) run_ncdu ;;
            8) view_logs ;;
            9) cleanup_menu ;;
            0) break ;;
        esac
    done
    clear
    echo "Logs saved in: $LOG_DIR"
}

main_menu
