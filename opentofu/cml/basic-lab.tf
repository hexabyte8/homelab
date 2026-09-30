resource "cml2_lab" "basic-lab" {
  title       = "basic-lab"
  description = "Basic Lab"
  notes       = ""
}

resource "cml2_node" "node1" {
  lab_id         = cml2_lab.basic-lab.id
  label          = "alpine1"
  nodedefinition = "alpine"
}
