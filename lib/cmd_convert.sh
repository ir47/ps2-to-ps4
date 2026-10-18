# shellcheck shell=bash
# `ps2ps4 convert` — for each unprocessed disc image: copy it locally,
# convert it to a fake PKG with ps2fpkg, and stage it in the PS4's
# /data/pkg folder (or a local folder with --local). Safe to re-run.

# Parallel arrays describing every input file found in GAMES_DIR.
ITEM_PATH=() ITEM_KEY=() ITEM_DISC=()
# Indices into ITEM_* that still need processing, in processing order.
WORK=()

# Counters
C_QUEUED=0 C_ALREADY=0 C_BLOCKED=0
C_F_COPY=0 C_F_CONVERT=0 C_F_UPLOAD=0 C_F_VERIFY=0 C_F_DISKFULL=0
C_ATTEMPTED=0

STOP_REASON=""
NET_FAILS=0
BG_PID="" BG_IDX=""
COPY_PID=""

cmd_convert() {
    local upload=1
    [ -n "$LOCAL_OUTPUT_DIR" ] && upload=0

    if [ "$upload" -eq 1 ]; then
        require_config GAMES_DIR PS2FPKG_BIN PS4_IP
    else
        require_config GAMES_DIR PS2FPKG_BIN
    fi
    require_cmds curl awk find
    [ "$upload" -eq 1 ] && require_cmds sqlite3

    [ -d "$GAMES_DIR" ] || die "GAMES_DIR not found: $GAMES_DIR (is the drive mounted?)" 2
    [ -f "$PS2FPKG_BIN" ] || die "ps2fpkg not found at: $PS2FPKG_BIN" 2
    [ -x "$PS2FPKG_BIN" ] || chmod +x "$PS2FPKG_BIN" 2>/dev/null ||
        die "ps2fpkg is not executable: $PS2FPKG_BIN" 2
    PS2FPKG_BIN="$(cd "$(dirname "$PS2FPKG_BIN")" && pwd -P)/$(basename "$PS2FPKG_BIN")"

    mkdir -p "$STATE_DIR" || die "Can't create STATE_DIR: $STATE_DIR" 2
    touch "$DONE_LOG" || die "Can't write DONE_LOG: $DONE_LOG" 2
    make_run_tmp
    if [ "$DRY_RUN" -eq 0 ]; then
        open_log_file convert
        acquire_lock
        mkdir -p "$WORK_DIR" || die "Can't create WORK_DIR: $WORK_DIR" 2
        add_exit_hook convert_cleanup
    fi

    if [ "$upload" -eq 1 ]; then
        if ! ftp_reachable; then
            [ "$DRY_RUN" -eq 1 ] || die_unreachable
            log_warn "PS4 not reachable — dry run continues without the installed-games sync"
            CLI_NO_SYNC=1
        fi
    elif [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$LOCAL_OUTPUT_DIR" || die "Can't create output dir: $LOCAL_OUTPUT_DIR" 2
    fi

    ensure_title_db
    scan_inputs
    if [ "${#ITEM_PATH[@]}" -eq 0 ]; then
        die "No .${INPUT_EXTENSIONS[*]} files found in $GAMES_DIR" 2
    fi

    DONE_SET=$(set_from_file "$DONE_LOG")
    if [ "$upload" -eq 1 ] && [ "$CLI_NO_SYNC" -eq 0 ]; then
        sync_done_from_ps4
    fi
    build_worklist

    log_step "${#ITEM_PATH[@]} disc images | ${#WORK[@]} to process | $C_ALREADY done | $C_BLOCKED blocklisted"
    if [ "$upload" -eq 1 ]; then
        log_info "Target: PS4 $PS4_IP:$PS4_FTP_PORT$PS4_PKG_DIR"
    else
        log_info "Target: $LOCAL_OUTPUT_DIR"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        print_worklist
        return 0
    fi
    if [ "${#WORK[@]}" -eq 0 ]; then
        say "Nothing to do — every disc image is already processed."
        return 0
    fi

    process_worklist "$upload"
    print_convert_summary "$upload"
}

# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------

acquire_lock() {
    LOCK_DIR="$STATE_DIR/convert.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        local pid
        pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            die "Another convert run is already in progress (PID $pid)" 2
        fi
        log_warn "Removing stale lock left by PID ${pid:-unknown}"
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" || die "Can't create lock: $LOCK_DIR" 2
    fi
    echo "$$" >"$LOCK_DIR/pid"
    add_exit_hook release_lock
}
release_lock() { rm -rf "$LOCK_DIR"; }

convert_cleanup() {
    [ -n "$COPY_PID" ] && kill "$COPY_PID" 2>/dev/null
    stop_background_job
    wait 2>/dev/null
    rm -rf "$WORK_DIR"/job-*
}

# Use TITLE_DB if present, else download it once. Without it, ps2fpkg
# falls back to its own serial database / the filename.
ensure_title_db() {
    [ -s "$TITLE_DB" ] && return 0
    if [ -z "$TITLE_DB_URL" ]; then
        TITLE_DB=""
        return 0
    fi
    log_step "Downloading PS2 title database"
    local tmp="$RUN_TMP/title_db.csv"
    if curl -fsSL --max-time 60 -o "$tmp" "$TITLE_DB_URL" && [ -s "$tmp" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            TITLE_DB="$tmp"
        else
            mkdir -p "$(dirname "$TITLE_DB")" && mv "$tmp" "$TITLE_DB"
        fi
        log_info "$(grep -c . "$TITLE_DB" | tr -d ' ') entries"
    else
        log_warn "Couldn't download the title database; ps2fpkg will pick titles itself"
        TITLE_DB=""
    fi
}

lookup_title() {
    [ -n "$TITLE_DB" ] && [ -n "$1" ] || return 0
    awk -F';' -v id="$1" 'toupper($1) == toupper(id) { sub(/\r$/, "", $2); print $2; exit }' "$TITLE_DB"
}

scan_inputs() {
    local find_args=() ext f name key
    for ext in "${INPUT_EXTENSIONS[@]}"; do
        [ "${#find_args[@]}" -gt 0 ] && find_args+=(-o)
        find_args+=(-iname "*.$ext")
    done
    # ._* files are macOS AppleDouble metadata that appear on network shares.
    while IFS= read -r f; do
        name=${f##*/}
        key=${name%.*}
        disc_id_from_name "$key" || REPLY=""
        ITEM_PATH+=("$f")
        ITEM_KEY+=("$key")
        ITEM_DISC+=("$REPLY")
    done < <(find "$GAMES_DIR" -maxdepth 1 -type f ! -name '._*' \( "${find_args[@]}" \) | LC_ALL=C sort)
}

# Games installed by any route (earlier runs, USB, another tool) count as done.
sync_done_from_ps4() {
    log_step "Checking which games are already installed on the PS4"
    if ! appdb_load_installed; then
        log_warn "Skipping installed-games sync"
        return 0
    fi
    local i added=0
    for i in "${!ITEM_PATH[@]}"; do
        [ -n "${ITEM_DISC[i]}" ] || continue
        set_has "$DONE_SET" "${ITEM_KEY[i]}" && continue
        set_has "$INSTALLED_SET" "${ITEM_DISC[i]/-/}" || continue
        mark_done "${ITEM_KEY[i]}"
        added=$((added + 1))
    done
    log_info "$INSTALLED_COUNT apps installed on the PS4; $added newly marked as done"
}

mark_done() {
    DONE_SET="$DONE_SET$NL$1"
    [ "$DRY_RUN" -eq 1 ] || printf '%s\n' "$1" >>"$DONE_LOG"
}

shuffle_lines() {
    awk 'BEGIN { srand() } { printf "%.8f\t%s\n", rand(), $0 }' | sort -n | cut -f2-
}

# Order: never-attempted games first, then ones that failed before, so a
# handful of problem games don't block progress at the start of every run.
build_worklist() {
    local fresh=() retry=() i failed_set=""
    if [ "$RETRY_FAILED_LAST" = 1 ] && [ -f "$FAILED_LOG" ]; then
        failed_set=$(cut -f2 "$FAILED_LOG")
    fi
    for i in "${!ITEM_PATH[@]}"; do
        if set_has "$DONE_SET" "${ITEM_KEY[i]}"; then
            C_ALREADY=$((C_ALREADY + 1))
            continue
        fi
        if [ -n "${ITEM_DISC[i]}" ] && skip_reason "${ITEM_DISC[i]}"; then
            log_debug "Skipping ${ITEM_KEY[i]} ($REPLY)"
            C_BLOCKED=$((C_BLOCKED + 1))
            continue
        fi
        if [ -n "$failed_set" ] && set_has "$failed_set" "${ITEM_KEY[i]}"; then
            retry+=("$i")
        else
            fresh+=("$i")
        fi
    done

    # shellcheck disable=SC2207  # indices are plain integers
    if [ "$ORDER" = "shuffle" ]; then
        [ "${#fresh[@]}" -gt 0 ] && fresh=($(printf '%s\n' "${fresh[@]}" | shuffle_lines))
        [ "${#retry[@]}" -gt 0 ] && retry=($(printf '%s\n' "${retry[@]}" | shuffle_lines))
    fi
    WORK=(${fresh[@]+"${fresh[@]}"} ${retry[@]+"${retry[@]}"})

    if [ -n "$CLI_LIMIT" ] && [ "${#WORK[@]}" -gt "$CLI_LIMIT" ]; then
        WORK=("${WORK[@]:0:$CLI_LIMIT}")
    fi
}

print_worklist() {
    local pos idx title shown=25
    [ "$VERBOSITY" -ge 2 ] && shown=${#WORK[@]}
    say ""
    say "Dry run — would process ${#WORK[@]} disc image(s):"
    for pos in "${!WORK[@]}"; do
        [ "$pos" -ge "$shown" ] && break
        idx=${WORK[pos]}
        title=$(lookup_title "${ITEM_DISC[idx]}")
        say "  $(printf '%4d' $((pos + 1)))  ${ITEM_KEY[idx]}${title:+  →  $title}"
    done
    if [ "${#WORK[@]}" -gt "$shown" ]; then
        say "  ... and $((${#WORK[@]} - shown)) more (use --verbose to list all)"
    fi
}

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------

process_worklist() {
    local upload="$1" pos total=${#WORK[@]}
    for pos in "${!WORK[@]}"; do
        C_ATTEMPTED=$((C_ATTEMPTED + 1))
        process_one "$upload" "$pos" "$total"
        [ -n "$STOP_REASON" ] && break
    done
    stop_background_job
}

# Each game is "prepared" (copied locally, then converted) in its own job
# directory, WORK_DIR/job-<index>. While game N uploads, game N+1 is
# prepared in the background, so a game's copy and conversion overlap the
# previous game's upload. Only one ps2fpkg runs at a time.
process_one() {
    local upload="$1" pos="$2" total="$3"
    local idx=${WORK[pos]}
    local key=${ITEM_KEY[idx]} disc=${ITEM_DISC[idx]} src=${ITEM_PATH[idx]}
    local title status kind pkg

    title=$(lookup_title "$disc")
    echo_game_header "$((pos + 1))" "$total" "$key" "$disc" "$title"

    if [ "$BG_IDX" != "$idx" ]; then
        check_local_space "$pos" || return 1
        # Estimate with the ISO size before spending time on copy + convert.
        if [ "$upload" -eq 1 ] && [ "${STAGING_LIMIT_GB:-0}" -gt 0 ]; then
            staging_has_room "$(ftp_list_files "$PS4_PKG_DIR")" "$(file_size "$src")" || return 1
        fi
        prepare_job "$idx" "$title" fg
    else
        collect_background_job
    fi

    status=$(cat "$(job_dir "$idx")/status" 2>/dev/null)
    # Start on the next game before this one's upload ties up the foreground.
    if [ "$PREFETCH" = 1 ] && [ $((pos + 1)) -lt "$total" ]; then
        start_background_job "$((pos + 1))" "$total"
    fi

    case "$status" in
        ok$'\t'*) pkg=${status#ok$'\t'} ;;
        fail$'\t'*)
            kind=${status#fail$'\t'}
            record_failure "$key" "${kind%%$'\t'*}" "${kind#*$'\t'}"
            rm -rf "$(job_dir "$idx")"
            return 1
            ;;
        *)
            record_failure "$key" convert "Preparation was interrupted"
            rm -rf "$(job_dir "$idx")"
            return 1
            ;;
    esac

    if [ "$upload" -eq 1 ]; then
        deliver_ftp "$pkg" "$key"
    else
        deliver_local "$pkg" "$key"
    fi
    local rc=$?
    rm -rf "$(job_dir "$idx")"
    return "$rc"
}

echo_game_header() {
    local n="$1" total="$2" key="$3" disc="$4" title="$5"
    if [ -n "$title" ]; then
        log_step "[$n/$total] $title (${disc:-$key})"
    else
        log_step "[$n/$total] $key"
        [ -n "$disc" ] && log_debug "No title in database for $disc; ps2fpkg will choose one"
    fi
}

record_failure() {
    local key="$1" kind="$2" detail="$3"
    # With --quiet the per-game header isn't shown, so name the game here.
    if [ "$VERBOSITY" -eq 0 ]; then
        log_error "$key: $detail"
    else
        log_error "$detail"
    fi
    printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$key" "$kind" "$detail" >>"$FAILED_LOG"
    case "$kind" in
        copy) C_F_COPY=$((C_F_COPY + 1)) ;;
        convert) C_F_CONVERT=$((C_F_CONVERT + 1)) ;;
        upload) C_F_UPLOAD=$((C_F_UPLOAD + 1)) ;;
        verify) C_F_VERIFY=$((C_F_VERIFY + 1)) ;;
        disk_full) C_F_DISKFULL=$((C_F_DISKFULL + 1)) ;;
    esac
}

# local_space_shortfall POS — prints "need<TAB>free" and returns 0 if there
# isn't room for this game's ISO and PKG (roughly the same size) plus, when
# working ahead, the next game's ISO and PKG. Has no side effects.
local_space_shortfall() {
    local pos="$1" idx need free next
    idx=${WORK[pos]}
    need=$(($(file_size "${ITEM_PATH[idx]}") * 2))
    if [ "$PREFETCH" = 1 ] && [ $((pos + 1)) -lt "${#WORK[@]}" ]; then
        next=${WORK[pos + 1]}
        need=$((need + $(file_size "${ITEM_PATH[next]}") * 2))
    fi
    free=$(free_bytes "$WORK_DIR")
    [ -n "$free" ] && [ "$free" -lt "$need" ] || return 1
    printf '%s\t%s\n' "$need" "$free"
}

check_local_space() {
    local short
    short=$(local_space_shortfall "$1") || return 0
    STOP_REASON="not enough local space in $WORK_DIR (need $(human_size "${short%%$'\t'*}"), have $(human_size "${short#*$'\t'}"))"
    C_ATTEMPTED=$((C_ATTEMPTED - 1))
    log_error "$STOP_REASON"
    return 1
}

# --------------------------------------------------------------------------
# Preparing a game: copy + convert, in the foreground or background
# --------------------------------------------------------------------------

job_dir() { printf '%s/job-%s\n' "$WORK_DIR" "$1"; }

# prepare_job IDX TITLE fg|bg — copy the disc image into the job directory
# and convert it. Writes the outcome to <job>/status as one of:
#   ok<TAB>/path/to.pkg
#   fail<TAB>copy|convert<TAB>detail
prepare_job() {
    local idx="$1" title="$2" mode="$3" dir src iso pkg
    dir=$(job_dir "$idx")
    src=${ITEM_PATH[idx]}
    iso="$dir/${src##*/}"
    rm -rf "$dir"
    mkdir -p "$dir"

    if [ "$mode" = fg ]; then
        copy_with_progress "$src" "$iso"
    else
        log_debug "Copying ${src##*/} in the background"
        cp "$src" "$iso"
    fi || {
        printf 'fail\tcopy\tcopy from %s failed\n' "$src" >"$dir/status"
        return 1
    }

    if ! pkg=$(convert_to_pkg "$iso" "$title" "$dir/out" "$dir/ps2fpkg.log"); then
        printf 'fail\tconvert\tConversion failed\n' >"$dir/status"
        rm -f "$iso"
        return 1
    fi
    rm -f "$iso"
    printf 'ok\t%s\n' "$pkg" >"$dir/status"
}

# Prepare WORK[POS] in the background, with its output going to its job log.
start_background_job() {
    local pos="$1" total="$2" idx title
    idx=${WORK[pos]}
    # Not enough room to work ahead: the game is prepared in the foreground
    # when its turn comes, where the space check stops the run cleanly.
    local_space_shortfall "$pos" >/dev/null && return 0
    title=$(lookup_title "${ITEM_DISC[idx]}")
    mkdir -p "$(job_dir "$idx")"
    (prepare_job "$idx" "$title" bg) >"$(job_dir "$idx").log" 2>&1 &
    BG_PID=$!
    BG_IDX=$idx
}

collect_background_job() {
    if kill -0 "$BG_PID" 2>/dev/null; then
        log_info "Waiting for background copy + conversion to finish..."
    fi
    wait "$BG_PID"
    local log
    log="$(job_dir "$BG_IDX").log"
    # Surface ps2fpkg's error output, which the background job captured.
    if ! grep -q '^ok' "$(job_dir "$BG_IDX")/status" 2>/dev/null && [ -s "$log" ]; then
        grep -v '^ *·' "$log" >&2
    fi
    rm -f "$log"
    BG_PID="" BG_IDX=""
}

# kill_tree PID — kill a process and all of its descendants. ps2fpkg runs
# a few subshells deep inside a background job, so killing the job's own
# PID alone would leave it running.
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -TERM "$1" 2>/dev/null
}

# Stop a background job and anything it started (cp, ps2fpkg).
stop_background_job() {
    [ -n "$BG_PID" ] || return 0
    kill_tree "$BG_PID"
    wait "$BG_PID" 2>/dev/null
    rm -rf "$(job_dir "$BG_IDX")" "$(job_dir "$BG_IDX").log"
    BG_PID="" BG_IDX=""
}

copy_with_progress() {
    local src="$1" dst="$2" total current rc
    total=$(file_size "$src")
    log_debug "Copying $src ($(human_size "$total"))"
    cp "$src" "$dst.part" &
    COPY_PID=$!
    if is_tty_out && [ "$total" -gt 0 ]; then
        while kill -0 "$COPY_PID" 2>/dev/null; do
            current=$(file_size "$dst.part")
            printf '\r    Copying %3d%%' $((current * 100 / total))
            sleep 0.5
        done
        printf '\r    Copying 100%%\n'
    fi
    wait "$COPY_PID"
    rc=$?
    COPY_PID=""
    if [ "$rc" -ne 0 ]; then
        rm -f "$dst.part"
        return 1
    fi
    mv "$dst.part" "$dst"
}

# --------------------------------------------------------------------------
# Conversion
# --------------------------------------------------------------------------

# convert_to_pkg ISO TITLE OUT_DIR LOG — prints the path of the built PKG.
convert_to_pkg() {
    local iso="$1" title="$2" out="$3" log="$4" pkg
    local args=("$iso" -o "$out")
    [ -n "$title" ] && args+=(-t "$title")
    [ "$AUTO_ART" = 1 ] && args+=(--auto-art)
    args+=(${PS2FPKG_ARGS[@]+"${PS2FPKG_ARGS[@]}"})

    rm -rf "$out"
    mkdir -p "$out"
    log_info "Converting to PKG$([ "$AUTO_ART" = 1 ] && echo ' (with cover art)')..." >&2
    log_debug "ps2fpkg ${args[*]}" >&2

    # Run from the job directory so any scratch files ps2fpkg creates stay there.
    if ! (cd "$(dirname "$out")" && "$PS2FPKG_BIN" "${args[@]}") >"$log" 2>&1; then
        log_error "ps2fpkg output (last 10 lines):"
        tail -n 10 "$log" | sed 's/^/      /' >&2
        [ -n "$LOG_FILE" ] && sed 's/^/      ps2fpkg: /' "$log" >>"$LOG_FILE"
        return 1
    fi
    [ -n "$LOG_FILE" ] && sed 's/^/      ps2fpkg: /' "$log" >>"$LOG_FILE"

    pkg=$(find "$out" -type f -name '*.pkg' | head -n 1)
    if [ -z "$pkg" ]; then
        log_error "ps2fpkg reported success but produced no .pkg"
        return 1
    fi
    printf '%s\n' "$pkg"
}

# --------------------------------------------------------------------------
# Delivery
# --------------------------------------------------------------------------

# remote_size LISTING NAME — size of NAME in a "size<TAB>name" listing.
remote_size() {
    printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$2 == n { print $1; exit }'
}

# staging_has_room LISTING BYTES — enforce STAGING_LIMIT_GB (0 = no limit).
staging_has_room() {
    local staged limit
    [ "${STAGING_LIMIT_GB:-0}" -gt 0 ] || return 0
    staged=$(printf '%s\n' "$1" | awk -F'\t' '{ s += $1 } END { printf "%.0f\n", s }')
    limit=$((STAGING_LIMIT_GB * 1024 * 1024 * 1024))
    [ $((staged + $2)) -le "$limit" ] && return 0
    STOP_REASON="staging limit reached ($(human_size "$staged") staged, limit ${STAGING_LIMIT_GB} GB) — install the queued PKGs, then run: ps2ps4 cleanup"
    C_ATTEMPTED=$((C_ATTEMPTED - 1))
    log_warn "Staging limit reached"
    return 1
}

deliver_ftp() {
    local pkg="$1" key="$2" name size listing rc start secs

    name=${pkg##*/}
    size=$(file_size "$pkg")

    listing=$(ftp_list_files "$PS4_PKG_DIR")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        handle_upload_error "$key" "$rc" "$name" "listing $PS4_PKG_DIR"
        return 1
    fi

    if [ "$(remote_size "$listing" "$name")" = "$size" ]; then
        log_ok "Already staged on the PS4 (same size) — skipping upload"
        mark_done "$key"
        C_QUEUED=$((C_QUEUED + 1))
        return 0
    fi

    staging_has_room "$listing" "$size" || return 1

    log_info "Uploading $(human_size "$size") to $PS4_PKG_DIR..."
    start=$(date +%s)
    ftp_upload "$pkg" "$PS4_PKG_DIR"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        handle_upload_error "$key" "$rc" "$name" "upload"
        return 1
    fi
    NET_FAILS=0
    secs=$(($(date +%s) - start))
    [ "$secs" -gt 0 ] || secs=1

    # Confirm the full file landed, not just that curl exited cleanly.
    listing=$(ftp_list_files "$PS4_PKG_DIR")
    if [ "$(remote_size "$listing" "$name")" != "$size" ]; then
        record_failure "$key" verify "Uploaded file missing or wrong size on the PS4"
        ftp_delete "$PS4_PKG_DIR/$name" >/dev/null 2>&1
        return 1
    fi

    log_ok "Staged in ${secs}s (~$(human_size $((size / secs)))/s): $name"
    mark_done "$key"
    C_QUEUED=$((C_QUEUED + 1))
}

handle_upload_error() {
    local key="$1" rc="$2" name="$3" action="$4" err
    err=$(curl_error_name "$rc")

    if [ "$rc" -eq 70 ]; then
        record_failure "$key" disk_full "PS4 disk full during $action"
        STOP_REASON="the PS4 is out of space — install the queued PKGs, then run: ps2ps4 cleanup"
    elif curl_is_network_error "$rc"; then
        record_failure "$key" upload "$action failed: $err"
        NET_FAILS=$((NET_FAILS + 1))
        if [ "$NET_FAILS" -ge "$MAX_NETWORK_FAILURES" ]; then
            STOP_REASON="lost connection to the PS4 ($NET_FAILS network failures in a row) — is it asleep?"
        fi
        return 0
    else
        record_failure "$key" upload "$action failed: $err"
    fi
    # Don't leave a partial PKG behind for Package Installer to choke on.
    ftp_delete "$PS4_PKG_DIR/$name" >/dev/null 2>&1
    return 0
}

deliver_local() {
    local pkg="$1" key="$2" dst
    dst="$LOCAL_OUTPUT_DIR/${pkg##*/}"
    [ -e "$dst" ] && log_warn "Overwriting existing $dst"
    if ! mv -f "$pkg" "$dst"; then
        record_failure "$key" upload "Couldn't move PKG to $LOCAL_OUTPUT_DIR"
        return 1
    fi
    log_ok "Saved $(human_size "$(file_size "$dst")"): $dst"
    mark_done "$key"
    C_QUEUED=$((C_QUEUED + 1))
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

print_convert_summary() {
    local upload="$1" failed remaining
    failed=$((C_F_COPY + C_F_CONVERT + C_F_UPLOAD + C_F_VERIFY + C_F_DISKFULL))
    remaining=$((${#WORK[@]} - C_ATTEMPTED))

    say ""
    say "──────────── Summary ────────────"
    if [ "$upload" -eq 1 ]; then
        say "Staged on PS4   : $C_QUEUED"
    else
        say "Converted       : $C_QUEUED"
    fi
    say "Already done    : $C_ALREADY"
    say "Blocklisted     : $C_BLOCKED"
    say "Failed          : $failed"
    if [ "$failed" -gt 0 ]; then
        say "  copy $C_F_COPY · convert $C_F_CONVERT · upload $C_F_UPLOAD · verify $C_F_VERIFY · disk full $C_F_DISKFULL"
        say "  details: $FAILED_LOG"
    fi
    if [ -n "$STOP_REASON" ]; then
        say "Not attempted   : $remaining"
        say ""
        say "Stopped early: $STOP_REASON"
    fi
    [ -n "$LOG_FILE" ] && say "Log             : $LOG_FILE"

    if [ "$upload" -eq 1 ] && [ "$C_QUEUED" -gt 0 ]; then
        say ""
        say "Next: on the PS4 open Package Installer and install the queued PKGs,"
        say "      then run 'ps2ps4 cleanup' to free space for the next batch."
    fi

    [ "$failed" -eq 0 ] && [ -z "$STOP_REASON" ]
}
