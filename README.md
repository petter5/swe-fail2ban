# swe-fail2ban

Adds fail2ban 0.10.0a2 to Smoothwall Express 3.1 (Update 12 + Update 13).

This is a fork of [d4t4king/swe-fail2ban](https://github.com/d4t4king/swe-fail2ban)
with bug fixes for [issue #1](https://github.com/d4t4king/swe-fail2ban/issues/1).

## What's fixed in this fork

### Bug 1 — apache-auth filter silent failure

`apache-auth.conf` uses `%(_apache_error_client)s` which is defined in
`apache-common.conf` via `[INCLUDES]`. In fail2ban 0.10.0a2, variables defined
in `[DEFAULT]` of an included file are not interpolated into `[Definition]`
failregex of the including file — so every failregex silently matches nothing.

**Fix:** `_apache_error_client` is now also defined in `[DEFAULT]` of
`apache-auth.conf` itself. Same value as `apache-common.conf`.

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

## Installation (Smoothwall Express 3.1, Update 12 + Update 13)

```sh
# On the Smoothwall box, as root:
cd /tmp
git clone https://github.com/petter5/swe-fail2ban.git fail2ban
cd fail2ban
perl enable-fail2ban
```

After installation, create the SQLite database directory and start:

```sh
mkdir -p /var/smoothwall/mods/fail2ban/var/lib/fail2ban
touch /var/smoothwall/mods-available/fail2ban/config
source /etc/bashrc
fail2ban-client -c /etc/fail2ban start
```

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
