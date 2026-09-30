resource "cml2_lab" "basic-lab" {
  title       = "basic-lab"
  description = "Basic Lab"
  notes       = "Basic CML lab created with Terraform for testing network lab management via TF, and automation testing"
}

resource "cml2_node" "node1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "alpine1"
  nodedefinition = "alpine"
}

resource "cml2_node" "vswitch1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "vSwitch1"
  nodedefinition = "iosvl2"
}

resource "cml2_link" "link1" {
  lab_id = cml2_lab.basic-lab.id
  node_a = cml2_node.node1.id
  node_b = cml2_node.vswitch1.id
}
