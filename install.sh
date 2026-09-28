#!/usr/bin/env bash

VERSION="1.0.0"
GOST_VERSION="3.3.0"
GOST_AMD64_SHA256="676fb7f78d267b6ae73df719c0c7f2b565dde7147da935cfafbc1e1da558b6d5"
GOST_ARM64_SHA256="d03699e3f385d4ff5dad68046712adfcc7515325a064d2ab046e0bece30f8f8f"
BASE_DIR="/etc/moviline-link"
LIB_DIR="/usr/local/lib/moviline-link"
BIN_CTL="/usr/local/sbin/moviline-link"
TABLE_ID="250"
TABLE_NAME="moviline"
REPO="${MOVILINE_REPO:-matin111/moviline-link}"
REF="${MOVILINE_REF:-v1.0.0}"
BUNDLE_DIR=""

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
need_root() {
  if [ "$(id -u)" != "0" ]; then
    die "این نصب باید با root اجرا شود."
    return 1
  fi
}

ROLE="${1:-}"
if [ -n "$ROLE" ]; then shift; fi
EXIT_IP=""
DOMAIN=""
CERT_FILE=""
KEY_FILE=""
SECRET=""
ROUTES=""
PRIMARY_PORT="443"
BACKUP_PORT="443"
PRIMARY_MTU="1280"
BACKUP_MTU="1180"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --exit-ip) EXIT_IP="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --cert) CERT_FILE="${2:-}"; shift 2 ;;
    --key) KEY_FILE="${2:-}"; shift 2 ;;
    --secret) SECRET="${2:-}"; shift 2 ;;
    --routes) ROUTES="${2:-}"; shift 2 ;;
    --primary-port) PRIMARY_PORT="${2:-}"; shift 2 ;;
    --backup-port) BACKUP_PORT="${2:-}"; shift 2 ;;
    --primary-mtu) PRIMARY_MTU="${2:-}"; shift 2 ;;
    --backup-mtu) BACKUP_MTU="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<USAGE
Moviline Link v${VERSION}

Usage:
  install.sh exit --domain DOMAIN --cert FILE --key FILE [--routes CIDR,CIDR]
  install.sh iran --exit-ip IP --domain DOMAIN --secret SECRET [--routes CIDR,CIDR]

Options:
  --primary-port PORT   UDP direct TUN port (default: 443)
  --backup-port PORT    WSS/TCP fallback port (default: 443)
  --primary-mtu MTU     primary TUN MTU (default: 1280)
  --backup-mtu MTU      backup TUN MTU (default: 1180)
  --repo OWNER/REPO     GitHub repository
  --ref REF             GitHub tag/branch/commit (default: v1.0.0)
USAGE
      exit 0
      ;;
    *) say "پارامتر ناشناخته: $1"; shift ;;
  esac
done

prompt_missing() {
  if [ "$ROLE" != "iran" ] && [ "$ROLE" != "exit" ]; then
    say "نوع سرور را انتخاب کنید:"
    say "1) iran"
    say "2) exit"
    read -r ans
    case "$ans" in
      1) ROLE="iran" ;;
      2) ROLE="exit" ;;
      *) die "Role نامعتبر است."; return 1 ;;
    esac
  fi

  if [ "$ROLE" = "iran" ]; then
    if [ -z "$EXIT_IP" ]; then
      printf 'IP سرور خارج: '
      read -r EXIT_IP
    fi
    if [ -z "$DOMAIN" ]; then
      printf 'دامنه TLS (مثال sub1.in88.sbs): '
      read -r DOMAIN
    fi
    if [ -z "$SECRET" ]; then
      printf 'Shared secret (خروجی نصب خارج): '
      read -r SECRET
    fi
  else
    if [ -z "$DOMAIN" ]; then
      printf 'دامنه TLS: '
      read -r DOMAIN
    fi
    if [ -z "$CERT_FILE" ]; then
      printf 'مسیر fullchain.pem: '
      read -r CERT_FILE
    fi
    if [ -z "$KEY_FILE" ]; then
      printf 'مسیر privkey.pem: '
      read -r KEY_FILE
    fi
    if [ -z "$SECRET" ]; then
      SECRET="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
    fi
  fi

  if [ -z "$ROUTES" ]; then
    printf 'Subnetهای کاربران VPN با کاما (برای نصب آزمایشی خالی بگذارید): '
    read -r ROUTES
  fi
}

validate_inputs() {
  if [ "$ROLE" = "iran" ]; then
    [ -n "$EXIT_IP" ] || { die "--exit-ip لازم است."; return 1; }
    [ -n "$DOMAIN" ] || { die "--domain لازم است."; return 1; }
    [ -n "$SECRET" ] || { die "--secret لازم است."; return 1; }
  else
    [ -n "$DOMAIN" ] || { die "--domain لازم است."; return 1; }
    [ -f "$CERT_FILE" ] || { die "Certificate پیدا نشد: $CERT_FILE"; return 1; }
    [ -f "$KEY_FILE" ] || { die "Private key پیدا نشد: $KEY_FILE"; return 1; }
  fi

  if [ "${#SECRET}" -gt 16 ]; then
    SECRET="${SECRET:0:16}"
  fi
  if [ "${#SECRET}" -lt 8 ]; then
    die "Shared secret باید حداقل 8 کاراکتر باشد."
    return 1
  fi

  case "$PRIMARY_PORT:$BACKUP_PORT" in
    *[!0-9:]* ) die "پورت‌ها باید عددی باشند."; return 1 ;;
  esac
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null 2>&1
  apt-get install -y curl ca-certificates tar iproute2 iptables iputils-ping >/dev/null 2>&1
}

prepare_bundle() {
  local src base rel dst
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [ -f "$src/scripts/apply-routing.sh" ] && [ -f "$src/systemd/moviline-link-primary.service" ]; then
    BUNDLE_DIR="$src"
    return 0
  fi

  BUNDLE_DIR="$(mktemp -d /tmp/moviline-link-bundle.XXXXXX)" || return 1
  mkdir -p "$BUNDLE_DIR/scripts" "$BUNDLE_DIR/systemd"
  base="https://raw.githubusercontent.com/${REPO}/${REF}"

  for rel in \
    scripts/apply-routing.sh \
    scripts/watchdog.sh \
    scripts/control.sh \
    systemd/moviline-link-primary.service \
    systemd/moviline-link-backup.service \
    systemd/moviline-link-routing.service \
    systemd/moviline-link-watchdog.service \
    update.sh \
    uninstall.sh; do
    dst="$BUNDLE_DIR/$rel"
    curl -fsSL --retry 3 --connect-timeout 10 "$base/$rel" -o "$dst" || {
      die "دانلود فایل repository ناموفق بود: $rel"
      return 1
    }
  done
}

install_gost() {
  local arch asset sha url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      asset="gost_${GOST_VERSION}_linux_amd64.tar.gz"
      sha="$GOST_AMD64_SHA256"
      ;;
    aarch64|arm64)
      asset="gost_${GOST_VERSION}_linux_arm64.tar.gz"
      sha="$GOST_ARM64_SHA256"
      ;;
    *) die "CPU پشتیبانی نشده: $arch"; return 1 ;;
  esac

  if command -v gost >/dev/null 2>&1; then
    if gost -V 2>&1 | grep -q "$GOST_VERSION"; then
      return 0
    fi
  fi

  url="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/${asset}"
  tmp="/tmp/${asset}"
  say "Downloading GOST v${GOST_VERSION}..."
  curl -fL --retry 3 --connect-timeout 10 "$url" -o "$tmp" || { die "دانلود GOST ناموفق بود."; return 1; }
  printf '%s  %s\n' "$sha" "$tmp" | sha256sum -c - >/dev/null 2>&1 || { die "Checksum GOST صحیح نیست."; return 1; }
  tar -xzf "$tmp" -C /tmp gost || { die "Extract ناموفق بود."; return 1; }
  install -m 755 /tmp/gost /usr/local/bin/gost
  rm -f "$tmp" /tmp/gost
}

backup_old() {
  if [ -d "$BASE_DIR" ]; then
    cp -a "$BASE_DIR" "${BASE_DIR}.bak-$(date +%Y%m%d-%H%M%S)"
  fi
}

write_env() {
  mkdir -p "$BASE_DIR" "$LIB_DIR"
  cat > "$BASE_DIR/config.env" <<ENV
ROLE='$ROLE'
EXIT_IP='$EXIT_IP'
DOMAIN='$DOMAIN'
CERT_FILE='$CERT_FILE'
KEY_FILE='$KEY_FILE'
SECRET='$SECRET'
ROUTE_CIDRS='$ROUTES'
PRIMARY_PORT='$PRIMARY_PORT'
BACKUP_PORT='$BACKUP_PORT'
PRIMARY_MTU='$PRIMARY_MTU'
BACKUP_MTU='$BACKUP_MTU'
TABLE_ID='$TABLE_ID'
TABLE_NAME='$TABLE_NAME'
PRIMARY_IF='mlp0'
BACKUP_IF='mlb0'
PRIMARY_IRAN_IP='10.250.0.2'
PRIMARY_EXIT_IP='10.250.0.1'
BACKUP_IRAN_IP='10.251.0.2'
BACKUP_EXIT_IP='10.251.0.1'
MOVILINE_REPO='$REPO'
MOVILINE_REF='$REF'
ENV
  chmod 600 "$BASE_DIR/config.env"
}

write_exit_yaml() {
  cat > "$BASE_DIR/primary.yml" <<YAML
services:
- name: moviline-primary-tun
  addr: ":${PRIMARY_PORT}"
  handler:
    type: tun
    auther: tun-auth
  listener:
    type: tun
    metadata:
      name: mlp0
      net: 10.250.0.1/30
      mtu: ${PRIMARY_MTU}
authers:
- name: tun-auth
  auths:
  - username: 10.250.0.2
    password: "${SECRET}"
YAML

  cat > "$BASE_DIR/backup.yml" <<YAML
services:
- name: moviline-backup-tun
  addr: "127.0.0.1:8422"
  handler:
    type: tun
  listener:
    type: tun
    metadata:
      name: mlb0
      net: 10.251.0.1/30
      mtu: ${BACKUP_MTU}

- name: moviline-backup-wss
  addr: ":${BACKUP_PORT}"
  handler:
    type: relay
    auth:
      username: moviline
      password: "${SECRET}"
    metadata:
      bind: true
  listener:
    type: wss
    tls:
      certFile: "${CERT_FILE}"
      keyFile: "${KEY_FILE}"
    metadata:
      path: /moviline-link/v1
YAML
}

write_iran_yaml() {
  cat > "$BASE_DIR/primary.yml" <<YAML
services:
- name: moviline-primary-tun
  addr: ":0"
  handler:
    type: tun
    metadata:
      keepAlive: true
      ttl: 5s
      passphrase: "${SECRET}"
  listener:
    type: tun
    metadata:
      name: mlp0
      net: 10.250.0.2/30
      mtu: ${PRIMARY_MTU}
  forwarder:
    nodes:
    - name: exit-primary
      addr: ${EXIT_IP}:${PRIMARY_PORT}
YAML

  cat > "$BASE_DIR/backup.yml" <<YAML
services:
- name: moviline-backup-tun
  addr: ":0"
  handler:
    type: tun
    chain: backup-chain
    metadata:
      keepAlive: true
      ttl: 5s
  listener:
    type: tun
    metadata:
      name: mlb0
      net: 10.251.0.2/30
      mtu: ${BACKUP_MTU}
  forwarder:
    nodes:
    - name: backup-target
      addr: 127.0.0.1:8422

chains:
- name: backup-chain
  hops:
  - name: backup-hop
    nodes:
    - name: exit-backup
      addr: ${EXIT_IP}:${BACKUP_PORT}
      connector:
        type: relay
        auth:
          username: moviline
          password: "${SECRET}"
      dialer:
        type: wss
        tls:
          secure: true
          serverName: "${DOMAIN}"
        metadata:
          host: "${DOMAIN}"
          path: /moviline-link/v1
          keepalive: true
          ttl: 10s
YAML
}

copy_scripts() {
  [ -n "$BUNDLE_DIR" ] || { die "Bundle آماده نیست."; return 1; }
  install -m 755 "$BUNDLE_DIR/scripts/apply-routing.sh" "$LIB_DIR/apply-routing.sh"
  install -m 755 "$BUNDLE_DIR/scripts/watchdog.sh" "$LIB_DIR/watchdog.sh"
  install -m 755 "$BUNDLE_DIR/scripts/control.sh" "$BIN_CTL"
  install -m 755 "$BUNDLE_DIR/update.sh" "$LIB_DIR/update.sh"
  install -m 755 "$BUNDLE_DIR/uninstall.sh" "$LIB_DIR/uninstall.sh"
  install -m 644 "$BUNDLE_DIR/systemd/moviline-link-primary.service" /etc/systemd/system/
  install -m 644 "$BUNDLE_DIR/systemd/moviline-link-backup.service" /etc/systemd/system/
  install -m 644 "$BUNDLE_DIR/systemd/moviline-link-routing.service" /etc/systemd/system/
  install -m 644 "$BUNDLE_DIR/systemd/moviline-link-watchdog.service" /etc/systemd/system/
}

start_services() {
  systemctl daemon-reload
  systemctl enable moviline-link-primary.service moviline-link-backup.service moviline-link-routing.service moviline-link-watchdog.service >/dev/null 2>&1
  systemctl restart moviline-link-primary.service
  sleep 2
  systemctl restart moviline-link-backup.service
  sleep 2
  systemctl restart moviline-link-routing.service
  systemctl restart moviline-link-watchdog.service
}

print_service_state() {
  say "primary : $(systemctl is-active moviline-link-primary.service 2>/dev/null || true)"
  say "backup  : $(systemctl is-active moviline-link-backup.service 2>/dev/null || true)"
  say "routing : $(systemctl is-active moviline-link-routing.service 2>/dev/null || true)"
  say "watchdog: $(systemctl is-active moviline-link-watchdog.service 2>/dev/null || true)"
}

main() {
  need_root || return 1
  prompt_missing || return 1
  validate_inputs || return 1

  say "===== Moviline Link v${VERSION} ====="
  say "Role: $ROLE"
  say "Repo: $REPO @ $REF"

  install_deps
  prepare_bundle || return 1
  install_gost || return 1
  backup_old
  write_env

  if [ "$ROLE" = "exit" ]; then
    write_exit_yaml
  else
    write_iran_yaml
  fi

  copy_scripts || return 1

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  mkdir -p /etc/sysctl.d
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-moviline-link.conf

  start_services

  say
  say "===== SERVICES ====="
  print_service_state
  say
  "$BIN_CTL" status || true

  if [ "$ROLE" = "exit" ]; then
    say
    say "Shared secret برای نصب ایران: $SECRET"
  fi

  say
  say "نصب انجام شد. اگر ROUTE_CIDRS خالی باشد مسیر فعلی کاربران تغییر نمی‌کند."
  say "برای عیب‌یابی: moviline-link doctor"
}

main "$@"
