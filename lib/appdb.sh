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

# appdb_unfinished_installs DB — installs that started but haven't completed
# (contentStatus = 1), oldest first, as "titleId<TAB>name<TAB>started<TAB>hours".
# Age is measured against the newest mTime in the registry, i.e. the PS4's
# own clock at its last activity, so a wrong console clock doesn't matter.
appdb_unfinished_installs() {
    local db="$1" tables table
    tables=$(appdb_tables "$db") || return 1
    while IFS= read -r table; do
        [ -n "$table" ] || continue
        sqlite3 -separator $'\t' "$db" "
            SELECT titleId, titleName, substr(installDate, 1, 16),
                   ROUND((julianday(ref) - julianday(installDate)) * 24, 1)
            FROM \"$table\", (SELECT max(mTime) AS ref FROM \"$table\")
            WHERE contentStatus = 1 AND titleId IS NOT NULL;"
    done <<<"$tables" | sort -t$'\t' -k3,3 | awk -F'\t' '!seen[$1]++'
}

# appdb_load_installed — fetch app.db and set:
#   INSTALLED_SET / INSTALLED_COUNT  titles in the registry (installed or installing)
#   FINISHED_SET  / FINISHED_COUNT   titles whose install has completed
#   INSTALLING_COUNT                 installs queued or in progress
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
    # Not INSTALLED_COUNT - FINISHED_COUNT: built-in and disc-based apps
    # have no recorded size, so they're neither "finished" nor installing.
    INSTALLING_COUNT=$(appdb_unfinished_installs "$db" | grep -c .)
    # grep -c exits 1 when it counts zero; that mustn't read as a failure.
    return 0
}
