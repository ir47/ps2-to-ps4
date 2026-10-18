# shellcheck shell=bash
# `ps2ps4 status` — progress through the collection and what's on the PS4.
# `ps2ps4 doctor` — check dependencies and configuration.

cmd_status() {
    make_run_tmp

    say "Config          : ${CONFIG_FILE:-none (defaults only)}"
    say "State dir       : $STATE_DIR"
    say ""

    if [ -n "$GAMES_DIR" ] && [ -d "$GAMES_DIR" ]; then
        # Reuse the convert command's scanning so the numbers match exactly.
        scan_inputs
        DONE_SET=$(set_from_file "$DONE_LOG")
        build_worklist
        say "Collection      : $GAMES_DIR"
        say "  disc images   : ${#ITEM_PATH[@]}"
        say "  done          : $C_ALREADY"
        say "  blocklisted   : $C_BLOCKED"
        say "  remaining     : ${#WORK[@]}"
    else
        say "Collection      : ${GAMES_DIR:-not configured} (not available)"
    fi

    if [ -s "$FAILED_LOG" ]; then
        say ""
        say "Failures logged : $(grep -c . "$FAILED_LOG" | tr -d ' ') (by type:" \
            "$(cut -f3 "$FAILED_LOG" | sort | uniq -c | awk '{ printf "%s%s %s", sep, $2, $1; sep = ", " }'))"
        say "  most recent:"
        tail -n 5 "$FAILED_LOG" | awk -F'\t' '{ printf "    %s  %-8s %s — %s\n", substr($1, 1, 16), $3, $2, $4 }'
    fi

    say ""
    if [ -z "$PS4_IP" ]; then
        say "PS4             : not configured"
        return 0
    fi
    if ! ftp_reachable; then
        say "PS4             : $PS4_IP:$PS4_FTP_PORT — NOT reachable"
        return 1
    fi
    say "PS4             : $PS4_IP:$PS4_FTP_PORT — reachable"

    local listing count bytes cleanable=0 name tid
    listing=$(ftp_list_files "$PS4_PKG_DIR" | awk -F'\t' '$2 ~ /\.[pP][kK][gG]$/')
    count=$(printf '%s\n' "$listing" | grep -c .)
    bytes=$(printf '%s\n' "$listing" | awk -F'\t' '{ s += $1 } END { printf "%.0f\n", s }')
    say "  staged PKGs   : $count ($(human_size "$bytes")) in $PS4_PKG_DIR"

    if command -v sqlite3 >/dev/null 2>&1 && appdb_load_installed 2>/dev/null; then
        while IFS=$'\t' read -r _ name; do
            tid=$(title_id_from_pkg_name "$name") || continue
            set_has "$FINISHED_SET" "$tid" && cleanable=$((cleanable + 1))
        done <<<"$listing"
        say "  installed apps: $FINISHED_COUNT"
        say "  cleanable     : $cleanable staged PKG(s) already installed (run: ps2ps4 cleanup)"
        report_unfinished_installs
    fi
}

# stuck_installs — unfinished installs older than STUCK_INSTALL_HOURS, from
# the app.db fetched by appdb_load_installed.
stuck_installs() {
    appdb_unfinished_installs "$RUN_TMP/app.db" 2>/dev/null |
        awk -F'\t' -v h="$STUCK_INSTALL_HOURS" '$4 >= h'
}

report_unfinished_installs() {
    local all stuck total nstuck
    all=$(appdb_unfinished_installs "$RUN_TMP/app.db" 2>/dev/null)
    total=$(printf '%s\n' "$all" | grep -c .)
    [ "$total" -gt 0 ] || return 0
    stuck=$(stuck_installs)
    nstuck=$(printf '%s\n' "$stuck" | grep -c .)
    if [ "$nstuck" -eq 0 ]; then
        say "  installing    : $total (queued or in progress)"
        return 0
    fi
    say "  installing    : $total, of which $nstuck unfinished for ${STUCK_INSTALL_HOURS}h+ (possibly stuck):"
    printf '%s\n' "$stuck" | awk -F'\t' '{
        age = ($4 < 48) ? sprintf("%.0fh", $4) : sprintf("%.1f days", $4 / 24)
        printf "    %-9s  %-44.44s started %s (%s ago)\n", $1, $2, $3, age
    }'
    say "  If the PS4 has finished its install queue, reinstall these from Package Installer."
}

cmd_doctor() {
    local problems=0

    check() {
        if eval "$2" >/dev/null 2>&1; then
            log_ok "$1"
        else
            log_error "$1${3:+ — $3}"
            problems=$((problems + 1))
        fi
    }

    log_step "Environment"
    log_info "bash $BASH_VERSION on $(uname -s) $(uname -m)"
    log_info "config: ${CONFIG_FILE:-none found (see config.example.sh)}"

    log_step "Dependencies"
    check "curl" "command -v curl"
    check "sqlite3" "command -v sqlite3" "needed to read the PS4 app registry"
    check "image resizer (sips or ImageMagick)" "command -v sips || command -v magick || command -v convert" \
        "only needed for 'ps2ps4 icons'"

    log_step "Configuration"
    check "GAMES_DIR exists (${GAMES_DIR:-unset})" '[ -d "$GAMES_DIR" ]'
    check "PS2FPKG_BIN exists (${PS2FPKG_BIN:-unset})" '[ -f "$PS2FPKG_BIN" ]'
    if [ -f "$PS2FPKG_BIN" ] && [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
        if file "$PS2FPKG_BIN" 2>/dev/null | grep -q x86_64; then
            check "Rosetta 2 available for x86_64 ps2fpkg" "arch -x86_64 /usr/bin/true" \
                "install with: softwareupdate --install-rosetta"
        fi
    fi
    check "STATE_DIR writable ($STATE_DIR)" 'mkdir -p "$STATE_DIR" && [ -w "$STATE_DIR" ]'
    check "WORK_DIR writable ($WORK_DIR)" 'mkdir -p "$WORK_DIR" && [ -w "$WORK_DIR" ]'

    log_step "PS4"
    check "PS4_IP set" '[ -n "$PS4_IP" ]'
    if [ -n "$PS4_IP" ]; then
        check "ping $PS4_IP" 'ping -c 1 -t 2 "$PS4_IP" || ping -c 1 -W 2 "$PS4_IP"' \
            "check the cable/network and the PS4's IP address"
        check "GoldHEN FTP on port $PS4_FTP_PORT" ftp_reachable "enable the FTP server in GoldHEN"
        check "$PS4_PKG_DIR listable" 'ftp_list_files "$PS4_PKG_DIR"'
    fi

    say ""
    if [ "$problems" -eq 0 ]; then
        say "All checks passed."
    else
        say "$problems problem(s) found."
    fi
    [ "$problems" -eq 0 ]
}
