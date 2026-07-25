# swe-fail2ban

Adds fail2ban 1.0.2 to Smoothwall Express 3.1 (Update 12 + Update 13).

This is a fork of [d4t4king/swe-fail2ban](https://github.com/d4t4king/swe-fail2ban)
with bug fixes for [issue #1](https://github.com/d4t4king/swe-fail2ban/issues/1),
plus an upgrade of the bundled fail2ban from the **0.10.0a2 alpha (2016)** this
mod originally shipped to **1.0.2 (2022)**, the last fail2ban release that still
supports Python 2.7 — which is all Smoothwall Express 3.1 has available
(fail2ban 1.1.0+ requires Python 3.5+).

## fail2ban 0.10.0a2 → 1.0.2 upgrade

The entire vendored `lib/python2.7/fail2ban` library, the `bin/fail2ban-*`
launcher scripts, and the stock `etc/fail2ban/{action.d,filter.d,jail.conf,
paths-*.conf,fail2ban.conf}` config tree were replaced wholesale with
upstream's 1.0.2 release. Smoothwall-specific pieces were kept or re-applied
on top:

- `bin/rc.fail2ban`, `bin/config_fail2ban`, `bin/uninstall_fail2ban` — untouched
  (Smoothwall-specific, not part of upstream).
- `etc/fail2ban/jail.d/httpd.conf` and `jail.d/sshd.conf` (our `apache` and
  `ssh-iptables` jails) — untouched; they're independent override files, not
  edits to `jail.conf` itself.
- `fail2ban.conf`'s `dbfile` — re-pointed at
  `/var/smoothwall/mods/fail2ban/var/lib/fail2ban/fail2ban.sqlite3` (upstream
  default changed to `/var/lib/fail2ban/...`, which doesn't exist here).
- Bug 2's `setDatabase()` patch (below) — re-applied; the crash it fixes is
  still present, unchanged, in 1.0.2's `server.py`.
- Bug 1's apache-auth patch — **dropped**. fail2ban 1.0.2 shipped a rewritten
  `configparserinc.py` (cross-section/include interpolation, `known/` section
  fallback) that appears to fix the exact class of bug Bug 1 worked around.
  I couldn't get a live functional test running in this sandbox (no Python
  2.7 available, and fail2ban's own Python 3 port has unrelated gaps), so
  **this is the top thing to verify before relying on it** — run
  `fail2ban-regex /var/log/httpd*/*error.log filter.d/apache-auth.conf` on a
  real box (or VM) and confirm it reports matched failures, not zero.
- **Caught in review, not from the original issue:** upstream's new
  `jail.conf` ships `ignoreip` commented out by default
  (`#ignoreip = 127.0.0.1/8 ::1`), but `enable-fail2ban`'s installer only
  matches lines starting with `ignoreip` (no `#`) to append the GREEN network.
  Silently broken auto-whitelisting otherwise. Re-uncommented in our shipped
  `jail.conf`.

## What's fixed in this fork

### Bug 1 — apache-auth filter silent failure (fail2ban 0.10.0a2 only)

`apache-auth.conf` uses `%(_apache_error_client)s` which is defined in
`apache-common.conf` via `[INCLUDES]`. In fail2ban 0.10.0a2, variables defined
in `[DEFAULT]` of an included file are not interpolated into `[Definition]`
failregex of the including file — so every failregex silently matches nothing.

**Fix (0.10.0a2 only, superseded by the 1.0.2 upgrade above):**
`_apache_error_client` was also defined in `[DEFAULT]` of `apache-auth.conf`
itself, same value as `apache-common.conf`. Kept here for history since the
upgrade removed the workaround rather than the bug report.

### Bug 2 — `fail2ban-client reload <jail>` crash

Reloading a jail with `fail2ban-client reload apache` crashed with:

```
NOK: ('Cannot change database when there are jails present',)
```

During reload, fail2ban replays the full config stream (including `setDatabase`)
while jails are still running. `server.py::setDatabase()` raised `RuntimeError`
whenever jails were present and the DB wasn't yet initialised.

**Fix:** `setDatabase()` now skips the error if `self.__reload_state` is
non-empty (a reload is in progress). The DB path doesn't change on reload,
so returning early is safe.

### Bug 3 — `DETAILS` shows literal `${MOD_NAME}`

Smoothwall reads `DETAILS` as plain key=value text, not via bash. The line
`MOD_LONG_NAME="[3.1] ${MOD_NAME} "` displayed literally in the mod browser.

**Fix:** Hardcoded to `MOD_LONG_NAME="[3.1] fail2ban"`.

### Bug 4 — `rc.fail2ban` and `config_fail2ban` wrong binary paths

`rc.fail2ban` referenced `usr/bin/fail2ban` (doesn't exist) using the old
fail2ban **0.8.x** API (`-c FILE` / `-k`). This prevented fail2ban from
starting or stopping via the management scripts.

`config_fail2ban` referenced `usr/bin/fail2ban-client` and
`etc/rc.d/rc.fail2ban`, neither of which exist after install.

**Fix:**
- `rc.fail2ban` updated to use `bin/fail2ban-client` with 0.10.x API
  (`start` / `stop`) and exports `PYTHONPATH` so the bundled library is
  found when called from init scripts (before `/etc/bashrc` is sourced).
- `config_fail2ban` corrected to `bin/fail2ban-client` and `bin/rc.fail2ban`.

### Bug 5 — banned IPs did not survive a restart

`fail2ban.conf` points `dbfile` at
`.../mods-available/fail2ban/var/lib/fail2ban/fail2ban.sqlite3` so bans persist
across restarts, but that directory was never created by the install or
management scripts — only documented as a manual one-time `mkdir` step.
fail2ban's `sqlite3.connect()` doesn't create missing parent directories, so
whenever that directory was absent (fresh install, or any process that
recreated the mod directory), the server silently started with **no**
persistent database, and every restart (`rc.fail2ban restart`,
`config_fail2ban`, or a plain `stop`/`start`) lost the ban list even though
the ban-restore logic itself (`Jail.restoreCurrentBans()`) works correctly.

**Fix:** `rc.fail2ban` now creates the database directory itself (idempotent
`mkdir -p`) before every start, so persistence no longer depends on a manual
setup step being remembered or surviving a mod reinstall.

## Untested on real hardware

Everything above was verified by static review (source diffing against
upstream, code tracing, Python syntax-checking) — there is no Smoothwall
Express box or VM in this environment to actually install and run the mod
on. Before publishing, install on a real Smoothwall Express 3.1 SP6 box or
VM and confirm: the service starts, both jails (`apache`, `ssh-iptables`)
show up in `fail2ban-client status`, the apache-auth filter actually matches
failures (see the note above), bans survive `rc.fail2ban restart`, and the
GREEN network shows up in `fail2ban-client get apache ignoreip`.

## Installation (Smoothwall Express 3.1, Update 12 + Update 13)

### New install

```sh
# On the Smoothwall box, as root:
cd /tmp
git clone https://github.com/petter5/swe-fail2ban.git fail2ban
cd fail2ban
perl enable-fail2ban
```

`enable-fail2ban` copies the mod into `/var/smoothwall/mods-available/fail2ban`,
whitelists the GREEN network in `jail.conf`, adds `PYTHONPATH` to `/etc/bashrc`,
and symlinks the mod into `/var/smoothwall/mods` and `/etc/fail2ban`. Then
start it:

```sh
touch /var/smoothwall/mods-available/fail2ban/config
source /etc/bashrc
fail2ban-client -c /etc/fail2ban start
```

### Upgrading an existing install (e.g. from 0.0.3 / fail2ban 0.10.0a2)

`enable-fail2ban` is safe to re-run over an existing install — it overwrites
the mod's files in place and is idempotent (re-running it doesn't duplicate
the `/etc/bashrc` addition or double-append the GREEN network). It does
**not** touch the persistent ban database (`var/lib/fail2ban/`, not part of
this repo) or anything under `jail.d/`, so bans and the two Smoothwall jails
survive an upgrade untouched. fail2ban's own database migrates its schema
automatically on first start with the new library — no manual DB step needed.

```sh
# On the Smoothwall box, as root:

# 1. Stop the running service first — files get overwritten under the
#    running process, and the new code only takes effect after a restart.
/var/smoothwall/mods-available/fail2ban/bin/rc.fail2ban stop

# 2. If you hand-edited etc/fail2ban/jail.conf directly (rather than adding
#    a file under jail.d/), back it up now — the upgrade overwrites it with
#    the new upstream jail.conf (GREEN re-whitelisting included). Custom
#    jail.d/*.conf files are untouched and don't need backing up.
cp /etc/fail2ban/jail.conf /root/jail.conf.bak-0.0.3   # optional but recommended

# 3. Fetch and re-run the installer, same as a new install:
cd /tmp
rm -rf fail2ban
git clone https://github.com/petter5/swe-fail2ban.git fail2ban
cd fail2ban
perl enable-fail2ban

# 4. Start it back up:
source /etc/bashrc
/var/smoothwall/mods-available/fail2ban/bin/rc.fail2ban start

# 5. Verify:
fail2ban-client -c /etc/fail2ban status
fail2ban-client -c /etc/fail2ban status apache
fail2ban-client -c /etc/fail2ban status ssh-iptables
```

Confirm both jails are listed, previously-banned IPs still show up under
`status <jail>`, and the mod browser shows version `0.0.4`.

## Jails configured

| Jail | Port | Log |
|------|------|-----|
| `apache` | 81, 441 | `/var/log/httpd*/*error.log` |
| `ssh-iptables` | 222 | `/var/log/messages` |

GREEN network is automatically whitelisted during installation.

## Original

By Charlie Heselton (dataking / d4t4king). See original
[README](https://github.com/d4t4king/swe-fail2ban) and
[LICENSE](LICENSE) for details.
