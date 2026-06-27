#!/usr/bin/env bash
# =============================================================================
# preflight.sh — Checks BEFORE deployment (run on each node).
#
# Usage:   sudo ./preflight.sh <db1|db2|db3>
#
# Verifies: cluster.env consistent, secrets filled in, VIP within the subnet,
# network interface present, correct node IP, reachability of the other
# nodes, free ports, resources, clock sync. Writes NOTHING.
# Exits with an error (code 1) if a BLOCKING check fails.
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/cluster.env"

R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; Z=$'\033[0m'
HARD=0; SOFT=0
pass(){ echo "  ${G}[ OK ]${Z} $*"; }
fail(){ echo "  ${R}[FAIL]${Z} $*"; HARD=1; }
warn(){ echo "  ${Y}[WARN]${Z} $*"; SOFT=$((SOFT+1)); }
sect(){ printf '\n%s== %s ==%s\n' "$C" "$*" "$Z"; }

# --- ipv4 helpers ------------------------------------------------------------
ip2int(){ local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24)|(b<<16)|(c<<8)|d )); }
in_cidr(){ # $1=ip  $2=a.b.c.d/NN
  local ip="$1" net="${2%/*}" bits="${2#*/}" mask
  mask=$(( bits==0 ? 0 : (0xFFFFFFFF << (32-bits)) & 0xFFFFFFFF ))
  (( ($(ip2int "$ip") & mask) == ($(ip2int "$net") & mask) ))
}

sect "Base"
[[ $EUID -eq 0 ]] && pass "running as root" || fail "must run as root (sudo)"
[[ -f "$ENV_FILE" ]] && pass "cluster.env present" || { fail "cluster.env missing (cp cluster.env.example cluster.env)"; echo; echo "${R}Preflight stopped.${Z}"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

NODE="${1:-}"
case "$NODE" in
  "$DB1_NAME") NODE_IP="$DB1_IP" ;;
  "$DB2_NAME") NODE_IP="$DB2_IP" ;;
  "$DB3_NAME") NODE_IP="$DB3_IP" ;;
  *) fail "invalid node argument '${NODE:-}' (expected: $DB1_NAME|$DB2_NAME|$DB3_NAME)"; echo; echo "${R}Preflight stopped.${Z}"; exit 1 ;;
esac
pass "target node: $NODE ($NODE_IP)"

sect "Required tools"
for t in ip ss openssl awk tar curl ping; do
  command -v "$t" >/dev/null 2>&1 && pass "$t present" || fail "$t missing (apt install)"
done

sect "cluster.env consistency"
for v in CLUSTER_NAME PG_VERSION ETCD_VERSION SUBNET VIP IFACE \
         DB1_IP DB2_IP DB3_IP DB1_NAME DB2_NAME DB3_NAME \
         PG_SUPERUSER_PASSWORD PG_REPLICATOR_PASSWORD PATRONI_RESTAPI_PASSWORD VRRP_AUTH_PASS; do
  [[ -n "${!v:-}" ]] && pass "$v set" || fail "$v empty"
done
# Unreplaced placeholders
for v in PG_SUPERUSER_PASSWORD PG_REPLICATOR_PASSWORD PATRONI_RESTAPI_PASSWORD VRRP_AUTH_PASS; do
  case "${!v:-}" in *CHANGE_ME*) fail "$v still contains 'CHANGE_ME' — generate a real secret";; esac
done
# VRRP auth_pass length (max 8)
if [[ -n "${VRRP_AUTH_PASS:-}" ]]; then
  (( ${#VRRP_AUTH_PASS} <= 8 )) && pass "VRRP_AUTH_PASS <= 8 characters" || fail "VRRP_AUTH_PASS = ${#VRRP_AUTH_PASS} chars (VRRP truncates to 8)"
fi
# VIP within the subnet
if in_cidr "$VIP" "$SUBNET"; then pass "VIP $VIP belongs to $SUBNET"; else fail "VIP $VIP OUTSIDE $SUBNET (apps via HAProxy won't match any pg_hba rule)"; fi
# Nodes within the subnet
for ip in "$DB1_IP" "$DB2_IP" "$DB3_IP"; do
  in_cidr "$ip" "$SUBNET" && pass "$ip in $SUBNET" || warn "$ip outside $SUBNET (check)"
done
# Identical secrets across nodes: reminder
warn "verify that cluster.env is IDENTICAL on all 3 nodes (secrets included)"

sect "Local network"
if ip link show "$IFACE" >/dev/null 2>&1; then
  pass "interface $IFACE present"
else
  fail "interface $IFACE missing — fix IFACE (seen: $(ip -o link show | awk -F': ' '{print $2}' | paste -sd' ' -))"
fi
if ip -4 addr show 2>/dev/null | grep -qw "$NODE_IP"; then
  pass "node IP $NODE_IP configured locally"
else
  fail "IP $NODE_IP not found on this machine (wrong node? wrong IP?)"
fi
# The VIP must NOT already exist before deployment
if ip -4 addr show 2>/dev/null | grep -qw "$VIP"; then
  warn "VIP $VIP already present locally (normal if Keepalived is already deployed here)"
else
  pass "VIP $VIP not yet up (expected before deployment)"
fi

sect "Reachability of the other nodes (ping)"
for n in "$DB1_NAME:$DB1_IP" "$DB2_NAME:$DB2_IP" "$DB3_NAME:$DB3_IP"; do
  nm="${n%%:*}"; ip="${n##*:}"
  [[ "$ip" == "$NODE_IP" ]] && continue
  if ping -c1 -W2 "$ip" >/dev/null 2>&1; then pass "$nm ($ip) reachable"; else warn "$nm ($ip) does NOT respond to ping (ICMP firewall? node down?)"; fi
done

sect "Free local ports (before deployment)"
for p in "${ETCD_CLIENT_PORT}" "${ETCD_PEER_PORT}" "${PG_HAPROXY_PORT}" "${PG_PATRONI_PORT}" "${PATRONI_API_PORT}"; do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then
    warn "port $p already listening (possible conflict — unless re-deploying)"
  else
    pass "port $p free"
  fi
done

sect "Resources & system"
mem_g=$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
awk -v m="$mem_g" 'BEGIN{exit !(m+0>=3.5)}' && pass "RAM ${mem_g} GB (>=4 GB recommended)" || warn "RAM ${mem_g} GB (< 4 GB recommended)"
free_g=$(df -BG /var/lib 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo 0)
[[ "${free_g:-0}" -ge 10 ]] 2>/dev/null && pass "/var/lib space ${free_g} GB" || warn "low /var/lib space (${free_g:-?} GB)"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then
  pass "clock synchronized (NTP) — critical for etcd/Patroni"
else
  warn "clock NOT synchronized — enable chrony/systemd-timesyncd (drift = unstable failover)"
fi
# data_dir empty/absent (Patroni initializes it itself)
DD="/var/lib/postgresql/data"
if [[ ! -d "$DD" ]] || [[ -z "$(ls -A "$DD" 2>/dev/null)" ]]; then
  pass "data_dir $DD empty/absent (OK for bootstrap)"
else
  warn "data_dir $DD NOT empty — Patroni will refuse to initialize (empty it if this is a new cluster)"
fi
# GitHub access for the etcd binary (if not already installed)
if command -v etcd >/dev/null 2>&1 && etcd --version 2>/dev/null | grep -q "${ETCD_VERSION#v}"; then
  pass "etcd ${ETCD_VERSION} already installed"
elif curl -fsI --max-time 5 https://github.com >/dev/null 2>&1; then
  pass "github.com reachable (etcd download possible)"
else
  warn "github.com unreachable — preinstall the etcd binary manually"
fi

sect "Summary"
if [[ $HARD -ne 0 ]]; then
  echo "${R}✗ BLOCKING checks failed — fix before running deploy.sh${Z}"
  exit 1
elif [[ $SOFT -ne 0 ]]; then
  echo "${Y}⚠ $SOFT warning(s) — check them, but deployment is possible${Z}"
  echo "  Then run: sudo ./deploy.sh ${NODE} --no-upgrade"
  exit 0
else
  echo "${G}✓ All checks pass. Run: sudo ./deploy.sh ${NODE} --no-upgrade${Z}"
  exit 0
fi
