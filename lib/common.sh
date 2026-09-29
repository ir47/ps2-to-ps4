# shellcheck shell=bash
# Shared config loading, logging and portable helpers.
#
# Everything here must run on the stock macOS bash (3.2): no associative
# arrays, no ${var,,}, and empty arrays are expanded as ${a[@]+"${a[@]}"}
# so `set -u` doesn't trip over them.

PS2PS4_VERSION="1.0.0"
NL=$'\n'

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

set_defaults() {
    # Source material
    GAMES_DIR=""
    INPUT_EXTENSIONS=(iso)

    # ps2fpkg converter
    PS2FPKG_BIN=""
    PS2FPKG_ARGS=()
    AUTO_ART=1

    # Title database (GameID;Name;... CSV). Empty URL = let ps2fpkg pick titles.
    TITLE_DB_URL="https://raw.githubusercontent.com/VTSTech/PS2-OPL-CFG/master/test/PS2-GAMEID-TITLE-MASTER.csv"
    TITLE_DB=""

    # Local state and scratch space
    STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ps2ps4"
    DONE_LOG=""
    FAILED_LOG=""
    LOG_DIR=""
    WORK_DIR="${TMPDIR:-/tmp}"
    WORK_DIR="${WORK_DIR%/}/ps2ps4-work"

    # PS4 / GoldHEN FTP
    PS4_IP=""
    PS4_FTP_PORT=2121
    PS4_FTP_USER=""
    PS4_FTP_PASS=""
    PS4_PKG_DIR="/data/pkg"
    PS4_APP_DB="/system_data/priv/mms/app.db"
    PS4_APPMETA_DIR="/system_data/priv/appmeta"
    FTP_CONNECT_TIMEOUT=5

    # Disc IDs that build a PKG the PS4 refuses to install
    SKIP_PREFIXES=(PBPX PCPX PAPX PDPX)
    SKIP_IDS=()

    # Batch behaviour
    STAGING_LIMIT_GB=0
    PREFETCH=1
    ORDER="sorted"
    RETRY_FAILED_LAST=1
    MAX_NETWORK_FAILURES=3
    STUCK_INSTALL_HOURS=6

    # Icon retrofit
    PS2_TITLE_PREFIXES=(SCUS SLUS SCES SLES SCED SLED SCPS SLPS SLPM SCAJ SLAJ SCKA SLKA)
    ICON_URL_TEMPLATES=("https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/{ID}.jpg")
    ICON_CACHE=""
}

# Picks the first config file that exists: --config, $PS2PS4_CONFIG,
# ./config.sh next to the script, then ~/.config/ps2ps4/config.sh.
find_config() {
    local candidate
    for candidate in \
        "${CLI_CONFIG:-}" \
        "${PS2PS4_CONFIG:-}" \
        "$PS2PS4_ROOT/config.sh" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/ps2ps4/config.sh"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

load_config() {
    CONFIG_FILE=""
    if [ -n "${CLI_CONFIG:-}" ] && [ ! -f "$CLI_CONFIG" ]; then
        die "Config file not found: $CLI_CONFIG" 2
    fi
    if CONFIG_FILE=$(find_config); then
        # shellcheck source=/dev/null
        . "$CONFIG_FILE" || die "Failed to load config: $CONFIG_FILE" 2
    fi

    # Derived paths that depend on STATE_DIR
    DONE_LOG="${DONE_LOG:-$STATE_DIR/completed.txt}"
    FAILED_LOG="${FAILED_LOG:-$STATE_DIR/failed.tsv}"
    TITLE_DB="${TITLE_DB:-$STATE_DIR/ps2_title_db.csv}"
    LOG_DIR="${LOG_DIR:-$STATE_DIR/logs}"
    ICON_CACHE="${ICON_CACHE:-$STATE_DIR/icons}"
}

# require_config VAR... — dies naming every unset variable at once.
require_config() {
    local name missing=""
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            missing="$missing $name"
        fi
    done
    if [ -n "$missing" ]; then
        log_error "Missing required config:$missing"
        log_error "Set them in ${CONFIG_FILE:-a config file (see config.example.sh)}"
        exit 2
    fi
}

require_cmds() {
    local cmd missing=""
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] || die "Required command(s) not found:$missing" 2
}

# --------------------------------------------------------------------------
# Logging
#
# Console output respects --quiet/--verbose; the log file (if any) always
# receives every message with a timestamp so unattended runs can be audited.
# --------------------------------------------------------------------------

VERBOSITY=1
LOG_FILE=""
C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""

setup_colors() {
    if [ "${NO_COLOR:-}" = "" ] && [ "${CLI_COLOR:-auto}" != "never" ] && [ -t 1 ]; then
        C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
        C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BLUE=$'\033[34m'
    fi
}

# open_log_file NAME — start a timestamped log in LOG_DIR unless --log-file given.
open_log_file() {
    if [ -z "$LOG_FILE" ]; then
        mkdir -p "$LOG_DIR" || return 0
        LOG_FILE="$LOG_DIR/$1-$(date '+%Y%m%d-%H%M%S').log"
    fi
    : >>"$LOG_FILE" 2>/dev/null || { LOG_FILE=""; log_warn "Can't write log file; continuing without one"; }
}

_log_file() {
    [ -n "$LOG_FILE" ] || return 0
    printf '%s %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$LOG_FILE"
}

log_debug() { _log_file DEBUG "$*"; [ "$VERBOSITY" -ge 2 ] && printf '%s   · %s%s\n' "$C_DIM" "$*" "$C_RESET"; return 0; }
log_info()  { _log_file INFO "$*";  [ "$VERBOSITY" -ge 1 ] && printf '    %s\n' "$*"; return 0; }
log_step()  { _log_file INFO "$*";  [ "$VERBOSITY" -ge 1 ] && printf '%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; return 0; }
log_ok()    { _log_file OK "$*";    [ "$VERBOSITY" -ge 1 ] && printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; return 0; }
log_warn()  { _log_file WARN "$*";  printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { _log_file ERROR "$*"; printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
# say — always printed, even with --quiet (used for final summaries).
say()       { _log_file INFO "$*";  printf '%s\n' "$*"; }

die() {
    log_error "$1"
    exit "${2:-1}"
}

# --------------------------------------------------------------------------
# Exit hooks — commands register cleanup (kill background copies, remove
# temp files) and they all run on normal exit, error or Ctrl+C.
# --------------------------------------------------------------------------

EXIT_HOOKS=()

add_exit_hook() { EXIT_HOOKS+=("$1"); }

run_exit_hooks() {
    local hook
    for hook in ${EXIT_HOOKS[@]+"${EXIT_HOOKS[@]}"}; do
        "$hook" || true
    done
    EXIT_HOOKS=()
}

install_traps() {
    trap run_exit_hooks EXIT
    trap 'echo >&2; log_warn "Interrupted"; exit 130' INT TERM
}

# Per-run temp dir, removed on exit.
make_run_tmp() {
    RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ps2ps4.XXXXXX") || die "mktemp failed"
    add_exit_hook _remove_run_tmp
}
_remove_run_tmp() { [ -n "${RUN_TMP:-}" ] && rm -rf "$RUN_TMP"; }

# --------------------------------------------------------------------------
# Small portable helpers (BSD/macOS and GNU/Linux)
# --------------------------------------------------------------------------

file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

# Free bytes on the filesystem holding $1.
free_bytes() {
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

human_size() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), b, u[i]
    }'
}

# in_list NEEDLE ITEM... — exact membership test.
in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# Newline-delimited string sets: fast membership without associative arrays.
#   set=$(set_from_file file); set_has "$set" item
# set_has adds its own delimiters, so leading/trailing newlines don't matter.
set_from_file() { [ -f "$1" ] && cat "$1"; return 0; }
set_has() {
    case "$NL$1$NL" in
        *"$NL$2$NL"*) return 0 ;;
    esac
    return 1
}

is_tty_out() { [ -t 1 ] && [ "$VERBOSITY" -ge 1 ]; }

# --------------------------------------------------------------------------
# PS2 identifiers
#
#   disc ID   SCUS-97105   (how ISOs are usually named)
#   title ID  SCUS97105    (how the PS4 registers the installed app)
# --------------------------------------------------------------------------

# disc_id_from_name NAME — sets REPLY to the normalised disc ID, or returns 1.
# Accepts "SCUS-97105", "SCUS_971.05" (OPL style) and lowercase variants.
# Sets REPLY instead of printing so callers avoid a subshell per file.
disc_id_from_name() {
    local re='([A-Za-z]{4})[-_]([0-9]{3})\.?([0-9]{2})'
    REPLY=""
    [[ $1 =~ $re ]] || return 1
    local prefix="${BASH_REMATCH[1]}"
    case "$prefix" in
        *[a-z]*) prefix=$(printf '%s' "$prefix" | tr '[:lower:]' '[:upper:]') ;;
    esac
    REPLY="$prefix-${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
}

title_id_from_disc_id() { printf '%s\n' "${1/-/}"; }
disc_id_from_title_id() { printf '%s-%s\n' "${1:0:4}" "${1:4}"; }

# First XXXX00000 token in a PKG filename, e.g.
#   UP9000-SCUS97105_00-SCUS971050000001.pkg -> SCUS97105
title_id_from_pkg_name() {
    local re='([A-Z]{4}[0-9]{5})'
    [[ $1 =~ $re ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# skip_reason DISC_ID — sets REPLY to why an ID is blocklisted, or returns 1.
skip_reason() {
    local disc_id="$1"
    REPLY=""
    if in_list "${disc_id:0:4}" ${SKIP_PREFIXES[@]+"${SKIP_PREFIXES[@]}"}; then
        REPLY="blocklisted prefix ${disc_id:0:4}"
        return 0
    fi
    if in_list "$disc_id" ${SKIP_IDS[@]+"${SKIP_IDS[@]}"}; then
        REPLY="blocklisted ID"
        return 0
    fi
    return 1
}
