# shellcheck shell=bash
# `ps2ps4 cleanup` — delete staged PKGs from the PS4 once Package Installer
# has installed them, freeing space for the next batch.

cmd_cleanup() {
    require_config PS4_IP
    require_cmds curl sqlite3 awk
    make_run_tmp
    [ "$DRY_RUN" -eq 1 ] || open_log_file cleanup

    ftp_reachable || die_unreachable

    log_step "Reading the PS4 app registry"
    appdb_load_installed || die "Can't determine installed apps; nothing deleted"
    log_info "$FINISHED_COUNT installed apps, $((INSTALLED_COUNT - FINISHED_COUNT)) still installing"

    log_step "Listing $PS4_PKG_DIR"
    local listing rc
    listing=$(ftp_list_files "$PS4_PKG_DIR")
    rc=$?
    [ "$rc" -eq 0 ] || die "Couldn't list $PS4_PKG_DIR: $(curl_error_name "$rc")"
    listing=$(printf '%s\n' "$listing" | awk -F'\t' '$2 ~ /\.[pP][kK][gG]$/')
    log_info "$(printf '%s\n' "$listing" | grep -c .) PKG(s) staged"

    local size name tid deleted=() deleted_sizes=() kept=0 installing=0 unknown=0 freed=0 failed=0
    while IFS=$'\t' read -r size name; do
        [ -n "$name" ] || continue
        if ! tid=$(title_id_from_pkg_name "$name"); then
            log_warn "Keeping (no title ID in filename): $name"
            unknown=$((unknown + 1))
            continue
        fi
        # Deleting a PKG while Package Installer is still reading it breaks
        # the install, so only titles whose install has completed qualify.
        if ! set_has "$FINISHED_SET" "$tid" && set_has "$INSTALLED_SET" "$tid"; then
            log_info "Keeping (still installing): $name"
            installing=$((installing + 1))
            continue
        fi
        if ! set_has "$FINISHED_SET" "$tid"; then
            log_info "Keeping (not installed yet): $name"
            kept=$((kept + 1))
            continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            log_ok "Would delete ($tid installed): $name"
        elif ftp_delete "$PS4_PKG_DIR/$name"; then
            log_ok "Deleted ($tid installed): $name"
        else
            log_error "FTP delete failed: $name"
            failed=$((failed + 1))
            continue
        fi
        deleted+=("$name")
        deleted_sizes+=("$size")
        freed=$((freed + size))
    done <<<"$listing"

    # DELE returning success isn't proof; confirm against a fresh listing.
    if [ "$DRY_RUN" -eq 0 ] && [ "${#deleted[@]}" -gt 0 ]; then
        local after i confirmed=()
        after=$(ftp_list_files "$PS4_PKG_DIR" | cut -f2)
        freed=0
        for i in "${!deleted[@]}"; do
            if set_has "$after" "${deleted[i]}"; then
                log_error "Still present after delete: ${deleted[i]}"
                failed=$((failed + 1))
            else
                confirmed+=("${deleted[i]}")
                freed=$((freed + deleted_sizes[i]))
            fi
        done
        deleted=(${confirmed[@]+"${confirmed[@]}"})
    fi

    say ""
    say "──────────── Summary ────────────"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "Would delete    : ${#deleted[@]} ($(human_size "$freed"))"
    else
        say "Deleted         : ${#deleted[@]} (~$(human_size "$freed") freed)"
    fi
    say "Not installed   : $kept"
    [ "$installing" -gt 0 ] && say "Still installing: $installing (run cleanup again once they finish)"
    [ "$unknown" -gt 0 ] && say "Unrecognised    : $unknown"
    [ "$failed" -gt 0 ] && say "Delete failed   : $failed"
    [ "$failed" -eq 0 ]
}
