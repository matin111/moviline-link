#!/usr/bin/env bash

CONF="/etc/moviline-link/config.env"
[ -f "$CONF" ] || { echo "config.env not found" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

split_routes() {
  printf '%s' "$ROUTE_CIDRS" | tr ',' ' '
}

ensure_rt_table() {
  if ! grep -qE "^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}([[:space:]]|$)" /etc/iproute2/rt_tables; then
    printf '%s %s
' "$TABLE_ID" "$TABLE_NAME" >> /etc/iproute2/rt_tables
  fi
}

ensure_ip_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
}

ensure_tun_sysctls() {
  local iface
  for iface in "$PRIMARY_IF" "$BACKUP_IF"; do
    if ip link show "$iface" >/dev/null 2>&1; then
      sysctl -w "net.ipv4.conf.${iface}.rp_filter=0" >/dev/null 2>&1 || true
    fi
  done
}

ensure_rule() {
  local cidr="$1"
  ip rule show | grep -Fq "from ${cidr} lookup ${TABLE_NAME}" || ip rule add from "$cidr" table "$TABLE_NAME" priority 12000
}

ensure_nat() {
  local cidr="$1" wan="$2"
  iptables -t nat -C POSTROUTING -s "$cidr" -o "$wan" -m comment --comment moviline-link -j MASQUERADE 2>/dev/null ||     iptables -t nat -A POSTROUTING -s "$cidr" -o "$wan" -m comment --comment moviline-link -j MASQUERADE
}

ensure_forward_rules() {
  local cidr="$1"
  iptables -C FORWARD -s "$cidr" -m comment --comment moviline-link -j ACCEPT 2>/dev/null ||     iptables -I FORWARD 1 -s "$cidr" -m comment --comment moviline-link -j ACCEPT
  iptables -C FORWARD -d "$cidr" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment moviline-link -j ACCEPT 2>/dev/null ||     iptables -I FORWARD 1 -d "$cidr" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment moviline-link -j ACCEPT
}

ensure_rt_table
ensure_ip_forward
ensure_tun_sysctls

if [ "$ROLE" = "iran" ]; then
  for cidr in $(split_routes); do
    [ -n "$cidr" ] || continue
    ensure_rule "$cidr"
  done
else
  WAN_IF="$(ip route show default | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [ -z "$WAN_IF" ]; then
    echo "WAN interface not found" >&2
    exit 1
  fi
  for cidr in $(split_routes); do
    [ -n "$cidr" ] || continue
    ensure_nat "$cidr" "$WAN_IF"
    ensure_forward_rules "$cidr"
  done
fi
