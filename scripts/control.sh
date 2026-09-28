#!/usr/bin/env bash

CONF="/etc/moviline-link/config.env"
MODE_FILE="/etc/moviline-link/mode"
STATE_FILE="/run/moviline-link.state"

[ -f "$CONF" ] || { echo "Moviline Link نصب نشده است."; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

cmd="${1:-status}"

status() {
  echo "Moviline Link"
  echo "Role        : $ROLE"
  echo "Version ref : ${MOVILINE_REF:-unknown}"
  echo "Mode        : $(cat "$MODE_FILE" 2>/dev/null || echo auto)"
  echo "Active path : $(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
  [ -n "$EXIT_IP" ] && echo "Exit        : $EXIT_IP"
  echo "Routes      : ${ROUTE_CIDRS:-none}"
  echo
  printf '%-10s %-12s %-15s
' "SERVICE" "STATE" "INTERFACE"
  printf '%-10s %-12s %-15s
' "primary" "$(systemctl is-active moviline-link-primary.service 2>/dev/null || true)" "$(ip -br link show "$PRIMARY_IF" 2>/dev/null | awk '{print $2}')"
  printf '%-10s %-12s %-15s
' "backup" "$(systemctl is-active moviline-link-backup.service 2>/dev/null || true)" "$(ip -br link show "$BACKUP_IF" 2>/dev/null | awk '{print $2}')"
  echo
  ip -br addr show "$PRIMARY_IF" 2>/dev/null || true
  ip -br addr show "$BACKUP_IF" 2>/dev/null || true
}

test_link() {
  if [ "$ROLE" = "iran" ]; then
    echo "Primary peer:"
    ping -I "$PRIMARY_IF" -c 3 -W 1 "$PRIMARY_EXIT_IP" || true
    echo
    echo "Backup peer:"
    ping -I "$BACKUP_IF" -c 3 -W 1 "$BACKUP_EXIT_IP" || true
  else
    echo "Primary peer:"
    ping -I "$PRIMARY_IF" -c 3 -W 1 "$PRIMARY_IRAN_IP" || true
    echo
    echo "Backup peer:"
    ping -I "$BACKUP_IF" -c 3 -W 1 "$BACKUP_IRAN_IP" || true
  fi
}

set_mode() {
  printf '%s
' "$1" > "$MODE_FILE"
  systemctl restart moviline-link-watchdog.service
  sleep 1
  status
}

doctor() {
  status
  echo
  echo "===== SYSTEMD ====="
  systemctl --no-pager --full status moviline-link-primary.service moviline-link-backup.service moviline-link-routing.service moviline-link-watchdog.service 2>/dev/null | tail -80 || true
  echo
  echo "===== RULES ====="
  ip rule show | grep -E "lookup (${TABLE_NAME}|${TABLE_ID})" || true
  echo
  echo "===== TABLE ====="
  ip route show table "$TABLE_NAME" 2>/dev/null || true
  echo
  echo "===== PORTS ====="
  ss -lntup | grep -E ":${PRIMARY_PORT} |:${BACKUP_PORT} " || true
  echo
  echo "===== RECENT LOGS ====="
  journalctl -u moviline-link-primary.service -u moviline-link-backup.service -u moviline-link-watchdog.service -n 60 --no-pager || true
}

case "$cmd" in
  status) status ;;
  test) test_link ;;
  doctor) doctor ;;
  auto) set_mode auto ;;
  primary) set_mode primary ;;
  backup) set_mode backup ;;
  restart)
    systemctl restart moviline-link-primary.service moviline-link-backup.service
    sleep 2
    systemctl restart moviline-link-routing.service moviline-link-watchdog.service
    status
    ;;
  update)
    shift
    exec /usr/local/lib/moviline-link/update.sh "${1:-${MOVILINE_REF:-v1.0.0}}"
    ;;
  uninstall)
    exec /usr/local/lib/moviline-link/uninstall.sh
    ;;
  logs)
    journalctl -u moviline-link-primary.service -u moviline-link-backup.service -u moviline-link-watchdog.service -n 100 --no-pager
    ;;
  *)
    echo "Usage: moviline-link {status|test|doctor|auto|primary|backup|restart|logs|update [ref]|uninstall}"
    exit 1
    ;;
esac
