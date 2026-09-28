#!/usr/bin/env bash

CONF="/etc/moviline-link/config.env"
if [ "$(id -u)" != "0" ]; then
  echo "Run as root"
  exit 1
fi

if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

systemctl disable --now moviline-link-primary.service moviline-link-backup.service moviline-link-routing.service moviline-link-watchdog.service 2>/dev/null || true

if [ -n "${ROUTE_CIDRS:-}" ]; then
  WAN_IF="$(ip route show default | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  for cidr in $(printf '%s' "$ROUTE_CIDRS" | tr ',' ' '); do
    [ -n "$cidr" ] || continue
    ip rule del from "$cidr" table "${TABLE_NAME:-moviline}" priority 12000 2>/dev/null || true
    ip route del "$cidr" via "${PRIMARY_IRAN_IP:-10.250.0.2}" dev "${PRIMARY_IF:-mlp0}" 2>/dev/null || true
    ip route del "$cidr" via "${BACKUP_IRAN_IP:-10.251.0.2}" dev "${BACKUP_IF:-mlb0}" 2>/dev/null || true

    if [ -n "$WAN_IF" ]; then
      while iptables -t nat -C POSTROUTING -s "$cidr" -o "$WAN_IF" -m comment --comment moviline-link -j MASQUERADE 2>/dev/null; do
        iptables -t nat -D POSTROUTING -s "$cidr" -o "$WAN_IF" -m comment --comment moviline-link -j MASQUERADE 2>/dev/null || break
      done
    fi
    while iptables -C FORWARD -s "$cidr" -m comment --comment moviline-link -j ACCEPT 2>/dev/null; do
      iptables -D FORWARD -s "$cidr" -m comment --comment moviline-link -j ACCEPT 2>/dev/null || break
    done
    while iptables -C FORWARD -d "$cidr" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment moviline-link -j ACCEPT 2>/dev/null; do
      iptables -D FORWARD -d "$cidr" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment moviline-link -j ACCEPT 2>/dev/null || break
    done
  done
fi

ip route flush table "${TABLE_NAME:-moviline}" 2>/dev/null || true

rm -f /etc/systemd/system/moviline-link-primary.service       /etc/systemd/system/moviline-link-backup.service       /etc/systemd/system/moviline-link-routing.service       /etc/systemd/system/moviline-link-watchdog.service
systemctl daemon-reload

rm -rf /etc/moviline-link /usr/local/lib/moviline-link
rm -f /usr/local/sbin/moviline-link
rm -f /etc/sysctl.d/90-moviline-link.conf

if [ -f /etc/iproute2/rt_tables ]; then
  sed -i -E '/^[[:space:]]*250[[:space:]]+moviline([[:space:]]|$)/d' /etc/iproute2/rt_tables
fi

echo "Moviline Link removed. GOST binary and live ip_forward value were intentionally left unchanged."
