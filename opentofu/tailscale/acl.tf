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
          "tag:cml-lab":            ["autogroup:owner"],
        },

        // The CML lab gateway (tsgw1) advertises the lab subnet; approve it
        // automatically so Ansible can reach vRouter1/vSwitch1.
        "autoApprovers": {
          "routes": {
            "10.96.0.0/24": ["tag:cml-lab"],
          },
        },
      
        "grants": [
          {
            // Node-to-node overlay: every VM joins the tailnet as tag:server
            // and flannel VTEPs ride the tailnet, so server nodes must reach
            // each other on all ports. Keep separate from the member grant —
            // removing this splits the cluster network across nodes.
            "src": ["tag:server"],
            "dst": ["tag:server"],
            "ip":  ["*", "tcp:*"],
          },
          {
            // Member-owned devices reach server nodes on all ports. Scoped to
            // autogroup:member instead of a wildcard so that service/CI tags
            // only get what their dedicated grants below allow.
            "src": ["autogroup:member"],
            "dst": ["tag:server"],
            "ip":  ["*", "tcp:*"],
          },
          {
            // Tailscale SSH needs BOTH this tcp:22 network grant and an ssh
            // rule (hexabyte8@github -> autogroup:self below). Personal
            // devices (phone, Steam Deck, ...) are untagged member-owned
            // machines, so member-to-member traffic is denied by default
            // without this. icmp:* allows ping-based debugging.
            "src": ["autogroup:member"],
            "dst": ["autogroup:member"],
            "ip":  ["tcp:22", "icmp:*"],
          },
          {
            // Sunshine/Moonlight game streaming (bytten) from any personal
            // device: HTTPS/HTTP pairing + web dashboard (47984, 47989,
            // 47990), RTSP (48010) and the video/audio/control UDP streams.
            "src": ["autogroup:member"],
            "dst": ["autogroup:member"],
            "ip": [
              "tcp:47984",
              "tcp:47989",
              "tcp:47990",
              "tcp:48010",
              "udp:47998-48000",
              "udp:48002",
              "udp:48010",
            ],
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
            // The opencode agent pod joins the tailnet as tag:ci via a
            // tailscale sidecar — the same OAuth client the CI workflows
            // use — giving the AI assistant its own device. The grant stays
            // pinned to a single member-owned device by IP, so the assistant
            // can reach it without widening tag:ci's or tag:server's general
            // reach into member devices. Currently just the Steam Deck
            // (wagyu) for SSH + ping-based debugging.
            "src": ["tag:ci"],
            "dst": ["100.84.62.116/32"],
            "ip":  ["tcp:22", "icmp:*"],
          },
          {
            "src": ["tag:k8s-operator"],
            "dst": ["tag:server"],
            "ip":  ["*"],
          },
          {
            // SSH to the CML lab devices (via the tsgw1 subnet router) for
            // the cml-lab-configure Ansible workflow / local runs.
            "src": ["tag:ci", "autogroup:member"],
            "dst": ["10.96.0.0/24"],
            "ip":  ["tcp:22"],
          },
          {
            "src": ["tag:copilot"],
            "dst": ["tag:k8s-operator", "tag:k8s-operator-proxy", "tag:k8s"],
            "ip":  ["tcp:443"],
          },
          {
            // tcp:22 is required for Forgejo's SSH server, exposed via the
            // git-ssh LoadBalancer Service (tagged tag:k8s by the Tailscale
            // operator), so members can `git clone ssh://...`.
            "src": ["autogroup:member"],
            "dst": ["tag:k8s"],
            "ip":  ["tcp:22", "tcp:80", "tcp:443"],
          },
          {
            "src": ["autogroup:member"],
            "dst": ["autogroup:internet"],
            "ip":  ["*"],
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
            // CI runs commands as ubuntu + sudo (passwordless) — direct root
            // sessions are not needed by any workflow.
            "src":    ["tag:ci"],
            "dst":    ["autogroup:tagged"],
            "users":  ["ubuntu"],
            "action": "accept",
          },
          {
            "src":    ["hexabyte8@github"],
            "dst":    ["autogroup:self"],
            "users":  ["autogroup:nonroot"],
            "action": "accept",
          },
        ],
      }
  EOT
}
