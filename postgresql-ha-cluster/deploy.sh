#!/usr/bin/env bash
# =============================================================================
# deploy.sh — PostgreSQL HA cluster deployment (Patroni + etcd + HAProxy + Keepalived)
#
# Usage:   sudo ./deploy.sh <db1|db2|db3> [--no-upgrade]
#
# - Idempotent: re-runnable without breaking an existing cluster.
# - Without SSH: on db1, the other nodes' certs are packaged as .tar.gz;
#   you copy them yourself (scp/USB) to db2/db3 before running the script there.
# - Read the guide: Guide_Cluster_PostgreSQL_HA_v2.md
# =============================================================================
set -euo pipefail

# --- Location & loading of cluster.env ---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/cluster.env"

# --- Display helpers ---------------------------------------------------------
c_info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
c_ok()    { printf '\033[1;32m[ OK ]\033[0m  %s\n' "$*"; }
c_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
c_err()   { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; }
c_step()  { printf '\n\033[1;36m===== %s =====\033[0m\n' "$*"; }
die()     { c_err "$*"; exit 1; }

# Test mode: SKIP_SERVICES=1 → don't touch systemd (container without systemd).
# The script installs, generates certs + configs, but starts/enables no service.
SKIP_SERVICES="${SKIP_SERVICES:-0}"
svc() { if [[ $SKIP_SERVICES -eq 1 ]]; then c_warn "SKIP_SERVICES: 'systemctl $*' skipped"; else systemctl "$@"; fi; }

# --- Pre-checks --------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Must run as root: sudo ./deploy.sh <db1|db2|db3>"
[[ -f "$ENV_FILE" ]] || die "File not found: $ENV_FILE (copy cluster.env.example -> cluster.env)"

# shellcheck disable=SC1090
source "$ENV_FILE"

# Default value if absent from cluster.env (avoids a broken download URL)
: "${ETCD_VERSION:=v3.6.12}"

NODE="${1:-}"
NO_UPGRADE=0
[[ "${2:-}" == "--no-upgrade" ]] && NO_UPGRADE=1
[[ -n "$NODE" ]] || die "Missing argument. Usage: sudo ./deploy.sh <db1|db2|db3> [--no-upgrade]"

# --- Resolve the current node's variables ------------------------------------
case "$NODE" in
  "$DB1_NAME") NODE_IP="$DB1_IP"; VRRP_STATE="MASTER"; VRRP_PRIORITY="$DB1_VRRP_PRIORITY"; IS_DB1=1 ;;
  "$DB2_NAME") NODE_IP="$DB2_IP"; VRRP_STATE="BACKUP"; VRRP_PRIORITY="$DB2_VRRP_PRIORITY"; IS_DB1=0 ;;
  "$DB3_NAME") NODE_IP="$DB3_IP"; VRRP_STATE="BACKUP"; VRRP_PRIORITY="$DB3_VRRP_PRIORITY"; IS_DB1=0 ;;
  *) die "Unknown node '$NODE'. Expected: $DB1_NAME, $DB2_NAME or $DB3_NAME" ;;
esac

ETCD_SSL="/etc/etcd/ssl"
PG_SSL="/var/lib/postgresql/ssl"
PG_DATA="/var/lib/postgresql/data"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
CERT_SUBJ_BASE="/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_LOCALITY}/O=${CERT_ORG}/OU=${CERT_OU}"
ETCD_INITIAL_CLUSTER="${DB1_NAME}=https://${DB1_IP}:${ETCD_PEER_PORT},${DB2_NAME}=https://${DB2_IP}:${ETCD_PEER_PORT},${DB3_NAME}=https://${DB3_IP}:${ETCD_PEER_PORT}"

c_info "Current node: ${NODE} (${NODE_IP})  | VRRP role: ${VRRP_STATE}/${VRRP_PRIORITY}"

# =============================================================================
# 1. System update
# =============================================================================
system_update() {
  c_step "1. System update"
  if [[ $NO_UPGRADE -eq 1 ]]; then c_warn "--no-upgrade: system upgrade skipped"; apt-get update -y; return; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  c_ok "System up to date"
}

# =============================================================================
# 2. Package installation
# =============================================================================
install_packages() {
  c_step "2. Package installation"
  export DEBIAN_FRONTEND=noninteractive
  if [[ ! -f /etc/apt/sources.list.d/pgdg.list && ! -f /etc/apt/sources.list.d/pgdg.sources ]]; then
    c_info "Configuring the PGDG repository"
    apt-get install -y postgresql-common
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  else
    c_ok "PGDG repository already present"
  fi
  apt-get install -y "postgresql-${PG_VERSION}" acl patroni haproxy keepalived curl socat tar wget

  # Patroni manages PostgreSQL: disable the native service
  svc stop postgresql 2>/dev/null || true
  svc disable postgresql 2>/dev/null || true
  c_ok "Packages installed, native postgresql service disabled"
}

# =============================================================================
# 3. etcd binary
# =============================================================================
install_etcd() {
  c_step "3. Installing the etcd binary ${ETCD_VERSION}"
  local want="$ETCD_VERSION" have=""
  # Safeguard: the version must be of the form vX.Y.Z, otherwise the download URL is broken
  [[ "$want" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Invalid ETCD_VERSION: '${want}' (expected vX.Y.Z, e.g. v3.6.12)"
  have="$(/usr/local/bin/etcd --version 2>/dev/null | awk '/etcd Version/{print "v"$3}' | head -1 || true)"
  if [[ "$have" == "$want" ]]; then
    c_ok "etcd ${want} already installed"
  else
    local arch earch; arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    case "$arch" in arm64) earch=arm64 ;; *) earch=amd64 ;; esac
    local dir="etcd-${want}-linux-${earch}" tgz="etcd-${want}-linux-${earch}.tar.gz"
    local url="https://github.com/etcd-io/etcd/releases/download/${want}/${tgz}"
    c_info "Downloading etcd ${want} (${earch}) from ${url}"
    ( cd /tmp && rm -f "$tgz" && wget -q "$url" \
        && tar xzf "$tgz" && cp "${dir}/etcd" "${dir}/etcdctl" /usr/local/bin/ ) \
      || die "Failed to download/install etcd from ${url}"
    c_ok "etcd installed: $(/usr/local/bin/etcd --version | head -1)"
  fi
  id etcd &>/dev/null || useradd --system --home /var/lib/etcd --shell /bin/false etcd
  mkdir -p /var/lib/etcd /etc/etcd "$ETCD_SSL"
  chown -R etcd:etcd /var/lib/etcd
}

# =============================================================================
# 4. TLS certificates
# =============================================================================
# 4a. On db1: CA + certs for all nodes + PG cert (multi-SAN) + tar packages
gen_certs_db1() {
  c_step "4. TLS certificates (generation on ${DB1_NAME})"
  mkdir -p "$ETCD_SSL" "$PG_SSL"

  # --- CA (generated only once) ---
  if [[ ! -f "$ETCD_SSL/ca.key" ]]; then
    c_info "Creating the CA"
    openssl genrsa -out "$ETCD_SSL/ca.key" 2048
    openssl req -x509 -new -nodes -key "$ETCD_SSL/ca.key" -subj "/CN=etcd-ca" -days 21900 -out "$ETCD_SSL/ca.crt"
  else
    c_ok "CA already present"
  fi

  # --- etcd cert per node ---
  local names=("$DB1_NAME" "$DB2_NAME" "$DB3_NAME") ips=("$DB1_IP" "$DB2_IP" "$DB3_IP") i
  for i in 0 1 2; do
    local n="${names[$i]}" ip="${ips[$i]}"
    if [[ -f "$ETCD_SSL/etcd-${n}.crt" ]]; then c_ok "etcd cert ${n} already present"; continue; fi
    c_info "Generating etcd cert ${n} (${ip})"
    openssl genrsa -out "$ETCD_SSL/etcd-${n}.key" 2048
    cat > /tmp/etcd-${n}.cnf <<EOF
[ req ]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[ dn ]
CN = etcd-${n}
[ v3_req ]
subjectAltName = @alt
[ alt ]
IP.1 = ${ip}
IP.2 = 127.0.0.1
EOF
    openssl req -new -key "$ETCD_SSL/etcd-${n}.key" -out "/tmp/etcd-${n}.csr" \
      -subj "${CERT_SUBJ_BASE}/CN=etcd-${n}" -config "/tmp/etcd-${n}.cnf"
    openssl x509 -req -in "/tmp/etcd-${n}.csr" -CA "$ETCD_SSL/ca.crt" -CAkey "$ETCD_SSL/ca.key" \
      -CAcreateserial -out "$ETCD_SSL/etcd-${n}.crt" -days 21900 -sha256 \
      -extensions v3_req -extfile "/tmp/etcd-${n}.cnf"
    rm -f "/tmp/etcd-${n}.csr" "/tmp/etcd-${n}.cnf"
  done

  # --- Shared PostgreSQL cert (SAN = VIP + 3 nodes + localhost) ---
  if [[ ! -f "$PG_SSL/server.crt" ]]; then
    c_info "Generating PostgreSQL cert (multi-SAN)"
    openssl genrsa -out "$PG_SSL/server.key" 2048
    cat > /tmp/server.cnf <<EOF
[ req ]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[ dn ]
CN = postgresql-server
[ v3_req ]
subjectAltName = @alt
[ alt ]
DNS.1 = postgresql-server
IP.1 = ${VIP}
IP.2 = ${DB1_IP}
IP.3 = ${DB2_IP}
IP.4 = ${DB3_IP}
IP.5 = 127.0.0.1
EOF
    openssl req -new -key "$PG_SSL/server.key" -out /tmp/server.req -config /tmp/server.cnf
    openssl x509 -req -in /tmp/server.req -signkey "$PG_SSL/server.key" -out "$PG_SSL/server.crt" \
      -days 21900 -sha256 -extensions v3_req -extfile /tmp/server.cnf
    cat "$PG_SSL/server.crt" "$PG_SSL/server.key" > "$PG_SSL/server.pem"
    rm -f /tmp/server.req /tmp/server.cnf
  else
    c_ok "PostgreSQL cert already present"
  fi

  # --- tar.gz packages for db2 and db3 ---
  local out="${SCRIPT_DIR}"
  for n in "$DB2_NAME" "$DB3_NAME"; do
    tar czf "${out}/certs-${n}.tar.gz" -C / \
      "etc/etcd/ssl/ca.crt" "etc/etcd/ssl/etcd-${n}.crt" "etc/etcd/ssl/etcd-${n}.key" \
      "var/lib/postgresql/ssl/server.crt" "var/lib/postgresql/ssl/server.key" "var/lib/postgresql/ssl/server.pem"
    c_ok "Package generated: ${out}/certs-${n}.tar.gz"
  done
}

# 4b. On db2/db3: extract the tar if it is in /tmp, otherwise require the certs
gen_certs_replica() {
  c_step "4. TLS certificates (reception on ${NODE})"
  mkdir -p "$ETCD_SSL" "$PG_SSL"
  local tarball="/tmp/certs-${NODE}.tar.gz"
  if [[ -f "$tarball" ]]; then
    c_info "Extracting ${tarball}"
    tar xzf "$tarball" -C /
    c_ok "Certs extracted"
  fi
  local missing=0 f
  for f in "$ETCD_SSL/ca.crt" "$ETCD_SSL/etcd-${NODE}.crt" "$ETCD_SSL/etcd-${NODE}.key" \
           "$PG_SSL/server.crt" "$PG_SSL/server.key" "$PG_SSL/server.pem"; do
    [[ -f "$f" ]] || { c_err "Missing cert: $f"; missing=1; }
  done
  if [[ $missing -eq 1 ]]; then
    cat <<EOF

  The certificates for ${NODE} are missing. From ${DB1_NAME}, copy the package:

      scp ${SCRIPT_DIR}/certs-${NODE}.tar.gz <user>@${NODE_IP}:/tmp/

  then re-run:  sudo ./deploy.sh ${NODE}

EOF
    die "Missing certs — see above."
  fi
}

# 4c. Permissions (all nodes)
fix_cert_perms() {
  c_info "Applying permissions on the certificates"
  chown -R etcd:etcd /etc/etcd/
  # Directory traversal for postgres (Patroni runs as postgres):
  # without +x on /etc/etcd and /etc/etcd/ssl, the file ACL is not enough and
  # openssl fails with "unable to load trusted certificates".
  chmod 755 /etc/etcd "$ETCD_SSL"
  chmod 600 "$ETCD_SSL"/*.key
  chmod 644 "$ETCD_SSL"/*.crt
  # Read access for postgres (Patroni runs as postgres) to the local etcd cert + CA
  setfacl -m u:postgres:r "$ETCD_SSL/ca.crt"
  setfacl -m u:postgres:r "$ETCD_SSL/etcd-${NODE}.crt"
  setfacl -m u:postgres:r "$ETCD_SSL/etcd-${NODE}.key"
  chown postgres:postgres "$PG_SSL"/server.*
  chmod 600 "$PG_SSL/server.key" "$PG_SSL/server.pem"
  chmod 644 "$PG_SSL/server.crt"
  c_ok "Permissions OK"
}

setup_certs() {
  if [[ $IS_DB1 -eq 1 ]]; then gen_certs_db1; else gen_certs_replica; fi
  fix_cert_perms
}

# =============================================================================
# 5. etcd configuration
# =============================================================================
configure_etcd() {
  c_step "5. etcd configuration"
  cat > /etc/etcd/etcd.env <<EOF
ETCD_NAME="${NODE}"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER}"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://${NODE_IP}:${ETCD_PEER_PORT}"
ETCD_ADVERTISE_CLIENT_URLS="https://${NODE_IP}:${ETCD_CLIENT_PORT}"
ETCD_LISTEN_PEER_URLS="https://0.0.0.0:${ETCD_PEER_PORT}"
ETCD_LISTEN_CLIENT_URLS="https://0.0.0.0:${ETCD_CLIENT_PORT}"
ETCD_CLIENT_CERT_AUTH="true"
ETCD_TRUSTED_CA_FILE="${ETCD_SSL}/ca.crt"
ETCD_CERT_FILE="${ETCD_SSL}/etcd-${NODE}.crt"
ETCD_KEY_FILE="${ETCD_SSL}/etcd-${NODE}.key"
ETCD_PEER_CLIENT_CERT_AUTH="true"
ETCD_PEER_TRUSTED_CA_FILE="${ETCD_SSL}/ca.crt"
ETCD_PEER_CERT_FILE="${ETCD_SSL}/etcd-${NODE}.crt"
ETCD_PEER_KEY_FILE="${ETCD_SSL}/etcd-${NODE}.key"
EOF

  cat > /etc/systemd/system/etcd.service <<'EOF'
[Unit]
Description=etcd key-value store
Documentation=https://github.com/etcd-io/etcd
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd
EnvironmentFile=/etc/etcd/etcd.env
ExecStart=/usr/local/bin/etcd
Restart=always
RestartSec=10s
LimitNOFILE=40000
User=etcd
Group=etcd

[Install]
WantedBy=multi-user.target
EOF
  svc daemon-reload
  svc enable etcd >/dev/null 2>&1 || true
  c_ok "etcd configured"
}

etcd_ctl() {
  etcdctl --endpoints="https://${NODE_IP}:${ETCD_CLIENT_PORT}" \
    --cacert="$ETCD_SSL/ca.crt" --cert="$ETCD_SSL/etcd-${NODE}.crt" --key="$ETCD_SSL/etcd-${NODE}.key" "$@"
}

start_etcd() {
  c_step "6. Starting etcd"
  if [[ $SKIP_SERVICES -eq 1 ]]; then c_warn "SKIP_SERVICES: etcd start skipped"; return 0; fi
  # IMPORTANT: etcd is Type=notify and only becomes "ready" at quorum (>=2 nodes).
  # We start it non-blocking so a node launched alone doesn't make systemctl fail.
  systemctl enable etcd >/dev/null 2>&1 || true
  systemctl start --no-block etcd || true
  c_warn "etcd started (non-blocking). Quorum forms as soon as >=2 nodes are up."
  c_info "Waiting for local etcd health (max ~30s, non-blocking for the deployment)..."
  local i
  for i in $(seq 1 15); do
    etcd_ctl endpoint health &>/dev/null && { c_ok "local etcd healthy (quorum OK)"; return 0; }
    sleep 2
  done
  c_warn "Quorum not formed yet (normal if db2/db3 are not deployed yet)."
}

# =============================================================================
# 7. Patroni configuration
# =============================================================================
configure_patroni() {
  c_step "7. Patroni configuration"
  mkdir -p "$PG_DATA" "$PG_SSL" /etc/patroni
  chown -R postgres:postgres /var/lib/postgresql
  chmod 700 "$PG_DATA"

  cat > /etc/patroni/config.yml <<EOF
scope: ${CLUSTER_NAME}
namespace: /service/
name: ${NODE}

etcd3:
  hosts: ${DB1_IP}:${ETCD_CLIENT_PORT},${DB2_IP}:${ETCD_CLIENT_PORT},${DB3_IP}:${ETCD_CLIENT_PORT}
  protocol: https
  cacert: ${ETCD_SSL}/ca.crt
  cert: ${ETCD_SSL}/etcd-${NODE}.crt
  key: ${ETCD_SSL}/etcd-${NODE}.key

restapi:
  listen: 0.0.0.0:${PATRONI_API_PORT}
  connect_address: ${NODE_IP}:${PATRONI_API_PORT}
  certfile: ${PG_SSL}/server.pem
  authentication:
    username: patroni
    password: '${PATRONI_RESTAPI_PASSWORD}'

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      parameters:
        ssl: 'on'
        ssl_cert_file: ${PG_SSL}/server.crt
        ssl_key_file: ${PG_SSL}/server.key
        password_encryption: 'scram-sha-256'
        max_connections: 100
        shared_buffers: 256MB
      pg_hba:
        - hostssl replication replicator 127.0.0.1/32 scram-sha-256
        - hostssl replication replicator ${SUBNET} scram-sha-256
        - hostssl all all 127.0.0.1/32 scram-sha-256
        - hostssl all all ${SUBNET} scram-sha-256
$( [[ "$APP_SUBNET" != "$SUBNET" ]] && echo "        - hostssl all all ${APP_SUBNET} scram-sha-256" )
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:${PG_PATRONI_PORT}
  connect_address: ${NODE_IP}:${PG_PATRONI_PORT}
  data_dir: ${PG_DATA}
  bin_dir: ${PG_BIN}
  authentication:
    superuser:
      username: postgres
      password: '${PG_SUPERUSER_PASSWORD}'
    replication:
      username: replicator
      password: '${PG_REPLICATOR_PASSWORD}'
tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
EOF
  chown postgres:postgres /etc/patroni/config.yml
  chmod 600 /etc/patroni/config.yml

  # Dedicated systemd unit (independent of the Debian package quirks)
  cat > /etc/systemd/system/patroni.service <<'EOF'
[Unit]
Description=Patroni PostgreSQL HA orchestrator
After=network-online.target etcd.service
Wants=network-online.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/bin/patroni /etc/patroni/config.yml
Restart=on-failure
RestartSec=5s
LimitNOFILE=40000
KillMode=process
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
  svc daemon-reload
  svc enable patroni >/dev/null 2>&1 || true
  c_ok "Patroni configured"
}

leader_exists() { etcd_ctl get "/service/${CLUSTER_NAME}/leader" --print-value-only 2>/dev/null | grep -q .; }

start_patroni() {
  c_step "8. Starting Patroni"
  # On a replica, we wait (non-blocking) for a leader to emerge. Patroni handles
  # the bootstrap race itself: starting concurrently is safe.
  if [[ $IS_DB1 -eq 0 ]]; then
    c_info "Waiting for a Patroni leader (max 60s)..."
    for _ in $(seq 1 30); do leader_exists && break; sleep 2; done
    leader_exists && c_ok "Leader detected" || c_warn "No leader yet — Patroni will wait/retry."
  fi
  svc restart patroni
  c_info "Wait ~15s then: patronictl -c /etc/patroni/config.yml list"
}

# =============================================================================
# 9. HAProxy
# =============================================================================
configure_haproxy() {
  c_step "9. HAProxy configuration"
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log    local0
    log /dev/log    local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    timeout tunnel  1h

frontend postgres_frontend
    bind *:${PG_HAPROXY_PORT}
    mode tcp
    default_backend postgres_backend

backend postgres_backend
    mode tcp
    balance first
    option tcpka
    option httpchk GET /primary
    http-check expect status 200
    server ${DB1_NAME} ${DB1_IP}:${PG_PATRONI_PORT} check port ${PATRONI_API_PORT} check-ssl verify none inter 2s fall 2 rise 2
    server ${DB2_NAME} ${DB2_IP}:${PG_PATRONI_PORT} check port ${PATRONI_API_PORT} check-ssl verify none inter 2s fall 2 rise 2
    server ${DB3_NAME} ${DB3_IP}:${PG_PATRONI_PORT} check port ${PATRONI_API_PORT} check-ssl verify none inter 2s fall 2 rise 2
EOF
  svc enable haproxy >/dev/null 2>&1 || true
  svc restart haproxy
  c_ok "HAProxy configured and started (port ${PG_HAPROXY_PORT})"
}

# =============================================================================
# 10. Keepalived
# =============================================================================
configure_keepalived() {
  c_step "10. Keepalived configuration"
  cat > /etc/keepalived/check_haproxy.sh <<EOF
#!/bin/bash
PORT=${PG_HAPROXY_PORT}
if ! pidof haproxy > /dev/null; then echo "HAProxy is not running"; exit 1; fi
if ! ss -ltn | grep -q ":\${PORT}"; then echo "HAProxy not listening on \${PORT}"; exit 2; fi
if ! curl -skf --max-time 2 https://127.0.0.1:${PATRONI_API_PORT}/primary > /dev/null 2>&1; then exit 3; fi
exit 0
EOF
  id keepalived_script &>/dev/null || useradd -r -s /bin/false keepalived_script
  chown keepalived_script:keepalived_script /etc/keepalived/check_haproxy.sh
  chmod 700 /etc/keepalived/check_haproxy.sh

  cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    enable_script_security
    script_user keepalived_script
}

vrrp_script check_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 2
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state ${VRRP_STATE}
    interface ${IFACE}
    virtual_router_id ${VRRP_ROUTER_ID}
    priority ${VRRP_PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${VRRP_AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}
    }
    track_script {
        check_haproxy
    }
}
EOF
  svc enable keepalived >/dev/null 2>&1 || true
  svc restart keepalived
  c_ok "Keepalived configured (${VRRP_STATE}/${VRRP_PRIORITY}, VIP ${VIP} on ${IFACE})"
}

# =============================================================================
# 11. etcd backup (db1 only)
# =============================================================================
setup_etcd_backup() {
  [[ $IS_DB1 -eq 1 ]] || return 0
  c_step "11. etcd backup (cron on ${DB1_NAME})"
  cat > /usr/local/bin/etcd-backup.sh <<EOF
#!/bin/bash
BACKUP_DIR="/var/backups/etcd"
DATE=\$(date +%F)
mkdir -p "\${BACKUP_DIR}"
etcdctl snapshot save "\${BACKUP_DIR}/etcd-\${DATE}.db" \\
  --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT} \\
  --cacert=${ETCD_SSL}/ca.crt --cert=${ETCD_SSL}/etcd-${DB1_NAME}.crt --key=${ETCD_SSL}/etcd-${DB1_NAME}.key
etcdctl snapshot status "\${BACKUP_DIR}/etcd-\${DATE}.db" --write-out=table
find "\${BACKUP_DIR}" -name 'etcd-*.db' -mtime +30 -delete
echo "Backup completed: \${BACKUP_DIR}/etcd-\${DATE}.db"
EOF
  chmod +x /usr/local/bin/etcd-backup.sh
  echo '0 2 * * * root /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1' > /etc/cron.d/etcd-backup
  c_ok "Daily etcd backup scheduled (02:00)"
}

# =============================================================================
# Final message / sync instructions
# =============================================================================
final_message() {
  c_step "Done for ${NODE}"
  if [[ $IS_DB1 -eq 1 ]]; then
    cat <<EOF
${NODE} configured. Next steps:

  1) Copy the certificate packages to db2 and db3 (interactive auth password + 2FA):
       scp ${SCRIPT_DIR}/certs-${DB2_NAME}.tar.gz <user>@${DB2_IP}:/tmp/
       scp ${SCRIPT_DIR}/certs-${DB3_NAME}.tar.gz <user>@${DB3_IP}:/tmp/

  2) On db2 then db3: copy this repository + cluster.env, then
       sudo ./deploy.sh ${DB2_NAME}
       sudo ./deploy.sh ${DB3_NAME}

  3) Verify the cluster:
       patronictl -c /etc/patroni/config.yml list
       PGPASSWORD='<superuser>' psql -h ${VIP} -U postgres -c 'SELECT pg_is_in_recovery();'
EOF
  else
    cat <<EOF
${NODE} configured and joined the cluster. Verify:
       patronictl -c /etc/patroni/config.yml list
EOF
  fi
}

# =============================================================================
# Orchestration
# =============================================================================
main() {
  system_update
  install_packages
  install_etcd
  setup_certs
  configure_etcd
  start_etcd
  configure_patroni
  start_patroni
  configure_haproxy
  configure_keepalived
  setup_etcd_backup
  final_message
}
main "$@"
