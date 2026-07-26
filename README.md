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
  fallback) that fixes the exact class of bug Bug 1 worked around — confirmed
  on a real VM (see "Tested on a real VM install" below):
  `fail2ban-regex` against a sample Apache auth-failure log line through
  `filter.d/apache-auth.conf` reports 1 matched, 0 missed.
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

**Update — the directory was never the whole story.** Testing on a real VM
turned up something bigger: Smoothwall Express's bundled Python 2.7.2 has
the `sqlite3` package's `.py` files but not the compiled `_sqlite3`
extension (the C binding — `libsqlite3.so` itself **is** present and used
by other programs, just never wired up to Python). `import sqlite3` fails
with `ImportError: No module named _sqlite3`, so fail2ban's SQLite-backed
ban database can't work here **at all**, directory or not. It's not fatal —
fail2ban logs the error and keeps running, jails and live banning both work
fine — but bans never survive any restart, full stop.

There's no compiler on the box either (confirmed: no `gcc`, no `cc`), so
building a matching `_sqlite3.so` isn't a config change, it's a whole
separate cross-compilation project (e.g. using the SP6 dev ISO). Given
that, worked around it instead with a plain CSV file:

- `action.d/csvlog.conf` — a new action chained onto the `apache` and
  `ssh-iptables` jails (`etc/fail2ban/jail.d/{httpd,sshd}.conf`) that
  appends `ip,jail,bantime,timestamp` to
  `var/lib/fail2ban/bans.csv` on every ban.
- `rc.fail2ban`'s new `restore_bans()`, called after every successful
  start: reads that CSV and re-applies (`fail2ban-client set <jail> banip
  <ip>`) any entry whose `timestamp + bantime` hasn't passed yet, pruning
  expired ones as it rewrites the file.

Two bugs found and fixed getting this actually working, both confirmed via
a real ban → restart → check-iptables cycle on the test VM:
- fail2ban's `<time>` tag is a Python **float** (`"1785012240.48"`), which
  bash's `$(( ))` can't do arithmetic on — crashed the restore loop, and
  because the `mv` of the rewritten file back over `bans.csv` ran
  unconditionally regardless, the first restart after any ban wiped the
  CSV instead of restoring from it. Fixed by stripping everything from the
  `.` onward before doing arithmetic, plus a digits-only guard so a future
  bad line gets skipped rather than repeating the same failure.
- fail2ban calls `actionunban` for every live ticket whenever a jail
  *stops* (not just for a real admin-initiated unban), so an
  actionunban that stripped the CSV row erased every entry on every
  single `rc.fail2ban stop` — before the next start's `restore_bans()`
  ever ran. Removed the CSV-stripping actionunban entirely; expiry-based
  pruning in `restore_bans()` is what keeps the file bounded instead. The
  tradeoff, documented in `csvlog.conf`: an IP an admin unbans early stays
  in the CSV until its original bantime would have expired, and comes back
  after the next restart.

Confirmed end-to-end on the test VM: ban an IP → `bans.csv` gets the row →
`rc.fail2ban stop` (row survives) → `rc.fail2ban start` → `fail2ban-client
status apache` shows it banned again → `iptables -L f2b-apache -n` shows
the real `REJECT` rule back in place, not just fail2ban's own bookkeeping.

### Bug 6 — `fail2ban-client start` and `rc.fail2ban` use different sockets

fail2ban 1.0.2 changed its default `socket`/`pidfile` to
`/var/run/fail2ban/fail2ban.sock` and `.../fail2ban.pid` (a subdirectory).
`rc.fail2ban` has always passed its own explicit `-s`/`-p` flags
(`/var/run/fail2ban.sock`, `/var/run/fail2ban.pid`, no subdirectory) and
still does. Starting the server with a bare `fail2ban-client -c /etc/fail2ban
start` (as the install docs used to say) uses the new default instead — a
**different** socket than `rc.fail2ban` uses. Mixing the two (e.g. starting
via the bare command, then later running `rc.fail2ban stop`/`restart` as the
upgrade instructions do) doesn't stop the first process at all: `rc.fail2ban`
looks for its own pidfile, doesn't find it, and starts a **second**,
orphaned `fail2ban-server`, running alongside the first with its own
separate ban database. Confirmed on a real VM: this produced two live
`fail2ban-server` processes watching the same logs.

**Fix:** `fail2ban.conf`'s `socket`/`pidfile` defaults changed back to
`/var/run/fail2ban.sock` / `/var/run/fail2ban.pid`, matching what
`rc.fail2ban` has always passed explicitly — so a bare `fail2ban-client
start` and `rc.fail2ban start` now agree by default. Docs below still use
`rc.fail2ban` throughout regardless, since it's also the only thing that
gets Bug 5's directory-creation fix. If you ever do end up with two
processes anyway (`ps aux | grep fail2ban-server`), kill the one whose
`-s`/`-p` paths don't match `/var/run/fail2ban.sock` / `/var/run/fail2ban.pid`.

### Bug 7 — `rc.fail2ban` silently no-ops without a dead marker file

`rc.fail2ban` gated every single command (`start`, `stop`, `status`, all of
it) on `${F2B_HOME}/config` existing, with the comment "config file is
written by `config_fail2ban`" — but `config_fail2ban` can't actually do that
in this fork: its own required template, `config.default`, doesn't exist
anywhere in this repo, so it fails immediately (`"No default
configuration-file found, exiting..."`, exit `-1`) before ever reaching the
line that would write `config`. Nothing else reads that file's contents
either — the jail configs hardcode their own `maxretry`/`findtime`/`bantime`
directly. The only way it ever existed was the manual one-time `touch` this
README used to tell "New install" users to run.

Found on a real production box, not the test VM: after a stale
`fail2ban-server` process (left over from before Bug 6's socket fix landed)
was killed and the mod reinstalled via `upgrade.sh`, that touch-once file
was gone. `rc.fail2ban start` then returned exit 0 with **no output and no
process** — indistinguishable from success unless you check `ps` — silently
leaving the box unprotected. The 7 IPs banned on `ssh-iptables` at the time
were lost from the running server's state in the process; recovered by
grepping `[jail] Ban`/`Unban` pairs out of the pre-Bug-6 file-based
`fail2ban.log` for entries with no matching `Unban`, then re-applied with
`fail2ban-client set ssh-iptables banip <ip>`.

**Fix:** removed the check entirely. `rc.fail2ban` no longer depends on any
file besides what `enable-fail2ban` itself creates. The `touch
.../config` step is no longer part of installation (removed from the docs
below).

## Tested on a real VM install

Installed and verified end-to-end on a Smoothwall Express 3.1 SP6 + Update 13
QEMU/KVM VM (fresh install, not an upgrade from 0.0.3): `enable-fail2ban`
completes, both jails (`apache`, `ssh-iptables`) come up under
`rc.fail2ban status` / `fail2ban-client status`, and — the one thing that
couldn't be checked without a real Python 2.7 runtime — `fail2ban-regex`
against a sample Apache auth-failure log line through `filter.d/apache-auth.conf`
reports **1 matched, 0 missed**, confirming upstream's rewritten
config-include interpolation does fix the class of bug Bug 1 used to work
around. Bug 6 above was found during this same test.

Also confirmed end-to-end on the same VM: a real ban (`fail2ban-client set
apache banip <ip>`) surviving a full `rc.fail2ban stop` + `start` cycle,
right down to the actual `iptables -L f2b-apache -n` rule reappearing —
see Bug 5's update above for what that took.

Not yet tested: the upgrade-from-0.0.3 path itself (this VM was a fresh
install). Bug 7 (above) was found and fixed directly on a real production
box, not this VM — not yet re-verified here.

## Smoothwall admin GUI integration

`enable-fail2ban` uses Smoothwall's own drop-in mod extension points to make
fail2ban activity visible in the stock admin UI, rather than CLI-only:

- **Logs → system tab**: `fail2ban.conf`'s `logtarget` is set to `SYSLOG`
  (instead of its own file), so ban/unban/jail-start events land in
  `/var/log/messages` like everything else and show up in the existing
  "system" log tab automatically — no new tab, no core file changes.
  Confirmed on the test VM: `fail2ban.jail[PID]: INFO Jail 'apache' started`
  etc. appear there right after `rc.fail2ban start`.
- **Control → Services status**: registered via
  `usr/lib/smoothwall/services/fail2ban` (Smoothwall's documented
  "SmoothInstall" mod convention — `status.cgi` globs
  `/var/smoothwall/mods/*/usr/lib/smoothwall/services/*`, one file per
  service, contents `name,release`). This part is only **partially working**:
  the file is found and would drive the PID-file-based running/uptime check
  correctly (it matches `rc.fail2ban`'s own `/var/run/fail2ban.pid`), but the
  display name goes through `status.cgi`'s `$tr{$name}` translation-table
  lookup, and a matching mod-provided `usr/lib/smoothwall/langs/en.pl`
  (confirmed to actually get `require`'d — a marker-file test proved it runs)
  still doesn't make `$tr{fail2ban}` resolve on the test VM. Net effect: the
  row doesn't render with a usable name yet. Not resolved — likely a Perl
  package/scope subtlety in `header.pm` between where `%tr` is populated and
  where `status.cgi` later reads it. If you want to pick this up: the file
  `usr/lib/smoothwall/services/fail2ban` and
  `usr/lib/smoothwall/langs/en.pl` are both already in place in this repo;
  the open question is purely why the language-file merge doesn't stick.

## Installation (Smoothwall Express 3.1, Update 12 + Update 13)

### New install

Smoothwall Express doesn't ship `git`, only `perl` and `curl` — `git clone`
will fail with "no git in ...". Fetch a release tarball instead:

```sh
# On the Smoothwall box, as root:
cd /tmp
curl -sSL -o fail2ban.tar.gz https://github.com/petter5/swe-fail2ban/releases/download/0.0.7/swe-fail2ban-0.0.7.tar.gz
tar xzf fail2ban.tar.gz
mv swe-fail2ban-0.0.7 fail2ban
cd fail2ban
perl enable-fail2ban
```

(If you're doing this from a machine that *does* have git, `git clone
https://github.com/petter5/swe-fail2ban.git fail2ban` into `/tmp/fail2ban`
works identically — `enable-fail2ban` just needs the directory to be named
`fail2ban` under `/tmp`.)

`enable-fail2ban` copies the mod into `/var/smoothwall/mods-available/fail2ban`,
whitelists the GREEN network in `jail.conf`, adds `PYTHONPATH` to `/etc/bashrc`,
and symlinks the mod into `/var/smoothwall/mods` and `/etc/fail2ban`. Then
start it:

```sh
source /etc/bashrc
/var/smoothwall/mods-available/fail2ban/bin/rc.fail2ban start
```

Use `rc.fail2ban`, not a bare `fail2ban-client start` — see Bug 6 below for
why mixing the two leaves an orphaned second process running.

### Upgrading an existing install (e.g. from 0.0.3 / fail2ban 0.10.0a2)

For a production box, `upgrade.sh` does all of the steps below in one
script (stop, back up `jail.conf`, fetch, install, start, verify):

```sh
curl -fsSL -o upgrade.sh https://raw.githubusercontent.com/petter5/swe-fail2ban/master/upgrade.sh
less upgrade.sh   # read it before running anything as root
bash upgrade.sh
```

Or do it by hand:

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

# 3. Fetch and re-run the installer, same as a new install (no git on
#    Smoothwall Express — see "New install" above):
cd /tmp
rm -rf fail2ban fail2ban.tar.gz
curl -sSL -o fail2ban.tar.gz https://github.com/petter5/swe-fail2ban/releases/download/0.0.7/swe-fail2ban-0.0.7.tar.gz
tar xzf fail2ban.tar.gz
mv swe-fail2ban-0.0.7 fail2ban
cd fail2ban
perl enable-fail2ban

# 4. Start it back up:
source /etc/bashrc
/var/smoothwall/mods-available/fail2ban/bin/rc.fail2ban start

# 5. Verify:
/var/smoothwall/mods-available/fail2ban/bin/rc.fail2ban status
fail2ban-client -c /etc/fail2ban -s /var/run/fail2ban.sock status apache
fail2ban-client -c /etc/fail2ban -s /var/run/fail2ban.sock status ssh-iptables
```

Confirm both jails are listed, previously-banned IPs still show up under
`status <jail>`, and the mod browser shows version `0.0.7`.

## Jails configured

| Jail | Port | Log | maxretry |
|------|------|-----|----------|
| `apache` | 81, 441 | `/var/log/httpd*/*error.log` | 3 |
| `ssh-iptables` | 222 | `/var/log/messages` | 3 |

`maxretry` was tightened from the upstream default of 5 to 3 for both jails
in 0.0.7 to ban sooner after repeated auth failures.

GREEN network is automatically whitelisted during installation.

## Original

By Charlie Heselton (dataking / d4t4king). See original
[README](https://github.com/d4t4king/swe-fail2ban) and
[LICENSE](LICENSE) for details.
