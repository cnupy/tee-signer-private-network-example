#!/bin/sh
# DNS updater in the Azure gateway group. Every INTERVAL seconds it reads the
# signer group's private IP and makes the A record RECORD in the private zone
# ZONE hold that IP and nothing else. Azure can restart or move a container
# group on its own, and the group may come back with a new IP. This keeps the
# relay's target name right with no one at a terminal.
#
# Its managed identity needs read on the signer group and write on this one
# record set, nothing more.
#
# Idempotent: it adds the IP only when the record lacks it (Azure refuses a
# duplicate entry), then removes every other entry, so a second writer cannot
# leave a stale one behind.
set -u
: "${CLIENT_ID:?}" "${RG:?}" "${SIGNER_GROUP:?}" "${ZONE:?}" "${RECORD:?}" "${IP_PREFIX:?}"
every="${INTERVAL:-30}"
until az login --identity --client-id "$CLIENT_ID" -o none; do
  echo "dns-updater: login failed, retry in 30 s"
  sleep 30
done
echo "dns-updater: watching $RG/$SIGNER_GROUP -> $RECORD.$ZONE every ${every}s"
while :; do
  ip="$(az container show -g "$RG" -n "$SIGNER_GROUP" --query ipAddress.ip -o tsv 2>/dev/null || true)"
  cur="$(az network private-dns record-set a show -g "$RG" -z "$ZONE" -n "$RECORD" \
    --query 'aRecords[].ipv4Address' -o tsv 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)"
  case "$ip" in
    "$IP_PREFIX"*)
      if [ "$ip" != "$cur" ]; then
        echo "dns-updater: $RECORD.$ZONE '$cur' -> $ip"
        have=no
        for c in $cur; do [ "$c" = "$ip" ] && have=yes; done
        if [ "$have" = yes ] || az network private-dns record-set a add-record -g "$RG" -z "$ZONE" -n "$RECORD" -a "$ip" -o none; then
          for old in $cur; do
            [ "$old" = "$ip" ] || az network private-dns record-set a remove-record -g "$RG" -z "$ZONE" -n "$RECORD" \
              -a "$old" --keep-empty-record-set -o none || echo "dns-updater: remove $old failed, next round retries"
          done
        else
          echo "dns-updater: add $ip failed, next round retries"
        fi
      fi
      ;;
    "") ;;
    *) echo "dns-updater: signer IP '$ip' is outside $IP_PREFIX, record left alone" ;;
  esac
  sleep "$every"
done
