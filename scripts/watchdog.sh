#!/usr/bin/env bash

CONF="/etc/moviline-link/config.env"
STATE_FILE="/run/moviline-link.state"
MODE_FILE="/etc/moviline-link/mode"
[ -f "$CONF" ] || exit 1
# shellcheck disable=SC1090
. "$CONF"

[ -f "$MODE_FILE" ] || printf 'auto\n' > "$MODE_FILE"

split_routes() {
  printf '%s' "$ROUTE_CIDRS" | tr ',' ' '
}

ping_peer() {
  local iface="$1" peer="$2"
  ip link show "$iface" >/dev/null 2>&1 || return 1
  ping -I "$iface" -c 1 -W 1 "$peer" >/dev/null 2>&1
}

set_iran_path() {
  local which="$1"
  ip route flush table "$TABLE_NAME" 2>/dev/null || true
  if [ "$which" = "primary" ]; then
    ip route replace default via "$PRIMARY_EXIT_IP" dev "$PRIMARY_IF" table "$TABLE_NAME" metric 10
  else
    ip route replace default via "$BACKUP_EXIT_IP" dev "$BACKUP_IF" table "$TABLE_NAME" metric 10
  fi
}

set_exit_path() {
  local which="$1" cidr
  for cidr in $(split_routes); do
    [ -n "$cidr" ] || continue
    if [ "$which" = "primary" ]; then
      ip route replace "$cidr" via "$PRIMARY_IRAN_IP" dev "$PRIMARY_IF" metric 10
    else
      ip route replace "$cidr" via "$BACKUP_IRAN_IP" dev "$BACKUP_IF" metric 10
    fi
  done
}

backup_success_streak=0

while true; do
  mode="$(cat "$MODE_FILE" 2>/dev/null || echo auto)"
  old="$(cat "$STATE_FILE" 2>/dev/null || echo none)"
  primary_ok=0
  backup_ok=0

  if [ "$ROLE" = "iran" ]; then
    ping_peer "$PRIMARY_IF" "$PRIMARY_EXIT_IP" && primary_ok=1
    ping_peer "$BACKUP_IF" "$BACKUP_EXIT_IP" && backup_ok=1
  else
    ping_peer "$PRIMARY_IF" "$PRIMARY_IRAN_IP" && primary_ok=1
    ping_peer "$BACKUP_IF" "$BACKUP_IRAN_IP" && backup_ok=1
  fi

  if [ "$backup_ok" = "1" ]; then
    backup_success_streak=$((backup_success_streak + 1))
  else
    backup_success_streak=0
  fi

  active="none"
  case "$mode" in
    primary|udp)
      [ "$primary_ok" = "1" ] && active="primary"
      ;;
    backup|wss)
      [ "$backup_ok" = "1" ] && active="backup"
      ;;
    *)
      if [ "$old" = "primary" ]; then
        if [ "$backup_ok" = "1" ] && [ "$backup_success_streak" -ge 3 ]; then
          active="backup"
        elif [ "$primary_ok" = "1" ]; then
          active="primary"
        elif [ "$backup_ok" = "1" ]; then
          active="backup"
        fi
      elif [ "$backup_ok" = "1" ]; then
        active="backup"
      elif [ "$primary_ok" = "1" ]; then
        active="primary"
      fi
      ;;
  esac

  if [ "$active" != "none" ]; then
    if [ "$ROLE" = "iran" ]; then
      set_iran_path "$active"
    else
      set_exit_path "$active"
    fi
  fi

  if [ "$active" != "$old" ]; then
    printf '%s\n' "$active" > "$STATE_FILE"
    logger -t moviline-link "role=$ROLE path=$active primary_udp_ok=$primary_ok preferred_wss_ok=$backup_ok"
  fi

  sleep 3
done
