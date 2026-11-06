# AWS: the Nitro parent as the mesh node

On AWS the signer runs in a Nitro enclave. The enclave has no network. The
parent instance runs tee-signer's forwarder (`platform-aws/cmd/forwarder`),
which copies TCP on port 7100 to the enclave's vsock port. The mutual TLS
ends inside the enclave, so the parent sees only TLS bytes.

```
mesh --> parent instance (mesh name signer-3) --TCP 7100--> forwarder --vsock 16:7100--> runner in the enclave
```

The parent is already outside the trust boundary, so the mesh node goes on
the parent itself. No extra instance is needed.

## Steps

1. Deploy the signer with tee-signer's `platform-aws/deploy` (`main.tf`,
   `parent-run.sh`). Leave `entry_cidrs` empty: no inbound rule for TCP 7100.
2. Copy `parent-mesh.sh` to the parent and run it with a one-time, tagged
   auth key on stdin:

   ```sh
   ssh <PARENT> 'bash parent-mesh.sh' < <ONE_TIME_KEY_FILE>
   ```

   It prints the node's mesh IP and checks that the forwarder listens.
3. From the operator host: `docker compose exec mesh tailscale nc signer-3 7100`
   opens a connection (it waits for TLS; stop it with Ctrl+C). The gateway
   then logs `signer attested` for `aws`.

## Outbound rules

`main.tf` allows the parent outbound TCP 443 and, with `nts_egress`, the NTS
clock's ports. That is enough for the mesh: it then uses relayed paths over
TCP 443. For direct UDP paths, add a rule with `extra_egress`, for example:

```hcl
extra_egress = [
  { description = "mesh direct paths", protocol = "udp", from_port = 41641, to_port = 41641, cidr_blocks = ["0.0.0.0/0"] },
]
```

The enclave still reaches only the routes of its setup.

## Notes

- SSH to the parent is only needed for this setup. Open TCP 22 for your IP
  for the duration and close it after, or use SSM Session Manager.
- The forwarder allows 16 new connections from one source address in their
  first 15 s. All of the gateway's connections come from its one mesh
  address. The default `signers.connections: 2` stays far below that.
- Without the mesh (README, "Other network options"): set `entry_cidrs` to the gateway host's address, or use a
  VPN into the VPC, and point the gateway at the parent's address on 7100.
