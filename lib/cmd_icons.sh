# shellcheck shell=bash
# `ps2ps4 icons` — retrofit home-screen icons on PS2 games that were
# installed without cover art (e.g. converted before --auto-art was used).
# Fetches box art (by default from the xlenore/ps2-covers collection),
# letterboxes it to 512x512 and overwrites
# /system_data/priv/appmeta/<TITLE_ID>/icon0.png on the console.

cmd_icons() {
    require_config PS4_IP
    require_cmds curl sqlite3
    detect_resizer || die "Need 'sips' (macOS) or ImageMagick ('magick'/'convert') to resize icons" 2
    make_run_tmp
    [ "$DRY_RUN" -eq 1 ] || open_log_file icons
    mkdir -p "$ICON_CACHE" || die "Can't create ICON_CACHE: $ICON_CACHE" 2

    ftp_reachable || die_unreachable

    log_step "Reading the PS4 app registry"
    appdb_load_installed || die "Can't determine installed apps"

    local titles tid
    if [ -n "$CLI_ONLY" ]; then
        titles=$(printf '%s\n' "${CLI_ONLY/-/}")
    else
        titles=$(printf '%s\n' "$INSTALLED_SET" | while IFS= read -r tid; do
            [ -n "$tid" ] && in_list "${tid:0:4}" "${PS2_TITLE_PREFIXES[@]}" && printf '%s\n' "$tid"
        done)
    fi
    local total
    total=$(printf '%s\n' "$titles" | grep -c .)
    log_info "$total PS2 title(s) to update"

    local updated=0 missing=0 failed=0 disc png
    while IFS= read -r tid; do
        [ -n "$tid" ] || continue
        disc=$(disc_id_from_title_id "$tid")
        log_step "$disc"

        png="$ICON_CACHE/$disc.png"
        if [ ! -s "$png" ] || [ "$CLI_FORCE" -eq 1 ]; then
            if ! fetch_cover "$disc" "$RUN_TMP/cover.png"; then
                log_warn "No cover art found"
                missing=$((missing + 1))
                continue
            fi
            if ! resize_icon "$RUN_TMP/cover.png" "$png"; then
                log_error "Resize failed"
                failed=$((failed + 1))
                continue
            fi
        else
            log_debug "Using cached $png"
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log_ok "Would upload icon to $PS4_APPMETA_DIR/$tid/icon0.png"
        elif ftp_curl -sS -T "$png" "$(ftp_url "$PS4_APPMETA_DIR/$tid/icon0.png")" -o /dev/null; then
            log_ok "Icon updated"
        else
            log_error "Upload failed: $PS4_APPMETA_DIR/$tid/icon0.png"
            failed=$((failed + 1))
            continue
        fi
        updated=$((updated + 1))
    done <<<"$titles"

    say ""
    say "──────────── Summary ────────────"
    say "$([ "$DRY_RUN" -eq 1 ] && echo 'Would update ' || echo 'Updated      ')   : $updated"
    say "No cover art    : $missing"
    say "Failed          : $failed"
    if [ "$DRY_RUN" -eq 0 ] && [ "$updated" -gt 0 ]; then
        say ""
        say "The PS4 caches icons; restart the console if the new ones don't appear."
    fi
    [ "$failed" -eq 0 ]
}

# Try each ICON_URL_TEMPLATES entry ({ID} = disc ID) until one downloads.
fetch_cover() {
    local disc="$1" dest="$2" template url
    for template in "${ICON_URL_TEMPLATES[@]}"; do
        url=${template//\{ID\}/$disc}
        if curl -fsSL --max-time 20 -o "$dest" "$url" 2>/dev/null && [ -s "$dest" ]; then
            log_debug "Cover from $url"
            return 0
        fi
    done
    return 1
}

detect_resizer() {
    if command -v sips >/dev/null 2>&1; then
        RESIZER=sips
    elif command -v magick >/dev/null 2>&1; then
        RESIZER=magick
    elif command -v convert >/dev/null 2>&1; then
        RESIZER=convert
    else
        return 1
    fi
}

# PS4 icons are 512x512 PNGs. Box art is portrait, so fit it inside the
# square and pad the sides rather than squashing it.
resize_icon() {
    case "$RESIZER" in
        sips)
            sips -s format png -Z 512 "$1" --out "$2" >/dev/null 2>&1 &&
                sips -p 512 512 --padColor 000000 "$2" >/dev/null 2>&1
            ;;
        *)
            "$RESIZER" "$1" -resize 512x512 -background black -gravity center \
                -extent 512x512 "PNG:$2"
            ;;
    esac
}
