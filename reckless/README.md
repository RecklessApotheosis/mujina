# reckless/: building and installing this fork on a Nano 3S

This branch is IxTech's Nano 3S firmware (`nano3s/v6`) plus Reckless Systems
changes. This directory holds the scripts that fetch its inputs, build it on a
leased Dendrite build lane, and install it on a unit over SSH. Each script's
header says exactly what it does; this page is the order to run them in.

Rules this follows (Ronald's): builds run only on a checked-out build lane,
never on the machine you type on; firmware goes on by SSH, with USB only for
a bricked unit; every install has a hashed rollback; dependencies are pinned,
at least 14 days old, and each new fetch needs his go.

## What gets built, and from what

| Output | Built from |
|---|---|
| `fb_button` | `fb_hijack/` (button: cycles the display pages) |
| `nano3s_ui` | `nano3s_ui/` (LVGL display; pages incl. `reckless`) |
| `mujina-minerd` | `mujina-miner/` with `--features nano3s`; it embeds the two above |
| `reckless.rgb565` | `assets/` (the logo page image; see `assets/README.md`) |

Not built here: `rtos_core.elf` (the RTOS on the second core) and
`mujina_display_startup.sh` stay as the unit has them from IxTech's release.

Native inputs, fetched by `fetch-deps.sh` at pinned versions:
- `libudev-zero` 1.0.5, source, built into a static riscv64 `libudev.a` in the job.
- Canaan `libipcmsg.a` from k230_sdk v2.0: the one prebuilt input; Canaan
  publishes no source for it. The kernel side it talks to is public.

## 1. Bring in upstream

```
git fetch ixtech nano3s/v6 'refs/tags/v5.0.*:refs/tags/v5.0.*'
git merge ixtech/nano3s/v6
```
Expect conflicts in `fb_hijack/src/fb_button.rs` (page cycle) and
`nano3s_ui/c_driver/driver.c` (page enum and raw-image pages) whenever IxTech
adds a page. Keep his pages and put `reckless` back after his last one; then
update `CYCLE` in `fb_button.rs`'s tests. Commit; `remote-build.sh` refuses a
dirty tree.

## 2. Fetch inputs (network; converges)

```
reckless/fetch-deps.sh /home/ronald/projects/mujina-nano3s/working/deps/nano3s
```
A second run prints `unchanged` for everything. A changed pin is a new fetch
and needs Ronald's go.

## 3. Build on a lane (no network in the job)

```
reckless/remote-build.sh OUT_DIR DEPS_DIR --miner
```
It takes the first free `supercomplex-build*` lane (only those carry the
riscv64 Rust image), runs the display unit tests, builds everything, pulls the
binaries into `OUT_DIR/bin` with `SHA256SUMS` checked, and releases the lane.
`OUT_DIR/build-record.txt` names the commit, source hash, lane, image id and
lease. Without `--miner` it builds only the display programs (about 20 s).

Then put the miner under its device name next to the display programs:
```
mkdir -p OUT_DIR/deploy && cp OUT_DIR/bin/fb_button OUT_DIR/bin/nano3s_ui OUT_DIR/deploy/
cp OUT_DIR/bin/mujina-minerd.stripped OUT_DIR/deploy/mujina-minerd
```

## 4. Save the rollback set first

Copy the unit's current `/data/mujina-minerd`, `/data/nano3s_ui`,
`/mntapp/release/linux/app/fb_button` and `/data/reckless.rgb565` into a
directory under `working/rollback/`, with a `SHA256SUMS`.

## 5. Install

```
NANO_SSH="ssh -o BatchMode=yes -o UserKnownHostsFile=<known_hosts> root@<unit>" \
    reckless/install.sh OUT_DIR/deploy [reckless/assets/reckless.rgb565]
```
Display programs go first, the miner last. A changed display program is
restarted in place. **A changed miner reboots the unit**: a restarted miner
cannot reconnect to `rtos_core` until the next boot (measured 2026-11-11), so
the script reboots and waits for the miner's IPC connection. Count about three
minutes without hashing.

A second run prints `unchanged` for every file. Rollback is the same command
with the rollback directory.

## 6. Check

- `curl http://<unit>/api/v0/system`: the version field.
- `/data/mujina-minerd.log`: `ipc_shim] connected`, `resumed profile ...`,
  then `First share accepted` (a share every few minutes at about 3.4 TH/s).
- The display boots to the `reckless` page; the button walks
  dials, ASIC table, tuner, IP, pizza, plasma, reckless.
- Read a page back: write its name to `/mntapp/release/linux/app/fb_page`,
  then `head -c 115200 /dev/fb0 | sha256sum` equals the image's hash for the
  static pages (`reckless`, `pizza`).
