#!/usr/bin/env bash
# Runs on the Nitro parent instance (Amazon Linux 2023). Installs Tailscale
# and joins the mesh, so the forwarder's TCP port (7100, started by
# tee-signer's platform-aws/deploy/parent-run.sh) is reachable at this node's
# mesh name. It changes nothing in the enclave and does not restart it.
#
# The parent is not trusted. The mesh carries bytes to the forwarder, the
# forwarder copies them over vsock, and the mutual TLS ends inside the
# enclave.
#
# The auth key comes on stdin, never as an argument:
#   ssh <PARENT> 'bash parent-mesh.sh' <one-time-key-file    # first join
#   ssh <PARENT> 'bash parent-mesh.sh' </dev/null            # later runs
# Use a tagged, pre-approved, one-time key. The node keeps its state on disk
# and rejoins after a reboot without a key.
#
# Settings: TS_HOSTNAME (default signer-3), TS_TAGS (default
# tag:<TS_HOSTNAME>), TS_MTU (default 1280).
set -euo pipefail
TS_HOSTNAME="${TS_HOSTNAME:-signer-3}"
TS_TAGS="${TS_TAGS:-tag:$TS_HOSTNAME}"
TS_MTU="${TS_MTU:-1280}"
die() { echo "parent-mesh.sh: $*" >&2; exit 1; }

[[ "$TS_TAGS" =~ ^tag:[a-z0-9][a-z0-9-]*(,tag:[a-z0-9][a-z0-9-]*)*$ ]] || die "TS_TAGS=$TS_TAGS is not a list of tags"

if ! command -v tailscale >/dev/null 2>&1; then
  sudo curl -fsSL -o /etc/yum.repos.d/tailscale.repo \
    https://pkgs.tailscale.com/stable/amazon-linux/2023/tailscale.repo
  sudo dnf install -y tailscale
fi
command -v jq >/dev/null 2>&1 || sudo dnf install -y jq
sudo systemctl enable --now tailscaled

umask 077
keyfile="$(mktemp)"
trap 'shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"' EXIT
[ -t 0 ] || cat >"$keyfile"

backend=""
for _ in $(seq 1 30); do
  backend="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)"
  if [ -n "$backend" ] && [ "$backend" != NoState ]; then break; fi
  sleep 1
done

# The parent keeps its own DNS and routes; it only needs to be reached.
up=(sudo tailscale up --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAGS" --accept-dns=false --accept-routes=false)
if [ "$backend" != Running ]; then
  [ -s "$keyfile" ] || die "not logged in and no auth key on stdin"
  up+=(--auth-key="file:$keyfile")
fi
"${up[@]}"

# Tailscale adds "-1" when the name is taken by an old node.
name="$(tailscale status --json | jq -r '.Self.DNSName // empty' | cut -d. -f1)"
[ "${name,,}" = "${TS_HOSTNAME,,}" ] ||
  die "this node is named '$name', not '$TS_HOSTNAME': delete the old node and run again"

# Smaller packets on the mesh path; see "An overlay network on the parent"
# in platform-aws/deploy/README.md.
sudo ip link set tailscale0 mtu "$TS_MTU" || echo "parent-mesh.sh: could not set the MTU" >&2

ss -ltn | grep -q ':7100 ' && echo "forwarder listens on 7100" || echo "parent-mesh.sh: nothing listens on 7100; start parent-run.sh" >&2
tailscale ip -4
