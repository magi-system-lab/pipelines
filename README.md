# pipelines

Deployment profiles for the homelab. App repos carry no CI logic: just a
`launch.yml` that declares what is specific to them, and a ten-line trigger.

## Adding an app

1. Copy `examples/launch.yml` to the repo root and adjust `app`, `port`, `host`.
2. Copy `examples/pipeline.yml` to `.github/workflows/pipeline.yml`.
3. Create the two Actions secrets the repo needs: `CLUSTER_HOST` and
   `CLUSTER_USER`. They point at the cluster node.
4. If the app needs credentials, write them into OpenBao under
   `secret/<env>/<app>` and reference that path from `launch.yml`.
5. Open a pull request: its preview comes up. Merge it: prod is deployed.

## What the flow does

| Event | Result |
|---|---|
| Pull request opened, updated or reopened | preview in namespace `pr-<number>`, with a resource cap |
| Pull request closed | that namespace is deleted |
| Push to a branch listed in `environments.prod.branches` | deploy to `prod` |
| Push to any other branch | nothing |

## Architecture

- **Build**: Podman on the Mac mini, native arm64, no emulation.
- **Image delivery**: no registry. `podman save` over SSH into
  `k3s ctr images import` on balthazar, and the chart sets
  `imagePullPolicy: Never`. A registry comes back when balthazar gets an SSD.
- **Deploy**: Helm, one chart per profile under `profiles/<profile>/chart`.
- **Priorities**: prod uses `prod-priority` (1000), previews use
  `preview-priority` (100). Under memory pressure Kubernetes evicts previews first.
- **Secrets**: OpenBao on casper, read by External Secrets Operator through a
  read-only AppRole over TLS. The operator materialises a normal Kubernetes
  Secret; the app reads env vars or files and never talks to OpenBao. CI never
  sees a credential.

## Profiles

| Profile | Build | Port variable | Secret file default |
|---|---|---|---|
| `spring-boot` | Maven or Gradle, auto-detected | `SERVER_PORT` | `/config/application.properties` |
| `node` | `npm ci --omit=dev`, runs `npm start` | `PORT` | `/config/.env` |

## Security

Nothing is exposed to the internet. The runner opens an **outbound** HTTPS
connection to GitHub and waits for work; GitHub never connects inward, so there
is no open port and no router forwarding. The SSH tunnel to the cluster API is
LAN-only, from the Mac to balthazar.

The real exposure is **code execution**: when a run starts, the runner executes
the workflow on the Mac. That is what the following controls address.

### Who can cause a run

1. GitHub requires approval for **every** external contributor
   (`all_external_contributors`).
2. The job is gated on the pull request coming from a branch of the repo
   itself. A pull request from a fork does not match the condition, so it
   cannot run on the Mac even if it gets approved by mistake.

### What a run is allowed to do

- `permissions: contents: read` — the job's GitHub token can only read code.
- Only GitHub-authored actions may run (`allowed_actions: selected`,
  `github_owned_allowed: true`), and `actions/checkout` is pinned to an
  immutable commit SHA rather than a mutable tag.
- Everything read from `launch.yml` is validated against strict patterns before
  it reaches a shell command, closing the script-injection path.
- The branch name is passed through the environment, never interpolated into a
  script body.

### What the SSH keys are allowed to do

Two separate keys, both restricted in `authorized_keys` on balthazar:

| Key | Allowed |
|---|---|
| `id_ed25519_balthazar_ci` | A forced command that accepts exactly two strings: reading the kubeconfig and importing an image. No shell, no pty, no forwarding. |
| `id_ed25519_balthazar_tunnel` | Port forwarding to `127.0.0.1:6443` only (`permitopen`), with a forced `sleep` so it cannot run commands. |

Neither key reaches casper or melchior. `sudo` on balthazar is limited to the
single exact command `k3s ctr images import -`.

### Known residual risk

The runner runs as the desktop user, so a compromised job can read that user's
files. Running it under a dedicated account is the proper fix and is still
pending. Until then, no long-lived credential should sit in that user's home
directory.

This repo is public **out of necessity**: a public repo cannot consume reusable
workflows from a private one. That is why the cluster address and SSH user live
in each app repo's Actions secrets instead of in this code.

## Known gaps

- **Local DNS**: the chart already renders an Ingress when `host` is set, but
  until AdGuard resolves `*.lab.home.arpa` apps are reached at `IP:NodePort`.
- **Stale previews**: there is no job yet that deletes previews older than 24h.
- **OpenBao unseal**: casper's OpenBao starts sealed after a reboot and needs
  two unseal keys applied by hand.
