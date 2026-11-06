#!/bin/bash
# Startup script of the GCP gateway VM (Debian 12). Runs at every boot.
#
#   mesh    a Tailscale node that serves TCP 7100 to the signer VM's private
#           IP. Clients on the mesh reach the signer at <ts-hostname>:7100.
#   NAT     the signer subnet goes out through this VM (table ip sgwnat).
#   filter  forwarded traffic from the signer subnet may leave only on TCP
#           443 and 4460, UDP 123 and 4123, and TCP 80 to the addresses of
#           the launcher's certificate hosts (table inet sgw, set http_ok).
#           The Confidential Space launcher fetches the CA chain of its
#           attestation key over plain HTTP. Everything else is dropped and
#           counted.
#   refresh sgw-http-refresh.timer resolves the certificate hosts every 5 min
#           and adds each address with a 2 h timeout. A failed lookup keeps
#           the old addresses.
#
# Instance metadata:
#   fwd-target   the signer VM's private IP, for example 192.0.2.2
#   signer-cidr  the signer subnet, for example 192.0.2.0/28
#   ts-hostname  the mesh name, for example signer-1
#   ts-authkey   one-time auth key, first boot only. Remove it after the join.
#   http-hosts   the launcher's certificate hosts, space separated (see
#                gcp/README.md). Read again at every refresh.
#
# Skip NAT and filter (set no signer-cidr) when the signer subnet uses Cloud
# NAT and VPC egress rules instead. The mesh part works either way.
set -u
CONF_DIR=/etc/signer-gw
BIN_DIR=/usr/local/sbin
HTTP_TIMEOUT=2h
log() { echo "SIGNER-GW $*"; }
MD=http://metadata.google.internal/computeMetadata/v1/instance/attributes
md() { curl -fs -H Metadata-Flavor:Google "$MD/$1"; }

TARGET=$(md fwd-target); CIDR=$(md signer-cidr || true); NAME=$(md ts-hostname)
HTTP_HOSTS=$(md http-hosts || true)
IF=$(ip route show default | awk '{print $5; exit}')
[[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log "bad fwd-target '$TARGET'"; exit 1; }
[ -n "$IF" ] || { log "no default interface"; exit 1; }

if [ -n "$CIDR" ]; then
  [[ "$CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || { log "bad signer-cidr '$CIDR'"; exit 1; }
  [ -n "$HTTP_HOSTS" ] || log "no http-hosts: the launcher cannot fetch its certificates, the signer will not start"
  sysctl -qw net.ipv4.ip_forward=1
  # In and out of the same NIC: send no ICMP redirects to the signer.
  sysctl -qw net.ipv4.conf.all.send_redirects=0
  sysctl -qw "net.ipv4.conf.$IF.send_redirects=0"
  command -v nft >/dev/null || { apt-get -qq update && apt-get -qq install -y nftables; }

  mkdir -p "$CONF_DIR"
  printf '%s\n' "$HTTP_HOSTS" >"$CONF_DIR/http-hosts"
  printf 'HTTP_TIMEOUT=%s\nCONF_DIR=%s\n' "$HTTP_TIMEOUT" "$CONF_DIR" >"$CONF_DIR/env"

  # One file in one transaction: the old tables go and the new ones come in
  # together, so there is no moment without the filter.
  cat >"$CONF_DIR/sgw.nft" <<NFT
table ip sgwnat
delete table ip sgwnat
table ip sgwnat {
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $CIDR oifname "$IF" masquerade
  }
}
table inet sgw
delete table inet sgw
table inet sgw {
  set http_ok {
    type ipv4_addr
    flags timeout
  }
  set no_fwd {
    type ipv4_addr
    flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 }
  }
  counter http_denied { packets 0 bytes 0 }
  counter denied { packets 0 bytes 0 }
  chain from_signer {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    ip saddr != $CIDR counter name "denied" drop
    iifname != "$IF" counter name "denied" drop
    oifname != "$IF" counter name "denied" drop
    ip daddr @no_fwd counter name "denied" drop
    tcp dport { 443, 4460 } accept
    udp dport { 123, 4123 } accept
    tcp dport 80 ip daddr @http_ok accept
    tcp dport 80 counter name "http_denied" limit rate 6/minute burst 10 packets log prefix "SIGNER-GW http-deny " level warn drop
    tcp dport 80 drop
    counter name "denied" limit rate 6/minute burst 10 packets log prefix "SIGNER-GW deny " level warn drop
  }
}
NFT
  nft -f "$CONF_DIR/sgw.nft" && log "filter: nat $CIDR via $IF; out tcp 443 4460, udp 123 4123; tcp 80 only to http_ok" ||
    { log "nft load failed"; exit 1; }

  # The refresh: resolve each host a few times (DNS rotates the answers),
  # keep public IPv4 addresses only, add them with a timeout.
  cat >"$BIN_DIR/sgw-http-refresh" <<'REFRESH'
#!/bin/bash
set -u
. /etc/signer-gw/env
log() { echo "SIGNER-GW $*"; }
MD=http://metadata.google.internal/computeMetadata/v1/instance/attributes
h=$(curl -fs -m 5 -H Metadata-Flavor:Google "$MD/http-hosts" 2>/dev/null || true)
[ -z "$h" ] || printf '%s\n' "$h" >"$CONF_DIR/http-hosts"
read -r -a HOSTS <"$CONF_DIR/http-hosts"
# public_v4 A: A is a dotted IPv4 address outside the private and special ranges.
public_v4() {
  local a b c d x
  IFS=. read -r a b c d <<<"$1"
  for x in "$a" "$b" "$c" "$d"; do [[ "$x" =~ ^[0-9]{1,3}$ ]] && [ "$x" -le 255 ] || return 1; done
  if [ "$a" -eq 0 ] || [ "$a" -eq 10 ] || [ "$a" -eq 127 ] || [ "$a" -ge 224 ]; then return 1; fi
  if [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then return 1; fi
  if [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; then return 1; fi
  if [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; then return 1; fi
  if [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; then return 1; fi
  return 0
}
declare -A seen=()
for host in "${HOSTS[@]}"; do
  [[ "$host" =~ ^[a-z0-9.-]+$ ]] || { log "http-refresh: skip bad host name"; continue; }
  for _ in 1 2 3 4 5 6 7 8; do
    got=$(timeout 5 getent ahostsv4 "$host" 2>/dev/null | awk '$2 == "STREAM" { print $1 }') || true
    [ -n "$got" ] || { log "http-refresh: no answer for $host"; break; }
    while read -r ip; do
      if public_v4 "$ip"; then seen[$ip]=1; else log "http-refresh: $host gave non-public $ip, not added"; fi
    done <<<"$got"
  done
done
if [ "${#seen[@]}" = 0 ]; then
  log "http-refresh FAIL: no address; old entries stay until their timeout"
  exit 1
fi
# "add" keeps the old timeout of an element that is there, so delete first.
els=""
for ip in "${!seen[@]}"; do
  nft delete element inet sgw http_ok "{ $ip }" 2>/dev/null || true
  els="$els${els:+, }$ip timeout $HTTP_TIMEOUT"
done
nft add element inet sgw http_ok "{ $els }" || { log "http-refresh FAIL: nft add"; exit 1; }
log "http-refresh: ${#seen[@]} address(es) in http_ok"
REFRESH
  chmod 755 "$BIN_DIR/sgw-http-refresh"

  cat >/etc/systemd/system/sgw-http-refresh.service <<UNIT
[Unit]
Description=Refresh the signer TCP 80 allowlist
After=network-online.target
[Service]
Type=oneshot
ExecStart=$BIN_DIR/sgw-http-refresh
UNIT
  cat >/etc/systemd/system/sgw-http-refresh.timer <<'UNIT'
[Unit]
Description=Refresh the signer TCP 80 allowlist every 5 min
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now sgw-http-refresh.timer >/dev/null 2>&1 && log "timer sgw-http-refresh every 5 min"
fi

# Mesh. Pin the package version in production.
if ! command -v tailscale >/dev/null; then curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1; fi
systemctl enable --now tailscaled >/dev/null 2>&1
if ! tailscale status >/dev/null 2>&1; then
  K=$(mktemp); chmod 600 "$K"; md ts-authkey >"$K" || true
  if [ -s "$K" ]; then
    tailscale up --auth-key="file:$K" --hostname="$NAME" --accept-dns=false >/dev/null 2>&1 && log "joined as $NAME" || log "join failed"
  else
    log "no saved state and no ts-authkey"
  fi
  shred -u "$K"
fi
tailscale set --hostname="$NAME" >/dev/null 2>&1
# Keep the VM's own DNS. With mesh DNS and no upstream, the TCP 80
# allowlist could not resolve the certificate hosts.
tailscale set --accept-dns=false >/dev/null 2>&1 && log "accept-dns off"
[ -z "$CIDR" ] || systemctl start sgw-http-refresh.service >/dev/null 2>&1 || true
tailscale serve --bg --tcp 7100 "tcp://$TARGET:7100" >/dev/null 2>&1 && log "serve tcp 7100 -> $TARGET:7100"
if timeout 4 bash -c "</dev/tcp/$TARGET/7100" 2>/dev/null; then log "reach $TARGET:7100 open"; else log "reach $TARGET:7100 closed or filtered"; fi
log "ready $(tailscale ip -4 2>/dev/null)"
