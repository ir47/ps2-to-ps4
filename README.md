# ps2-to-ps4

[![CI](https://github.com/ir47/ps2-to-ps4/actions/workflows/ci.yml/badge.svg)](https://github.com/ir47/ps2-to-ps4/actions/workflows/ci.yml)

Batch-convert a PS2 disc image collection into PS4 fake PKGs and stage them
on a jailbroken console over FTP — unattended, resumable, and safe to re-run.

```text
$ ./ps2ps4 convert
==> Checking which games are already installed on the PS4
    214 apps installed on the PS4; 10 newly marked as done
==> 1650 disc images | 546 to process | 1092 done | 12 blocklisted
    Target: PS4 192.168.0.50:2121/data/pkg
==> [1/546] Fantavision (SCUS-97105)
    Copying 100%
    Converting to PKG (with cover art)...
    Uploading 1.8 GB to /data/pkg...
######################################################## 100.0%
  ✓ Staged in 23s (~81.1 MB/s): UP9000-SCUS97105_00-SCUS971050000001.pkg
```

`ps2ps4` is built on **[easy-ps2-fpkg](https://github.com/spiral009/easy-ps2-fpkg)
by [spiral009](https://github.com/spiral009)**. Its `ps2fpkg` binary does all
the actual ISO → PKG conversion, emulator setup and cover art. This project
is a batch wrapper around it that adds the parts you need for a large
collection:

- **Idempotent batches** — remembers what's done, and reads the PS4's own app
  registry so games installed any other way are skipped too.
- **Pipelined** — copies and converts the next game while the current one
  uploads, so the upload link is rarely idle.
- **Verified uploads** — checks the staged file's size on the console, removes
  partial uploads, and stops cleanly when the PS4's disk fills up.
- **Install-aware cleanup** — deletes staged PKGs once their install has
  *finished* (never mid-install), and flags installs that look stuck.
- **Failure tracking** — failures are logged by type (copy, convert, upload,
  verify, disk full); games that failed before are retried *after* new ones.
- **Icons** — retrofits box-art icons onto PS2 games installed without them.

> **Use your own legally dumped discs.** This project doesn't include or link
> to any games, firmware or copyrighted assets. Modifying a console may void
> its warranty; you do so at your own risk.

## How it works

```text
 NAS / disk             Mac / Linux                        PS4 (GoldHEN)
┌────────────┐  copy  ┌──────────────┐  FTP upload   ┌──────────────────────┐
│ *.iso      │ ─────▶ │ ps2fpkg      │ ────────────▶ │ /data/pkg/*.pkg      │
└────────────┘        │  → .pkg      │               │   │ Package Installer │
                      └──────────────┘               │   ▼  (manual)         │
                              ▲       FTP download   │ installed app        │
                              └───────────────────── │ /system_data/priv/   │
                                  app.db (installed) │   mms/app.db         │
                                                     └──────────────────────┘
```

Installing is the one manual step. Remote PKG Installer rejects ps2fpkg's
fake PKGs ("Unable to load system file object"), but the PS4's built-in
**Package Installer** accepts them, so `ps2ps4` stages PKGs in `/data/pkg`
and you install them from the console.

PS2 classics install outside the part of the filesystem GoldHEN's FTP server
exposes, so listing `/user/app` won't show them. Instead `ps2ps4` reads the
console's SQLite app registry (`/system_data/priv/mms/app.db`, table
`tbl_appbrowse_<local user id>`) to find out what's installed.

## Requirements

- macOS or Linux with `bash` (the stock macOS bash 3.2 is fine), `curl` and
  `sqlite3`
- The `ps2fpkg` command-line binary for your OS, from
  [easy-ps2-fpkg](https://github.com/spiral009/easy-ps2-fpkg). The macOS build
  is x86_64, so Apple Silicon Macs need Rosetta 2
- A PS4 running [GoldHEN](https://github.com/GoldHEN/GoldHEN) with its FTP
  server enabled (port 2121 by default)
- For `ps2ps4 icons`: `sips` (built into macOS) or ImageMagick

## Setup

```bash
git clone https://github.com/ir47/ps2-to-ps4.git
cd ps2-to-ps4
cp config.example.sh config.sh
```

Edit `config.sh` and set at least these three:

```bash
GAMES_DIR="/Volumes/NAS/PS2"          # your disc images
PS2FPKG_BIN="$HOME/bin/ps2fpkg-osx-x64"
PS4_IP="192.168.0.50"
```

Then check everything is wired up:

```bash
./ps2ps4 doctor
```

Optionally put it on your `PATH`:

```bash
ln -s "$PWD/ps2ps4" /usr/local/bin/ps2ps4
```

Disc images need the disc ID somewhere in the filename, e.g.
`SCUS-97105 (1.10).iso` or `SCUS_971.05.Fantavision.iso`. Files without one
still convert, but can't be matched against the PS4's installed games or get
a title from the database.

### Preparing the PS4

- **Settings → Power Save Settings**: disable Rest Mode for both general use
  and media playback. A sleeping PS4 drops the FTP connection mid-upload.
- **Turn off HDMI-CEC** (HDMI Device Link) so switching the TV off doesn't put
  the console to sleep.
- **Use a static IP.** A direct Ethernet cable between computer and console
  is fastest (80+ MB/s). If the console reboots and needs re-jailbreaking,
  check `ping <PS4_IP>` before starting a batch.

## Usage

```text
ps2ps4 [options] <command>

  convert   Convert unprocessed disc images and stage them on the PS4
  cleanup   Delete staged PKGs that are now installed
  icons     Retrofit box-art icons onto installed PS2 games
  status    Collection progress and what's staged on the PS4
  doctor    Check dependencies, configuration and connectivity
```

Every command accepts `--dry-run`, `--quiet`, `--verbose` and
`--config FILE`. Run `./ps2ps4 help` for the full list.

### The batch loop

```bash
./ps2ps4 convert            # stage as many PKGs as fit
# On the PS4: Package Installer → select each PKG → Install
./ps2ps4 cleanup            # delete the staged PKGs that are now installed
./ps2ps4 convert            # carry on where it left off
```

`/data/pkg` sits on the PS4's internal drive, and PKGs are about the size of
the disc image. Set `STAGING_LIMIT_GB` so `convert` stops before the drive
fills, rather than hitting "disk full" partway through an upload.

`cleanup` is safe to run while games are installing. A game appears in the
PS4's registry as soon as its install *starts*, so `cleanup` only deletes a
PKG once the registry shows the install completed. `status` and `cleanup` also
flag installs that have been unfinished for longer than `STUCK_INSTALL_HOURS`
(default 6). If the PS4 has finished its install queue, reinstall those from
Package Installer.

### Useful variations

```bash
./ps2ps4 convert --dry-run           # what would be processed, in order
./ps2ps4 convert --limit 20          # small batch
./ps2ps4 convert --shuffle           # random order
./ps2ps4 convert --quiet --log-file ~/ps2.log   # unattended
./ps2ps4 convert --local ~/pkgs      # just build PKGs (e.g. to install from USB)
./ps2ps4 icons --only SCUS-97105     # re-do one game's icon
```

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Some items failed (see the summary / `failed.tsv`) |
| 2 | Usage or configuration error |
| 3 | PS4 not reachable |
| 130 | Interrupted |

## State and logs

All state lives in `STATE_DIR` (default `~/.local/state/ps2ps4`):

| File | Contents |
|------|----------|
| `completed.txt` | One processed filename (without extension) per line. Delete a line to redo that game. |
| `failed.tsv` | `timestamp  filename  type  detail` for every failure |
| `logs/` | A timestamped log per run, including ps2fpkg's output |
| `ps2_title_db.csv` | Title database, downloaded on first run |
| `icons/` | Cover art cache for `ps2ps4 icons` |

Scratch files go in `WORK_DIR` and are removed after each game, and on
Ctrl+C. It needs about four times your largest disc image in free space (two games in flight, each with its disc image and PKG).
Put it on a local SSD rather than the NAS.

## Known issues

- **Bundle and demo discs don't install.** Disc IDs such as `PBPX`, `PCPX`,
  `PAPX` and `PDPX` build a valid-looking PKG, but Package Installer fails
  with "Unable to install" and deletes it. These are skipped by default (see
  `SKIP_PREFIXES` / `SKIP_IDS`).
- **No "install all".** Package Installer makes you install PKGs one at a
  time, and that can't be automated over FTP.
- **Icons are cached.** After `ps2ps4 icons`, restart the PS4 if the new
  icons don't show.
- **Some games don't run well** with the default emulator settings. Pass
  extra ps2fpkg options with `PS2FPKG_ARGS` (e.g. `--emu "Rogue v1"`). See
  ps2fpkg's `--help`.

## Development

```bash
tests/run.sh      # unit + end-to-end tests using a fake ps2fpkg; no PS4 needed
```

The scripts target bash 3.2 (the macOS default), so no associative arrays,
and empty arrays are expanded as `${a[@]+"${a[@]}"}` under `set -u`. Lint with
[ShellCheck](https://www.shellcheck.net/) (settings in `.shellcheckrc`):

```bash
shellcheck -x ps2ps4 lib/*.sh tests/run.sh
```

CI runs ShellCheck and the tests on macOS and Linux for every push and pull
request.

## Credits

This project wouldn't exist without
**[spiral009](https://github.com/spiral009)'s
[easy-ps2-fpkg](https://github.com/spiral009/easy-ps2-fpkg)**, the
self-contained `ps2fpkg` converter that does the real work. `ps2ps4` doesn't
include or redistribute it. Download it from spiral009's repository, and
report conversion or compatibility problems there.

Also thanks to:

- [VTSTech/PS2-OPL-CFG](https://github.com/VTSTech/PS2-OPL-CFG) — PS2 title database
- [xlenore/ps2-covers](https://github.com/xlenore/ps2-covers) — box art used by `ps2ps4 icons`
- [GoldHEN](https://github.com/GoldHEN/GoldHEN) — FTP server and homebrew enabler

## License

[MIT](LICENSE)
