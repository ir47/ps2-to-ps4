# ps2ps4 configuration
#
# Copy this file to one of:
#   ./config.sh                    (next to the ps2ps4 script; git-ignored)
#   ~/.config/ps2ps4/config.sh
# or point at it with `ps2ps4 --config FILE` / PS2PS4_CONFIG=FILE.
#
# It's sourced as bash, so quote paths and use (...) for lists.
# Anything left commented out uses the default shown.

# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------

# Folder containing your PS2 disc images. The disc ID should appear in each
# filename, e.g. "SCUS-97105 (1.10).iso" or "SCUS_971.05.Fantavision.iso".
GAMES_DIR="/Volumes/NAS/PS2"

# Path to the ps2fpkg command-line converter for your OS, from spiral009's
# easy-ps2-fpkg: https://github.com/spiral009/easy-ps2-fpkg
PS2FPKG_BIN="$HOME/bin/ps2fpkg-osx-x64"

# PS4 running GoldHEN with its FTP server enabled. Find its address in
# Settings → Network → View Connection Status.
PS4_IP="192.168.0.50"

# ---------------------------------------------------------------------------
# PS4 connection
# ---------------------------------------------------------------------------

# PS4_FTP_PORT=2121
# PS4_FTP_USER=""                 # GoldHEN's FTP server doesn't need a login
# PS4_FTP_PASS=""
# PS4_PKG_DIR="/data/pkg"         # where Package Installer looks for PKGs
# FTP_CONNECT_TIMEOUT=5

# Stop before uploading once this many GB are staged in PS4_PKG_DIR
# (0 = no limit; uploads stop when the PS4's disk is full instead).
# STAGING_LIMIT_GB=400

# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------

# File types to pick up. ps2fpkg also accepts archives holding a single ISO.
# INPUT_EXTENSIONS=(iso)
# INPUT_EXTENSIONS=(iso 7z zip rar)

# Fetch official box art for the home-screen icon/background (1 = on).
# AUTO_ART=1

# Extra arguments passed to every ps2fpkg call, e.g. a different emulator.
# PS2FPKG_ARGS=(--emu "Rogue v1")

# Semicolon-delimited "GameID;Name;..." database used for on-screen titles.
# Set TITLE_DB_URL="" to let ps2fpkg choose titles itself.
# TITLE_DB_URL="https://raw.githubusercontent.com/VTSTech/PS2-OPL-CFG/master/test/PS2-GAMEID-TITLE-MASTER.csv"

# Disc ID prefixes / IDs to skip. Bundle and demo discs (PBPX etc.) build a
# PKG that Package Installer rejects with "Unable to install".
# SKIP_PREFIXES=(PBPX PCPX PAPX PDPX)
# SKIP_IDS=(PBPX-95517)

# ---------------------------------------------------------------------------
# Batch behaviour
# ---------------------------------------------------------------------------

# Copy the next disc image while the current one converts/uploads (1 = on).
# PREFETCH=1

# "sorted" (alphabetical) or "shuffle".
# ORDER="sorted"

# Try disc images that failed on a previous run after the untried ones.
# RETRY_FAILED_LAST=1

# Give up on the batch after this many network failures in a row
# (usually means the PS4 went to sleep or lost its jailbreak).
# MAX_NETWORK_FAILURES=3

# ---------------------------------------------------------------------------
# Local paths
# ---------------------------------------------------------------------------

# Progress, failure log, run logs, title DB and icon cache.
# STATE_DIR="$HOME/.local/state/ps2ps4"
# DONE_LOG="$STATE_DIR/completed.txt"   # one processed filename per line
# FAILED_LOG="$STATE_DIR/failed.tsv"
# LOG_DIR="$STATE_DIR/logs"

# Scratch space for the local ISO copy and built PKG. Needs roughly 3x the
# size of your largest disc image free. Use a local SSD, not the NAS.
# WORK_DIR="$HOME/tmp/ps2ps4-work"

# ---------------------------------------------------------------------------
# Icons (`ps2ps4 icons`)
# ---------------------------------------------------------------------------

# Where to download box art from, tried in order. {ID} becomes the disc ID
# (e.g. SCUS-97105). Images are letterboxed to 512x512 PNG.
# ICON_URL_TEMPLATES=("https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/{ID}.jpg")
