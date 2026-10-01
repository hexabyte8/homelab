resource "cml2_lab" "basic-lab" {
  title       = "basic-lab"
  description = "Basic Lab"
  notes       = "Basic CML lab created with Terraform for testing network lab management via TF, and automation testing"
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
  x = 0
  y = 0
}

resource "cml2_node" "node1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "chronos1"
  nodedefinition = "ubuntu"
  x = 100
  y = 0
}

resource "cml2_node" "node2" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "alpine2"
  nodedefinition = "alpine"
  x = 100
  y = 100
}

resource "cml2_node" "vswitch1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "vSwitch1"
  nodedefinition = "iosvl2"
  x = 300
  y = 100

  # Gi0/0 -> alpine2 (link2, first link created against this node)
  # Gi0/1 -> vRouter1 (link3, second link created against this node)
  configuration = <<-EOT
    hostname vSwitch1
    no ip domain-lookup
    !
    vlan 10
     name INTERNAL
    !
    interface GigabitEthernet0/0
     switchport mode access
     switchport access vlan 10
     no shutdown
    !
    interface GigabitEthernet0/1
     switchport mode access
     switchport access vlan 10
     no shutdown
    !
    line con 0
     logging synchronous
    !
    end
  EOT
}

resource "cml2_node" "vrouter1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "vRouter1"
  nodedefinition = "iosv"
  x = 300
  y = 300

  # Gi0/0 -> vSwitch1 (link3, first link created against this node): internal/inside
  # Gi0/1 -> external_connector1 (link4, second link created against this node): outside, DHCP from CML's NAT network
  configuration = <<-EOT
    hostname vRouter1
    no ip domain-lookup
    !
    interface GigabitEthernet0/0
     description to-vSwitch1-internal
     ip address 10.96.0.1 255.255.255.0
     ip nat inside
     no shutdown
    !
    interface GigabitEthernet0/1
     description to-external-connector-NAT
     ip address dhcp
     ip nat outside
     no shutdown
    !
    ip nat inside source list INTERNAL-NAT interface GigabitEthernet0/1 overload
    !
    ip access-list standard INTERNAL-NAT
     permit 10.96.0.0 0.0.0.255
    !
    line con 0
     logging synchronous
    !
    end
  EOT
}

resource "cml2_link" "link1" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.node1.id
  node_b = cml2_node.external_connector1.id
}

resource "cml2_link" "link2" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.node2.id
  node_b = cml2_node.vswitch1.id
}

resource "cml2_link" "link3" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.vswitch1.id
  node_b = cml2_node.vrouter1.id
}

resource "cml2_link" "link4" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.external_connector1.id
  node_b = cml2_node.vrouter1.id
}
