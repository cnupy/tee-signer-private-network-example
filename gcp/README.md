# GCP: private signer VM behind a gateway VM

The signer is a Confidential Space VM with no external IP, deployed by
tee-signer's `platform-gcp/deploy/deploy.sh` with `NETWORK_ENTRY=private`. A
small gateway VM in the same VPC joins the mesh and serves TCP 7100 to the
signer's private IP. It can also be the signer's way out to the internet, with
a filter on what the signer may send.

```
mesh --> gateway VM (tag signer-gw, mesh name signer-1) --TCP 7100--> signer VM (tag signer-node, no external IP)
signer VM --default route for tag signer-node--> gateway VM --NAT, filtered--> internet
```

The gateway VM is not trusted. It sees TLS bytes and nothing else. If it is
replaced by a VPN gateway, an internal load balancer or a public IP with a
firewall rule, the gateway config on the operator host only changes the
signer's address.

## Values

| Placeholder | Example |
|---|---|
| `<PROJECT_ID>` | your project |
| `<REGION>`, `<ZONE>` | `us-central1`, `us-central1-a` |
| `<NETWORK>` | the VPC of the signer (tee-signer's default: `signer-net`) |
| `<SIGNER_SUBNET>` | the signer's subnet, for example `192.0.2.0/28` |
| `<SIGNER_IP>` | the signer VM's private IP, for example `192.0.2.2` |
| `<GW_SUBNET>` | a subnet for the gateway VM |

## Steps

1. Deploy the signer with tee-signer's `platform-gcp/deploy/deploy.sh`,
   `NETWORK_ENTRY=private`, `PRIVATE_IP=<SIGNER_IP>` and
   `ENTRY_SOURCE_TAGS=signer-gw`. That gives the VM no external address and
   opens TCP 7100 from the tag `signer-gw` only. Turn on Private Google Access
   on the signer subnet. See "Network entry" and "Outbound internet" in
   `platform-gcp/deploy/README.md`.

2. Make the gateway VM. It forwards packets for the signer, so it needs
   `--can-ip-forward`, and an external IP (or Cloud NAT) for its own way out.

   ```sh
   gcloud compute instances create signer-gw-1 \
     --project=<PROJECT_ID> --zone=<ZONE> \
     --machine-type=e2-micro --image-family=debian-12 --image-project=debian-cloud \
     --subnet=<GW_SUBNET> --can-ip-forward --tags=signer-gw \
     --metadata-from-file=startup-script=gateway-vm-startup.sh,ts-authkey=<PATH_TO_ONE_TIME_KEY> \
     --metadata=fwd-target=<SIGNER_IP>,signer-cidr=<SIGNER_SUBNET>,ts-hostname=signer-1,http-hosts=<CERT_HOSTS>
   ```

   After the VM logs `joined as signer-1`, remove the key:
   `gcloud compute instances remove-metadata signer-gw-1 --zone=<ZONE> --keys=ts-authkey`.

3. Route the signer's traffic through the gateway VM, and let the gateway VM
   take it in:

   ```sh
   gcloud compute routes create signer-via-gw --network=<NETWORK> \
     --destination-range=0.0.0.0/0 --next-hop-instance=signer-gw-1 \
     --next-hop-instance-zone=<ZONE> --tags=signer-node --priority=900
   gcloud compute firewall-rules create signer-gw-forward --network=<NETWORK> \
     --direction=INGRESS --source-tags=signer-node --target-tags=signer-gw \
     --allow=tcp:443,tcp:4460,tcp:80,udp:123,udp:4123
   ```

   Requests to Google APIs still take Private Google Access.

4. Check the serial log of the gateway VM for `serve tcp 7100 -> <SIGNER_IP>:7100`
   and `reach <SIGNER_IP>:7100 open` (the second one only once the signer is up).

## Egress of the signer

The signer needs TCP 443 (cloud APIs, registry, time sources), the NTS clock
(TCP 4460, UDP 123 and 4123) and TCP 80 to the hosts that serve the
Confidential Space launcher's certificate chain. The launcher fetches that
chain over plain HTTP. The certificates are signed, so HTTP is safe, but
blocking it stops the attestation token fetch and the signer never starts.

Two layers filter this:

- tee-signer's `egress-create` step adds VPC rules on the signer: allow the
  ports above, deny the rest.
- The gateway VM's nftables filter (`gateway-vm-startup.sh`) allows the same
  ports, and TCP 80 only to the addresses of the certificate hosts. It drops
  forwarded traffic to private and special ranges.

Find the certificate hosts in the AIA field ("CA Issuers") of the signer VM's
attestation key certificate, for example:

```sh
gcloud compute instances get-shielded-identity <SIGNER_VM> --zone=<ZONE> \
  --format='value(signingKey.ekCert)' | openssl x509 -noout -text | grep -A1 'CA Issuers'
```

They look like `privateca-content-<ID>.storage.googleapis.com`. Put them in the
`http-hosts` metadata of the gateway VM. The refresh timer reads it every
5 minutes, so a change needs no reboot.

Without the gateway VM as NAT, give the signer subnet Cloud NAT, keep
tee-signer's egress rules, and leave `signer-cidr` out of the metadata. The
startup script then sets up the mesh only.

## Mesh notes

- `--accept-dns=false`: the gateway VM keeps Google's resolver. With mesh DNS
  and no upstream, the TCP 80 allowlist could not resolve its hosts.
- Mesh traffic needs only outbound connections from the gateway VM. No
  inbound firewall rule is needed. Without a UDP path the mesh relays over
  TCP 443, which is slower but works.
- The VM keeps its mesh state on disk, so a reboot rejoins without a key.
