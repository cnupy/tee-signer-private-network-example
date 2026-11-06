#!/bin/sh
# Entry of the mesh container in the Azure gateway group (a Standard group,
# not a TEE). Mesh TCP 7100 on this node goes to the signer's private DNS
# name, port 7100. The gateway group sees only TLS; the operator's gateway
# checks the signer's mutual TLS and attestation end to end.
#
# RELAY_MODE=direct (default): the serve config forwards straight to
#   SIGNER_FQDN:7100. It followed a signer IP change in a test, once the DNS
#   updater moved the record.
# RELAY_MODE=nc: the serve config forwards to a local busybox nc relay, which
#   resolves SIGNER_FQDN again for every connection. An option if the direct
#   forward ever keeps an old address.
set -eu
: "${SIGNER_FQDN:?SIGNER_FQDN not set}"
mode="${RELAY_MODE:-direct}"
mkdir -p /serve
if [ "$mode" = direct ]; then
  target="$SIGNER_FQDN:7100"
else
  target="127.0.0.1:7101"
  (
    while :; do
      nc -lk -s 127.0.0.1 -p 7101 -e nc "$SIGNER_FQDN" 7100 || true
      echo "relay: stopped, restarting" >&2
      sleep 1
    done
  ) &
fi
printf '{"TCP":{"7100":{"TCPForward":"%s"}}}\n' "$target" >/serve/serve.json
echo "relay: mesh 7100 -> $target (signer $SIGNER_FQDN, mode $mode)"
exec /usr/local/bin/containerboot
