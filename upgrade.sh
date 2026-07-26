#!/bin/bash
#
# Safely upgrade an existing swe-fail2ban install on a running Smoothwall
# Express 3.1 box: stop the service, back up jail.conf, fetch and install
# the release tarball, restart, and print jail status to verify.
#
# For a FRESH install (no existing swe-fail2ban), don't use this script -
# see the README's "New install" section instead.
#
# Usage (as root, on the Smoothwall box):
#   curl -fsSL -o upgrade.sh https://raw.githubusercontent.com/petter5/swe-fail2ban/master/upgrade.sh
#   less upgrade.sh   # read it before running anything as root
#   bash upgrade.sh

set -e

VERSION="0.0.6"
MOD_HOME="/var/smoothwall/mods-available/fail2ban"
RC="${MOD_HOME}/bin/rc.fail2ban"
JAILS="apache ssh-iptables"
BANNED_FILE="$(mktemp)"

echo "=== swe-fail2ban upgrade to ${VERSION} ==="

if [ "$(id -u)" != "0" ]; then
	echo "Must be run as root." >&2
	exit 1
fi

if [ ! -x "${RC}" ]; then
	echo "No existing install found at ${MOD_HOME} - this script is for" >&2
	echo "upgrades only. For a fresh install, see the README instead." >&2
	exit 1
fi

# Needed for the pre-stop status query below (bin/fail2ban-client isn't on
# PATH/PYTHONPATH until /etc/bashrc has been sourced in this shell).
source /etc/bashrc

# Capture whatever's actively banned on the OLD install before touching
# anything. The new CSV-based ban log (etc/fail2ban/action.d/csvlog.conf)
# only exists once 0.0.6 is running, so it has no record of bans that
# predate this upgrade - without this step those would simply vanish when
# the old service stops, restart or not.
echo "--- Capturing currently active bans (if any) ---"
for jail in ${JAILS}; do
	ips=$(fail2ban-client -c /etc/fail2ban -s /var/run/fail2ban.sock status "${jail}" 2>/dev/null \
		| sed -n 's/.*Banned IP list:[[:space:]]*//p')
	for ip in ${ips}; do
		echo "${jail} ${ip}" >> "${BANNED_FILE}"
	done
done
if [ -s "${BANNED_FILE}" ]; then
	echo "Found $(wc -l < "${BANNED_FILE}") active ban(s), will restore after the upgrade:"
	cat "${BANNED_FILE}"
else
	echo "No active bans found."
fi

echo "--- Stopping fail2ban ---"
"${RC}" stop

if [ -f /etc/fail2ban/jail.conf ]; then
	BACKUP="/root/jail.conf.bak-$(date +%Y%m%d%H%M%S)"
	echo "--- Backing up jail.conf to ${BACKUP} (only matters if you hand-edited it) ---"
	cp /etc/fail2ban/jail.conf "${BACKUP}"
fi

echo "--- Fetching ${VERSION} ---"
cd /tmp
rm -rf fail2ban fail2ban.tar.gz
curl -fsSL -o fail2ban.tar.gz "https://github.com/petter5/swe-fail2ban/releases/download/${VERSION}/swe-fail2ban-${VERSION}.tar.gz"
tar xzf fail2ban.tar.gz
mv "swe-fail2ban-${VERSION}" fail2ban
cd fail2ban

echo "--- Installing (enable-fail2ban) ---"
# enable-fail2ban asks a single y/n question ("install this mod to your
# smoothie?") - answer it non-interactively since this script only runs
# when there's already a confirmed existing install to upgrade in place.
echo y | perl enable-fail2ban

echo "--- Starting fail2ban ---"
source /etc/bashrc
"${RC}" start

if [ -s "${BANNED_FILE}" ]; then
	echo "--- Re-applying bans captured before the upgrade ---"
	while read -r jail ip; do
		fail2ban-client -c /etc/fail2ban -s /var/run/fail2ban.sock set "${jail}" banip "${ip}" >/dev/null 2>&1 || true
	done < "${BANNED_FILE}"
fi
rm -f "${BANNED_FILE}"

echo "--- Status (verify both jails are listed, and any bans above reappear here) ---"
"${RC}" status
fail2ban-client -c /etc/fail2ban -s /var/run/fail2ban.sock status apache || true
fail2ban-client -c /etc/fail2ban -s /var/run/fail2ban.sock status ssh-iptables || true

echo "=== Done ==="
