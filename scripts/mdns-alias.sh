#!/usr/bin/env bash
# Publish extra mDNS hostnames (default: pi.local) for this NAS, so old Finder bookmarks keep working
# after a hostname change. Usage: sudo bash mdns-alias.sh [alias ...]
# Publishes both A and AAAA: with an A record only, macOS waits ~5 s for the AAAA lookup to time out.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
ALIASES=("${@:-pi}")
apt-get -o DPkg::Lock::Timeout=600 install -y avahi-utils >/dev/null   # waits for unattended-upgrades
cat > /usr/local/sbin/mdns-alias <<'SH'
#!/usr/bin/env bash
# Publish each alias.local -> eth0's current IPv4 and global IPv6; exit (systemd restarts) when they change.
addrs() {
  ip -4 -o addr show dev eth0 | awk '{split($4,a,"/"); print a[1]; exit}'
  ip -6 -o addr show dev eth0 scope global -temporary -deprecated | awk '{split($4,a,"/"); print a[1]; exit}'
}
cur=""
for i in $(seq 1 60); do cur=$(addrs); [[ -n $(echo "$cur" | head -1) ]] && break; sleep 1; done
[[ -n $cur ]] || exit 1
for a in "$@"; do while read -r ip; do [[ -n $ip ]] && avahi-publish -a -R "$a.local" "$ip" & done <<< "$cur"; done
while sleep 30; do [[ $(addrs) == "$cur" ]] || { kill $(jobs -p) 2>/dev/null; exit 1; }; done
SH
chmod 755 /usr/local/sbin/mdns-alias
cat > /etc/systemd/system/mdns-alias.service <<UNIT
[Unit]
Description=Publish mDNS host aliases (${ALIASES[*]}) for the NAS
After=avahi-daemon.service network-online.target
Requires=avahi-daemon.service
[Service]
ExecStart=/usr/local/sbin/mdns-alias ${ALIASES[*]}
Restart=always
RestartSec=5
KillMode=control-group
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable mdns-alias.service >/dev/null
systemctl restart mdns-alias.service
sleep 3; systemctl is-active mdns-alias.service; pgrep -a avahi-publish
echo "MDNS_ALIAS_DONE (${ALIASES[*]/%/.local})"
