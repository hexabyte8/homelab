#cloud-config
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - systemctl restart systemd-sysctl
  # One-command install, from https://tailscale.com/download/
  - ['sh', '-c', 'curl -fsSL https://tailscale.com/install.sh | sh']
  # Auth key is managed by OpenTofu - rotate by running tofu apply
  - ['tailscale', 'up', '--auth-key=${tailscale_auth_key}', '--advertise-tags=tag:server', '--ssh']
write_files:
  - path: /etc/sysctl.d/10-disable-ipv6.conf
    permissions: 0644
    owner: root
    content: |
      net.ipv6.conf.eth0.disable_ipv6 = 1
  - path: /etc/sysctl.d/20-tailscale-perf.conf
    permissions: 0644
    owner: root
    content: |
      # Tailscale / WireGuard performance tuning
      # Increase UDP socket buffers for WireGuard throughput
      net.core.rmem_max = 7500000
      net.core.wmem_max = 7500000
      # Enable IP forwarding (required for Tailscale subnet routing and exit nodes)
      net.ipv4.ip_forward = 1
      net.ipv6.conf.all.forwarding = 1
      # BBR TCP congestion control + fair queuing for better throughput over WireGuard tunnels
      net.core.default_qdisc = fq
      net.ipv4.tcp_congestion_control = bbr
