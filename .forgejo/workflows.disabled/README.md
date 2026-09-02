# Forgejo workflows (disabled)

Forgejo Actions only discovers workflows under `.forgejo/workflows/` (or
`.gitea/workflows/`). This directory is deliberately named
`.forgejo/workflows.disabled/` so that Forgejo does **not** auto-trigger any
workflows on push to this repo.

The homelab repo is mirrored to Forgejo as an emergency backup; CI/CD for it
runs on GitHub Actions (`.github/workflows/`). Forgejo Actions itself remains
enabled globally (see `k3s/manifests/forgejo/configmap.yaml`) and the
`forgejo-runner` deployment stays running so other repos hosted on Forgejo can
use it.

To re-enable Forgejo Actions for this repo, `git mv` the workflow files back
into `.forgejo/workflows/`.
