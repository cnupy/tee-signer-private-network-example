#!/bin/sh
# Entry point of the mesh sidecar (tailscale/tailscale image) on the operator
# host. It starts tailscaled, logs in once with a one-time auth key, and
# forwards local ports to signers by mesh name:
#
#   MESH_FORWARD="7101=signer-1:7100 7102=signer-2:7100 7103=signer-3:7100"
#
# The gateway shares this container's network namespace and dials
# 127.0.0.1:7101 and so on. Each connection goes through `tailscale nc` to the
# named node. Names stay the same when a node joins again; mesh IPs may not.
#
# The mesh only carries bytes. The gateway's mutual TLS and attestation check
# run end to end, inside each signer's TEE.
set -eu

sock=/var/run/tailscale/tailscaled.sock
key=/run/secrets/ts_authkey
mkdir -p /var/run/tailscale /var/lib/tailscale

tailscaled --state=/var/lib/tailscale/tailscaled.state --socket="$sock" &
daemon=$!
trap 'kill -TERM "$daemon" 2>/dev/null || true' TERM INT

tries=0
while [ ! -S "$sock" ]; do
  tries=$((tries + 1))
  [ "$tries" -le 100 ] || { echo "mesh: tailscaled did not start" >&2; exit 1; }
  sleep 0.1
done

# With saved state the node logs in without a key. The key is needed only
# for the first join; delete the file after that.
if [ -s "$key" ]; then
  echo "mesh: logging in as $TS_HOSTNAME with tags $TS_TAGS"
  tailscale --socket="$sock" up \
    --auth-key="file:$key" \
    --hostname="$TS_HOSTNAME" \
    --advertise-tags="$TS_TAGS" \
    --accept-dns=false \
    --shields-up || echo "mesh: login failed, tailscaled keeps running" >&2
else
  echo "mesh: no auth key, using saved state"
fi

# Some paths drop packets above about 1300 bytes, and TLS handshakes then
# stall. A smaller MTU here makes TCP announce a smaller MSS, so the replies
# fit.
mtu="${TS_TUN_MTU:-1200}"
tries=0
while ! ip link show tailscale0 >/dev/null 2>&1 && [ "$tries" -lt 100 ]; do
  tries=$((tries + 1))
  sleep 0.1
done
ip link set tailscale0 mtu "$mtu" && echo "mesh: tailscale0 mtu $mtu" ||
  echo "mesh: could not set the tailscale0 mtu" >&2

for f in ${MESH_FORWARD:-}; do
  lp=${f%%=*}; dst=${f#*=}; host=${dst%:*}; port=${dst##*:}
  echo "mesh: 127.0.0.1:$lp -> $host:$port"
  (
    while :; do
      nc -lk -s 127.0.0.1 -p "$lp" -e tailscale --socket="$sock" nc "$host" "$port" || true
      echo "mesh: forward $lp stopped, restarting" >&2
      sleep 1
    done
  ) &
done

status=0
wait "$daemon" || status=$?
exit "$status"
