#!/usr/bin/env bash
# Test suite: unit tests for the pure helpers plus an end-to-end `convert`
# run in --local mode against a fake ps2fpkg. No PS4 required.
#
#   tests/run.sh

set -u -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures"
PASS=0 FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }

assert_eq() { # NAME EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
assert_true() { # NAME CMD...
    local name="$1"; shift
    if "$@"; then ok "$name"; else fail "$name"; fi
}
assert_false() {
    local name="$1"; shift
    if "$@"; then fail "$name"; else ok "$name"; fi
}

# Load the libraries without running main.
PS2PS4_ROOT="$ROOT"
for lib in common ftp appdb cmd_convert cmd_cleanup cmd_icons cmd_status; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$lib.sh"
done
set_defaults

echo "disc ID parsing"
disc_id_from_name "SCUS-97105 (1.10)"; assert_eq "hyphenated" "SCUS-97105" "$REPLY"
disc_id_from_name "SLUS_200.62.Grand Theft Auto III"; assert_eq "OPL style" "SLUS-20062" "$REPLY"
disc_id_from_name "sles_123.45"; assert_eq "lowercase" "SLES-12345" "$REPLY"
assert_false "no ID" disc_id_from_name "Some Homebrew Disc"
assert_eq "title id from disc id" "SCUS97105" "$(title_id_from_disc_id SCUS-97105)"
assert_eq "disc id from title id" "SCUS-97105" "$(disc_id_from_title_id SCUS97105)"
assert_eq "title id from pkg" "SCUS97105" "$(title_id_from_pkg_name UP9000-SCUS97105_00-SCUS971050000001.pkg)"
assert_false "pkg without title id" title_id_from_pkg_name "random.pkg"

echo "skip list"
SKIP_PREFIXES=(PBPX) SKIP_IDS=(SLUS-99999)
assert_true "prefix blocked" skip_reason PBPX-95517
assert_true "id blocked" skip_reason SLUS-99999
assert_false "normal id allowed" skip_reason SCUS-97105
SKIP_PREFIXES=() SKIP_IDS=()
assert_false "empty lists (set -u safe)" skip_reason PBPX-95517
set_defaults

echo "string sets"
s="$NL""Game (USA) [!]$NL""SCUS-97105 (1.10)$NL"
assert_true "member with glob chars" set_has "$s" "Game (USA) [!]"
assert_false "prefix is not a member" set_has "$s" "SCUS-97105"
assert_false "glob is literal" set_has "$s" "Game*"
assert_true "last item without trailing newline" set_has "$(printf 'a\nb\n')" "b"
assert_true "single item" set_has "only" "only"
assert_false "empty set" set_has "" "x"

echo "FTP listing parser"
listing=$(printf '%s\r\n' \
    "drwxr-xr-x 1 root wheel 0 Jan 1 2024 subdir" \
    "-rw-r--r-- 1 root wheel 1955762176 Jan 1 12:00 UP9000-SCUS97105_00-SCUS971050000001.pkg" \
    "-rw-r--r-- 1 root wheel 42 Jan 1 12:00 name with  spaces.pkg" | parse_ftp_listing)
assert_eq "skips dirs, keeps size + names" \
    "1955762176	UP9000-SCUS97105_00-SCUS971050000001.pkg${NL}42	name with  spaces.pkg" "$listing"
assert_eq "remote_size lookup" "42" "$(remote_size "$listing" "name with  spaces.pkg")"

echo "misc helpers"
assert_eq "human_size bytes" "512 B" "$(human_size 512)"
assert_eq "human_size GB" "1.8 GB" "$(human_size 1955762176)"
assert_eq "curl 70 is disk full" "PS4 disk full" "$(curl_error_name 70)"
assert_true "curl 7 is a network error" curl_is_network_error 7
assert_false "curl 25 is not a network error" curl_is_network_error 25

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ps2ps4-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "app.db parsing"
if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$TMP/app.db" "
        CREATE TABLE tbl_appbrowse_1234567890 (titleId TEXT, contentStatus INT, contentSize INT);
        CREATE TABLE tbl_appbrowse_0000000002 (titleId TEXT, contentStatus INT, contentSize INT);
        CREATE TABLE tbl_other (titleId TEXT);
        INSERT INTO tbl_appbrowse_1234567890 VALUES
            ('SCUS97105', 0, 1952710656), ('CUSA00219', 0, 576622592), (NULL, 0, 0),
            ('SLUS20549', 1, 0);
        INSERT INTO tbl_appbrowse_0000000002 VALUES ('SCUS97105', 0, 1952710656), ('SLUS20062', 0, 4458000000);
        INSERT INTO tbl_other VALUES ('NOPE00000');"
    assert_eq "all users, deduplicated" "CUSA00219${NL}SCUS97105${NL}SLUS20062${NL}SLUS20549" \
        "$(appdb_installed_title_ids "$TMP/app.db")"
    assert_eq "finished excludes installs in progress" "CUSA00219${NL}SCUS97105${NL}SLUS20062" \
        "$(appdb_installed_title_ids "$TMP/app.db" finished)"
    sqlite3 "$TMP/empty.db" "CREATE TABLE t (x);"
    assert_false "no appbrowse table" appdb_installed_title_ids "$TMP/empty.db" 2>/dev/null
else
    echo "  skip  sqlite3 not installed"
fi

echo "convert end-to-end (--local, fake ps2fpkg)"
games="$TMP/games" out="$TMP/out" state="$TMP/state"
mkdir -p "$games"
for f in "SCUS-97105 (1.10).iso" "SLUS_200.62.GTA3.iso" "PBPX-95517.iso" \
         "SLES-12345 BROKEN.iso" "No Serial Here.iso" "._SCUS-97105 (1.10).iso" "notes.txt"; do
    head -c 4096 /dev/zero >"$games/$f"
done
cat >"$TMP/config.sh" <<EOF
GAMES_DIR="$games"
PS2FPKG_BIN="$FIXTURES/fake_ps2fpkg.sh"
STATE_DIR="$state"
WORK_DIR="$TMP/work"
TITLE_DB="$FIXTURES/title_db.csv"
TITLE_DB_URL=""
EOF
export FAKE_PS2FPKG_LOG="$TMP/fake.log"
run() { "$ROOT/ps2ps4" --config "$TMP/config.sh" --no-color "$@" >"$TMP/stdout" 2>"$TMP/stderr"; }

run convert --local "$out"
assert_eq "exit 1 when an item fails" "1" "$?"
assert_eq "built PKGs" "UP9000-NOID00000_00-NOID000000000001.pkg${NL}UP9000-SCUS97105_00-SCUS971050000001.pkg${NL}UP9000-SLUS20062_00-SLUS200620000001.pkg" \
    "$(ls "$out")"
assert_eq "done log" "No Serial Here${NL}SCUS-97105 (1.10)${NL}SLUS_200.62.GTA3" "$(cat "$state/completed.txt")"
assert_eq "failure recorded as convert" "SLES-12345 BROKEN	convert" "$(cut -f2,3 "$state/failed.tsv")"
assert_true "title from DB passed to ps2fpkg" grep -q "title=Fantavision" "$TMP/fake.log"
assert_true "no -t when title unknown" grep -q "No Serial Here.iso title=$" "$TMP/fake.log"
assert_false "AppleDouble files ignored" grep -q '\._' "$TMP/fake.log"
assert_false "blocklisted disc not converted" grep -q PBPX "$TMP/fake.log"
assert_true "summary counts blocklisted" grep -q "Blocklisted     : 1" "$TMP/stdout"
assert_false "work dir cleaned up" test -e "$TMP/work/in"
assert_false "lock released" test -e "$state/convert.lock"

: >"$TMP/fake.log"
run convert --local "$out" --dry-run
assert_eq "dry run exits 0" "0" "$?"
assert_true "dry run lists remaining" grep -q "would process 1 disc image" "$TMP/stdout"
assert_false "dry run converts nothing" test -s "$TMP/fake.log"

head -c 4096 /dev/zero >"$games/SLUS-20001.iso"
run convert --local "$out" --limit 1
assert_eq "retry of failed game goes last" "SLUS-20001" "$(tail -n 1 "$state/completed.txt")"

run status
assert_true "status shows remaining" grep -q "remaining     : 1" "$TMP/stdout"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
