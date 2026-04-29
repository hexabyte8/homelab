resource "tailscale_tailnet_key" "vm_auth" {
  reusable            = true
  ephemeral           = false
  preauthorized       = true
  expiry              = 7776000 # 90 days
  description         = "Cloud-init VM auth key"
  tags                = ["tag:server"]
  recreate_if_invalid = "always"
}

resource "tailscale_acl" "as_json" {
  acl = <<-EOT
      {
        "tagOwners": {
          "tag:ci":                 ["autogroup:owner"],
          "tag:copilot":            ["autogroup:owner"],
          "tag:server":             ["autogroup:owner"],
          "tag:k8s-operator":       ["autogroup:owner"],
          "tag:k8s-operator-proxy": ["autogroup:owner"],
          "tag:k8s":                ["tag:k8s-operator"],
        },
      
        "grants": [
          {
            "src": ["*"],
            "dst": ["tag:server"],
            "ip":  ["*", "tcp:*"],
          },
          {
            "src": ["tag:ci"],
            "dst": ["tag:server"],
            "ip":  ["*"],
          },
          {
            "src": ["tag:ci"],
            "dst": ["tag:k8s"],
            "ip":  ["tcp:443"],
          },
          {
            "src": ["tag:k8s-operator"],
            "dst": ["tag:server"],
            "ip":  ["*"],
          },
          {
            "src": ["tag:copilot"],
            "dst": ["tag:k8s-operator"],
            "ip":  ["tcp:443"],
          },
          {
            "src": ["autogroup:member"],
            "dst": ["tag:k8s"],
            "ip":  ["tcp:80", "tcp:443"],
          },
        ],
      
        "ssh": [
          {
            "src":    ["hexabyte8@github"],
            "dst":    ["tag:server"],
            "users":  ["root", "ubuntu"],
            "action": "accept",
          },
          {
            "src":    ["tag:ci"],
            "dst":    ["autogroup:tagged"],
            "users":  ["root", "ubuntu"],
            "action": "accept",
          },
          {
            "src":    ["hexabyte8@github"],
            "dst":    ["autogroup:self"],
            "users":  ["autogroup:nonroot"],
            "action": "accept",
          },
        ],
      
        "nodeAttrs": [
          {
            "target": ["tag:k8s"],
            "attr":   ["funnel"],
          },
        ],
      }
  EOT
}
