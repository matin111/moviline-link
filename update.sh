#!/usr/bin/env bash

CONF="/etc/moviline-link/config.env"
[ -f "$CONF" ] || { echo "Moviline Link config not found" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

REF="${1:-${MOVILINE_REF:-v1.0.0}}"
REPO="${MOVILINE_REPO:-matin111/moviline-link}"
TMP="$(mktemp /tmp/moviline-link-install.XXXXXX.sh)" || exit 1
URL="https://raw.githubusercontent.com/${REPO}/${REF}/install.sh"

curl -fsSL --retry 3 --connect-timeout 10 "$URL" -o "$TMP" || {
  echo "Download failed: $URL" >&2
  rm -f "$TMP"
  exit 1
}
chmod +x "$TMP"

ARGS=("$ROLE" --domain "$DOMAIN" --secret "$SECRET" --routes "$ROUTE_CIDRS" --primary-port "$PRIMARY_PORT" --backup-port "$BACKUP_PORT" --primary-mtu "$PRIMARY_MTU" --backup-mtu "$BACKUP_MTU" --repo "$REPO" --ref "$REF")

if [ "$ROLE" = "iran" ]; then
  ARGS+=(--exit-ip "$EXIT_IP")
else
  ARGS+=(--cert "$CERT_FILE" --key "$KEY_FILE")
fi

bash "$TMP" "${ARGS[@]}"
rc=$?
rm -f "$TMP"
exit "$rc"
