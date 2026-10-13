locals {
  # Lab addressing. vRouter1 is the default gateway/DHCP server for the lab,
  # vSwitch1 is managed in-band via its VLAN 10 SVI. These addresses are also
  # the Ansible inventory (ansible/inventories/cml-lab/hosts.yml).
  lab_subnet = "10.96.0.0/24"
  router_ip  = "10.96.0.1"
  switch_ip  = "10.96.0.2"

  # Day-0 ("bootstrap") config only contains what is needed for Ansible to log
  # in over SSH. Everything else (VLANs, DHCP, NAT, ...) is owned by the
  # cml_* Ansible roles. Keep this stable: changing the config of a node that
  # has been started forces a node replacement.
  ios_bootstrap = <<-EOT
    no ip domain lookup
    ip domain name lab.local
    username ansible privilege 15 secret 0 ${var.default_vm_password}
    enable secret 0 ${var.default_vm_password}
    ip ssh version 2
    crypto key generate rsa modulus 2048
    !
    line con 0
     logging synchronous
    line vty 0 4
     login local
     transport input ssh
    !
    event manager applet GENERATE-SSH-KEYS authorization bypass
     event timer countdown time 60
     action 1.0 cli command "enable"
     action 2.0 cli command "show crypto key mypubkey rsa"
     action 3.0 regexp "Key name" "$_cli_result"
     action 4.0 if $_regexp_result eq 0
     action 4.1  cli command "configure terminal"
     action 4.2  cli command "crypto key generate rsa modulus 2048"
     action 4.3  cli command "end"
     action 5.0 end
  EOT
}

resource "cml2_lab" "basic-lab" {
  title       = "basic-lab"
  description = "Basic Lab"
  notes       = "Basic CML lab created with Terraform for testing network lab management via TF, and automation testing. Device configuration is enforced by the cml_* Ansible roles."
}

# NAT is the only mode available to external connectors in CML cloud (no bridge
# mode), so look up the controller's "NAT" external connector device by label.
data "cml2_connector" "nat" {
  label = "NAT"
}

resource "cml2_node" "external_connector1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "external_connector1"
  nodedefinition = "external_connector"
  configuration  = data.cml2_connector.nat.connectors[0].device_name
  tags           = ["infra"]
  x              = 0
  y              = 0
}

resource "cml2_node" "node1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "chronos1"
  nodedefinition = "ubuntu"
  tags           = ["client"]
  x              = 100
  y              = 0
}

resource "cml2_node" "node2" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "alpine2"
  nodedefinition = "alpine"
  tags           = ["client"]
  x              = 100
  y              = 100
}

# Tailscale subnet router for the lab: lets CI / a local machine reach
# vRouter1 and vSwitch1 over SSH so Ansible can configure them. It is a plain
# DHCP client of the lab like the other two VMs.
resource "tailscale_tailnet_key" "cml_gw" {
  reusable            = true
  ephemeral           = true
  preauthorized       = true
  expiry              = 7776000 # 90 days
  description         = "CML lab gateway"
  tags                = ["tag:cml-lab"]
  recreate_if_invalid = "always"
}

resource "cml2_node" "tsgw1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "tsgw1"
  nodedefinition = "ubuntu"
  tags           = ["gateway"]
  x              = 100
  y              = 200

  configuration = <<-EOT
    #cloud-config
    hostname: tsgw1
    write_files:
      - path: /etc/sysctl.d/99-tailscale-forward.conf
        content: |
          net.ipv4.ip_forward = 1
      - path: /usr/local/sbin/tsgw-bootstrap.sh
        permissions: "0700"
        content: |
          #!/bin/sh
          # The lab DHCP server (vRouter1) may not be up yet, so retry until
          # the internet is reachable.
          sysctl --system
          until curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh; do sleep 10; done
          sh /tmp/tailscale-install.sh
          until tailscale up --auth-key='${tailscale_tailnet_key.cml_gw.key}' --hostname=cml-lab-gw --advertise-routes=${local.lab_subnet} --accept-dns=false; do sleep 15; done
    runcmd:
      - [ sh, -c, "nohup /usr/local/sbin/tsgw-bootstrap.sh > /var/log/tsgw-bootstrap.log 2>&1 &" ]
  EOT

  # The auth key is only needed on first boot. Don't replace the (started)
  # node just because the key was rotated.
  lifecycle {
    ignore_changes = [configuration]
  }
}

# Interface slots are pinned so the port-to-device mapping is deterministic:
#
#   vSwitch1  Gi0/0 chronos1   Gi0/1 alpine2   Gi0/2 vRouter1   Gi0/3 tsgw1
#   vRouter1  Gi0/0 vSwitch1 (inside)   Gi0/1 external_connector1 (outside/NAT)
resource "cml2_node" "vswitch1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "vSwitch1"
  nodedefinition = "iosvl2"
  tags           = ["infra"]
  x              = 300
  y              = 100

  configuration = <<-EOT
    hostname vSwitch1
    ${local.ios_bootstrap}
    !
    vlan 10
     name INTERNAL
    !
    interface GigabitEthernet0/0
     switchport mode access
     switchport access vlan 10
     no shutdown
    interface GigabitEthernet0/1
     switchport mode access
     switchport access vlan 10
     no shutdown
    interface GigabitEthernet0/2
     switchport mode access
     switchport access vlan 10
     no shutdown
    interface GigabitEthernet0/3
     switchport mode access
     switchport access vlan 10
     no shutdown
    !
    interface Vlan10
     ip address ${local.switch_ip} 255.255.255.0
     no shutdown
    !
    ip default-gateway ${local.router_ip}
    end
  EOT
}

resource "cml2_node" "vrouter1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "vRouter1"
  nodedefinition = "iosv"
  tags           = ["infra"]
  x              = 300
  y              = 300

  # Day-0 also brings up routing/DHCP/NAT: tsgw1 needs internet through this
  # router to join Tailscale, and Ansible reaches the lab through tsgw1. The
  # cml_router role then takes over and keeps this (and everything else) in the
  # state declared in host_vars/vrouter1.yml.
  configuration = <<-EOT
    hostname vRouter1
    ${local.ios_bootstrap}
    !
    interface GigabitEthernet0/0
     description to-vSwitch1-internal
     ip address ${local.router_ip} 255.255.255.0
     ip nat inside
     no shutdown
    interface GigabitEthernet0/1
     description to-external-connector-NAT
     ip address dhcp
     ip nat outside
     no shutdown
    !
    ip access-list standard INTERNAL-NAT
     permit 10.96.0.0 0.0.0.255
    ip nat inside source list INTERNAL-NAT interface GigabitEthernet0/1 overload
    !
    ip dhcp excluded-address ${local.router_ip} 10.96.0.20
    ip dhcp pool LAB-CLIENTS
     network 10.96.0.0 255.255.255.0
     dns-server 1.1.1.1 8.8.8.8
     default-router ${local.router_ip}
     lease 0 8
    end
  EOT
}

resource "cml2_link" "link1" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.node1.id
  slot_a = 0
  node_b = cml2_node.vswitch1.id
  slot_b = 0
}

resource "cml2_link" "link2" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.node2.id
  slot_a = 0
  node_b = cml2_node.vswitch1.id
  slot_b = 1
}

resource "cml2_link" "link3" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.vswitch1.id
  slot_a = 2
  node_b = cml2_node.vrouter1.id
  slot_b = 0
}

resource "cml2_link" "link4" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.external_connector1.id
  slot_a = 0
  node_b = cml2_node.vrouter1.id
  slot_b = 1
}

resource "cml2_link" "link5" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.tsgw1.id
  slot_a = 0
  node_b = cml2_node.vswitch1.id
  slot_b = 3
}

# Start the lab. Infra (router, switch, NAT) comes up first so DHCP is
# available when the clients boot. wait = false keeps `tofu apply` short; the
# Ansible workflow waits for the lab to become reachable.
resource "cml2_lifecycle" "basic-lab" {
  lab_id = cml2_lab.basic-lab.id
  state  = "STARTED"
  wait   = false

  staging = {
    stages          = ["infra", "gateway"]
    start_remaining = true
  }

  depends_on = [
    cml2_node.external_connector1,
    cml2_node.node1,
    cml2_node.node2,
    cml2_node.tsgw1,
    cml2_node.vswitch1,
    cml2_node.vrouter1,
    cml2_link.link1,
    cml2_link.link2,
    cml2_link.link3,
    cml2_link.link4,
    cml2_link.link5,
  ]
}
