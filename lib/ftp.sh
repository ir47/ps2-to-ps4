# shellcheck shell=bash
# Thin curl wrappers for talking to GoldHEN's FTP server.

ftp_base() { printf 'ftp://%s:%s' "$PS4_IP" "$PS4_FTP_PORT"; }

# ftp_url /remote/path — spaces are the only thing we realistically need to escape.
ftp_url() { printf '%s%s' "$(ftp_base)" "${1// /%20}"; }

# ftp_curl ARGS... — curl with the FTP options every call needs.
ftp_curl() {
    local opts=(--ftp-pasv --connect-timeout "$FTP_CONNECT_TIMEOUT")
    if [ -n "$PS4_FTP_USER" ]; then
        opts+=(--user "$PS4_FTP_USER:$PS4_FTP_PASS")
    fi
    curl "${opts[@]}" "$@"
}

ftp_reachable() {
    ftp_curl -s --max-time 10 -o /dev/null "$(ftp_base)/"
}

# Explain the usual reasons the PS4 isn't answering, then exit.
die_unreachable() {
    log_error "PS4 FTP not reachable at $PS4_IP:$PS4_FTP_PORT"
    log_info "Check that:"
    log_info "  - the PS4 is on, jailbroken and GoldHEN's FTP server is enabled"
    log_info "  - 'ping $PS4_IP' answers (the static IP can change after a reboot)"
    log_info "  - Rest Mode is disabled in Power Save Settings"
    exit 3
}

ftp_get() {
    ftp_curl -sS --max-time "${3:-120}" -o "$2" "$(ftp_url "$1")"
}

# ftp_list_files DIR — prints "size<TAB>name" for each regular file in DIR.
# Parses LIST output (unix `ls -l` style) and keeps names containing spaces.
ftp_list_files() {
    ftp_curl -sS --max-time 30 "$(ftp_url "${1%/}/")" | parse_ftp_listing
}

parse_ftp_listing() {
    tr -d '\r' | awk '/^-/ {
        size = $5; name = $0
        for (i = 0; i < 8; i++) sub(/^[^ ]+ +/, "", name)
        print size "\t" name
    }'
}

# ftp_upload LOCAL_FILE REMOTE_DIR — returns curl's exit code.
# Shows a progress bar when attached to a terminal.
ftp_upload() {
    local progress=(-sS)
    if is_tty_out; then
        progress=(--progress-bar)
    fi
    ftp_curl "${progress[@]}" -T "$1" "$(ftp_url "${2%/}/")" -o /dev/null
}

ftp_delete() {
    ftp_curl -sS --max-time 30 -o /dev/null -Q "DELE $1" "$(ftp_base)/"
}

# Human-readable meaning of the curl exit codes we care about.
curl_error_name() {
    case "$1" in
        6) echo "could not resolve host" ;;
        7) echo "could not connect" ;;
        9) echo "access denied to remote directory" ;;
        25) echo "upload rejected by server" ;;
        28) echo "timed out" ;;
        55|56) echo "connection lost" ;;
        70) echo "PS4 disk full" ;;
        *) echo "curl error $1" ;;
    esac
}

# True for failures that suggest the PS4 has gone away (asleep, rebooted).
curl_is_network_error() {
    case "$1" in
        6|7|28|55|56) return 0 ;;
    esac
    return 1
}
