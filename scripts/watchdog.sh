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
  ping -I "$iface" -c 2 -W 1 -i 0.2 "$peer" >/dev/null 2>&1
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

primary_success=0
backup_success=0
primary_fail=0
backup_fail=0
both_fail=0

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

  if [ "$primary_ok" = "1" ]; then
    primary_success=$((primary_success + 1))
    primary_fail=0
  else
    primary_success=0
    primary_fail=$((primary_fail + 1))
  fi

  if [ "$backup_ok" = "1" ]; then
    backup_success=$((backup_success + 1))
    backup_fail=0
  else
    backup_success=0
    backup_fail=$((backup_fail + 1))
  fi

  if [ "$primary_ok" = "0" ] && [ "$backup_ok" = "0" ]; then
    both_fail=$((both_fail + 1))
  else
    both_fail=0
  fi

  active="$old"

  case "$mode" in
    primary|udp)
      if [ "$primary_ok" = "1" ]; then
        active="primary"
      elif [ "$primary_fail" -ge 3 ]; then
        active="none"
      fi
      ;;
    backup|wss)
      if [ "$backup_ok" = "1" ]; then
        active="backup"
      elif [ "$backup_fail" -ge 3 ]; then
        active="none"
      fi
      ;;
    *)
      case "$old" in
        backup)
          if [ "$backup_ok" = "1" ]; then
            active="backup"
          elif [ "$backup_fail" -ge 3 ] && [ "$primary_ok" = "1" ]; then
            active="primary"
          elif [ "$both_fail" -ge 3 ]; then
            active="none"
          fi
          ;;
        primary)
          if [ "$backup_success" -ge 2 ]; then
            active="backup"
          elif [ "$primary_ok" = "1" ]; then
            active="primary"
          elif [ "$primary_fail" -ge 3 ] && [ "$backup_ok" = "1" ]; then
            active="backup"
          elif [ "$both_fail" -ge 3 ]; then
            active="none"
          fi
          ;;
        *)
          if [ "$backup_success" -ge 2 ]; then
            active="backup"
          elif [ "$primary_success" -ge 2 ]; then
            active="primary"
          elif [ "$both_fail" -ge 3 ]; then
            active="none"
          fi
          ;;
      esac
      ;;
  esac

  if [ "$active" = "primary" ] || [ "$active" = "backup" ]; then
    if [ "$ROLE" = "iran" ]; then
      set_iran_path "$active"
    else
      set_exit_path "$active"
    fi
  fi

  if [ "$active" != "$old" ]; then
    printf '%s\n' "$active" > "$STATE_FILE"
    logger -t moviline-link "role=$ROLE mode=$mode path=$active udp_ok=$primary_ok wss_ok=$backup_ok udp_fail=$primary_fail wss_fail=$backup_fail"
  fi

  sleep 3
done
