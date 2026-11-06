# Azure: confidential container group in a VNet, reached through a gateway group

The signer is a confidential container group (ACI, `sku: Confidential`)
deployed by tee-signer's `platform-azure/deploy/deploy.sh` with a private IP
in a subnet (`SUBNET_ID_N`) and no public IP. A second, ordinary container
group in another subnet of the same VNet carries the mesh and relays TCP 7100
to the signer. This is the "virtual network with a separate forwarder" option
in `platform-azure/deploy/README.md`, "Network entry".

```
mesh --> gateway group (Standard ACI, mesh name signer-2) --TCP 7100--> signer-2.example.internal --> signer group (Confidential ACI, private IP)
                 \-- dns-updater keeps signer-2.example.internal = the signer group's IP
signer subnet and gateway subnet --NAT gateway--> internet
```

Nothing but the runner listens in the signer group. The relay sits outside
the measured group, which is fine: the network is not trusted.

## Values

| Placeholder | Example |
|---|---|
| `<RG>`, `<LOCATION>` | resource group and region |
| `<VNET>` | `signer-vnet`, for example `198.51.100.0/24` |
| `<SIGNER_SUBNET>` | `signer-subnet`, for example `198.51.100.0/28`, delegated to `Microsoft.ContainerInstance/containerGroups` |
| `<GW_SUBNET>` | `gw-subnet`, for example `198.51.100.16/28`, same delegation |
| `<SIGNER_GROUP>` | the signer's container group name |
| zone, record | `example.internal`, `signer-2` |

## Steps

1. Network: the VNet with both subnets, a NAT gateway attached to both (the
   signer needs outbound access for the attestation provider, Key Vault, the
   identity endpoint and the clock; the gateway group needs it for the mesh),
   and a network security group on the signer subnet that allows TCP 7100 from
   `<GW_SUBNET>` and denies other inbound traffic.

2. Signer: deploy the group with tee-signer's `deploy.sh group-deploy N` and
   `SUBNET_ID_N=<signer subnet ID>`. The subnet setting is a group property,
   so it does not change the CCE policy hash.

3. Private DNS: a private zone `example.internal` linked to the VNet, with an
   A record `signer-2` that holds the signer group's IP.

4. Identity for the DNS updater: a user-assigned identity with `Reader` on the
   signer container group and `Private DNS Zone Contributor` scoped to the one
   record set `signer-2` (not the whole zone).

5. Gateway group:

   ```sh
   az deployment group create -g <RG> --template-file gateway-group.json \
     --parameters subnetId=<GW_SUBNET_ID> identityId=<IDENTITY_RESOURCE_ID> \
       identityClientId=<IDENTITY_CLIENT_ID> signerGroup=<SIGNER_GROUP> \
       ipPrefix=198.51.100. \
       relayEntryB64="$(base64 -w0 relay-entry.sh)" \
       dnsUpdaterB64="$(base64 -w0 dns-updater.sh)" \
     --parameters @<SECRET_PARAMETERS_FILE>
   ```

   `<SECRET_PARAMETERS_FILE>` is a mode 600 ARM parameters file that holds
   only `meshAuthKey`. The key never goes on the command line.

6. Check: `az container logs -g <RG> -n signer-2-gw --container-name mesh`
   shows `relay: mesh 7100 -> ...`, and the `dns-updater` container logs the
   record it watches.

## Notes

- The gateway group keeps no mesh state, so it joins the mesh again after
  every restart. Use a tagged, ephemeral, pre-approved auth key that can be
  used again, or an OAuth client that can mint such keys, and limit it to the
  one tag of this signer.
- `RELAY_MODE=direct` (default) forwards straight to the signer's name. In a
  test it followed a signer IP change once the DNS updater had fixed the
  record (within `INTERVAL` seconds). `RELAY_MODE=nc` resolves the name again
  for every connection, an option if the direct forward ever keeps an old
  address.
- Path MTU: a path through the mesh can drop packets above about 1300 bytes,
  and TLS handshakes then stall. The operator side sets MTU 1200
  (`TS_TUN_MTU` in `compose.yaml`).
- Docker Hub limits anonymous pulls. Copy the images to your own registry and
  add `imageRegistryCredentials` to the template if a restart hits that limit.
- A VPN gateway or Private Link instead of the gateway group works the same
  way: the operator's gateway only needs a route to the signer's private IP.
