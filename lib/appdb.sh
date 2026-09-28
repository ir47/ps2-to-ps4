# shellcheck shell=bash
# Reading the PS4's app registry (app.db).
#
# PS2 classics install outside the part of the filesystem GoldHEN's FTP
# server exposes, so listing /user/app doesn't show them. The reliable
# source of truth is the SQLite registry at /system_data/priv/mms/app.db,
# which has one tbl_appbrowse_<local user id> table per local account.

# appdb_fetch DEST — download app.db and check it is a readable SQLite file.
appdb_fetch() {
    local dest="$1"
    if ! ftp_get "$PS4_APP_DB" "$dest" 60; then
        log_warn "Could not download $PS4_APP_DB from the PS4"
        return 1
    fi
    if ! sqlite3 "$dest" "SELECT 1 FROM sqlite_master LIMIT 1;" >/dev/null 2>&1; then
        log_warn "Downloaded app.db is not a readable SQLite database"
        return 1
    fi
}

appdb_tables() {
    sqlite3 "$1" "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'tbl_appbrowse_%';"
}

# appdb_installed_title_ids DB [finished] — every titleId (SCUS97105,
# CUSA00219, ...) in the registry across all local user accounts, deduplicated.
#
# A title is added to the registry as soon as its install *starts*. While
# it's installing it has contentStatus = 1 and contentSize = 0; once done,
# contentStatus drops to 0 and contentSize holds the installed size. Pass
# "finished" to return only completed installs.
appdb_installed_title_ids() {
    local db="$1" filter="" tables table
    [ "${2:-}" = "finished" ] && filter="AND contentStatus = 0 AND contentSize > 0"
    tables=$(appdb_tables "$db")
    if [ -z "$tables" ]; then
        log_warn "No tbl_appbrowse_* table found in app.db"
        return 1
    fi
    while IFS= read -r table; do
        [ -n "$table" ] || continue
        sqlite3 "$db" "SELECT titleId FROM \"$table\" WHERE titleId IS NOT NULL $filter;"
    done <<<"$tables" | sort -u
}

# appdb_load_installed — fetch app.db and set:
#   INSTALLED_SET / INSTALLED_COUNT  titles in the registry (installed or installing)
#   FINISHED_SET  / FINISHED_COUNT   titles whose install has completed
# Returns 1 if the registry is unavailable.
appdb_load_installed() {
    local db="$RUN_TMP/app.db" ids
    INSTALLED_SET="" INSTALLED_COUNT=0
    FINISHED_SET="" FINISHED_COUNT=0
    appdb_fetch "$db" || return 1
    ids=$(appdb_installed_title_ids "$db") || return 1
    INSTALLED_SET="$ids"
    INSTALLED_COUNT=$(printf '%s\n' "$ids" | grep -c .)
    ids=$(appdb_installed_title_ids "$db" finished) || return 1
    FINISHED_SET="$ids"
    FINISHED_COUNT=$(printf '%s\n' "$ids" | grep -c .)
}
