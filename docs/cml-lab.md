# CML Lab

The `basic-lab` CML lab is defined in OpenTofu (`opentofu/cml`) and its device
configuration is enforced by Ansible (`ansible/`).

```
                       Tailscale
                           |
 chronos1 ─┐           ┌ tsgw1 (subnet router, advertises 10.96.0.0/24)
 alpine2  ─┼─ vSwitch1 ┤
           │  (VLAN 10)└ vRouter1 ── external_connector1 (CML NAT) ── internet
```

| Device | Role | Address |
|---|---|---|
| vRouter1 (IOSv) | Gateway, DHCP server, PAT/NAT to the CML NAT network | `10.96.0.1` |
| vSwitch1 (IOSvL2) | L2 access switch, all ports in VLAN 10 `INTERNAL` | `10.96.0.2` (SVI) |
| chronos1 (Ubuntu), alpine2 (Alpine) | Plain DHCP clients | `10.96.0.21+` |
| tsgw1 (Ubuntu) | Tailscale subnet router so CI / your laptop can reach the lab | DHCP |

## Who owns what

| Layer | Tool | Where |
|---|---|---|
| Lab, nodes, links, start/stop | OpenTofu | `opentofu/cml/basic-lab.tf` |
| Tailscale ACL / route approval, gateway auth key | OpenTofu | `opentofu/tailscale/acl.tf`, `opentofu/cml/basic-lab.tf` |
| Device configuration (VLANs, ports, SVI, DHCP, NAT, ...) | Ansible | `ansible/inventories/cml-lab/`, `ansible/roles/cml_*` |

OpenTofu only injects a **bootstrap** day-0 config into the IOS devices: the
management IPs, an `ansible` user, SSH (including RSA key generation), and on
the router the minimal DHCP + NAT needed for `tsgw1` to get internet and join
Tailscale (Ansible can't reach the lab until it has). The same settings are
declared in YAML and enforced by Ansible, which is the source of truth: day-0 is
only the starting point, so keep it in sync but minimal. Changing the config of
a node that has already been started forces a node replacement.

## Changing the desired configuration

Edit the YAML and re-run the playbook:

- `ansible/inventories/cml-lab/host_vars/vrouter1.yml` - interfaces, NAT, DHCP
  pools, static routes
- `ansible/inventories/cml-lab/host_vars/vswitch1.yml` - VLANs, access ports,
  SVIs, default gateway
- `ansible/inventories/cml-lab/group_vars/cml_lab.yml` - connection settings,
  domain name

VLANs and interfaces use the `cisco.ios` resource modules with
`state: replaced`, so drift on the listed objects is corrected. Lines managed
through `ios_config` (NAT, ACL, DHCP, routes) are added idempotently but are
not removed when you delete them from YAML; remove them on the device with a
`no ...` command.

## Running the playbook

### Workflow

Run **Configure CML Lab** from the Actions tab. Options: `check_mode` for a dry
run and `limit` (a host or group). The runner joins the tailnet as `tag:ci`,
waits for `10.96.0.1`/`10.96.0.2` to answer on port 22, and runs the playbook.

### Locally

```bash
tailscale up --accept-routes          # reach 10.96.0.0/24 via tsgw1
export CML_DEVICE_PASSWORD=...        # same value as DEFAULT_VM_PASSWORD
cd ansible
ansible-galaxy collection install -r requirements.yml
pip install paramiko
ansible-playbook -i inventories/cml-lab playbooks/configure_cml_lab.yml --diff
# --check for a dry run, --limit vrouter1 for one device, --tags verify for checks only
```

## How reachability works

CML nodes are on isolated lab networks, so `tsgw1` runs Tailscale (installed
via cloud-init on first boot using an auth key created by OpenTofu) and
advertises `10.96.0.0/24`. The route is auto-approved for `tag:cml-lab`, and
the ACL allows `tag:ci` and members to reach `tcp:22` on that subnet. SNAT on
the subnet router means replies come back through `tsgw1`.

## Bring-up order

1. Merge/apply the `tailscale` stack (adds `tag:cml-lab`, the auto-approver and
   the grant). The `cml` stack creates an auth key for that tag, so if both
   stacks apply in the same run and `cml` fails on the tag, re-run the apply.
2. `cml` stack apply creates and **starts** the lab (`cml2_lifecycle`). It does
   not wait for the nodes to boot; IOSv and Ubuntu take a few minutes.
3. Run **Configure CML Lab**. It waits for SSH on the devices.

## Troubleshooting

- **tsgw1 not on the tailnet**: open its console in CML and read
  `/var/log/tsgw-bootstrap.log`. It retries until the lab has internet through
  vRouter1 (DHCP + NAT come from the router's day-0 config), so also check
  that vRouter1's Gi0/1 got a lease from the CML NAT network.
- **SSH refused / no key**: the day-0 config generates an RSA key at boot (a
  `crypto key generate` line plus an EEM fallback applet ~60s after boot). If
  it did not run, log in on the console and run
  `crypto key generate rsa modulus 2048`.
- **Clients have no DHCP lease**: run the playbook, then check
  `show ip dhcp binding` on vRouter1.
