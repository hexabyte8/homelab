resource "cml2_lab" "basic-lab" {
  title       = "basic-lab"
  description = "Basic Lab"
  notes       = "Basic CML lab created with Terraform for testing network lab management via TF, and automation testing"
}

resource "cml2_node" "external_connector1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "external_connector1"
  nodedefinition = "external_connector"
  x = 0
  y = 200
}

resource "cml2_node" "node1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "alpine1"
  nodedefinition = "alpine"
  x = 100
  y = 100
}

resource "cml2_node" "node2" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "alpine2"
  nodedefinition = "alpine"
  x = 100
  y = 300
}

resource "cml2_node" "vswitch1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "vSwitch1"
  nodedefinition = "iosvl2"
  x = 300
  y = 100
}

resource "cml2_node" "vrouter1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "vRouter1"
  nodedefinition = "iosv"
  x = 300
  y = 300
}

resource "cml2_link" "link1" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.node1.id
  node_b = cml2_node.vswitch1.id
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
