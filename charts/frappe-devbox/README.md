# frappe-devbox Helm chart

Deploys a Frappe v15 developer workspace: bench, MariaDB, Redis and code-server in one pod. One release is one workspace; install several releases for several developers or branches.

This is a development environment (developer mode, `bench serve`, database inside the pod). It is not a way to serve Frappe to end users.

## Install

The namespace should enforce Pod Security `restricted`; the chart is built to pass it.

```bash
kubectl create namespace frappe-dev
kubectl label namespace frappe-dev \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

helm install alice ./charts/frappe-devbox -n frappe-dev \
  --set ingress.host=alice.dev.example.com
```

`helm install` prints how to follow the first boot, open the site and read the generated passwords.

Default values create a Longhorn StorageClass (`longhorn-devbox`, 2 replicas, `dataLocality: best-effort`, `Retain`) and an Ingress for Traefik. For local-path:

```bash
helm install alice ./charts/frappe-devbox -n frappe-dev \
  --set persistence.storageClass=local-path \
  --set longhornStorageClass.create=false \
  --set ingress.host=alice.dev.example.com
```

## What the chart does

| Resource | Notes |
|----------|-------|
| Deployment | `bootstrap` init container runs the first-boot build with the higher limits, then the `devbox` container runs the workspace. `Recreate` strategy, one replica. |
| PersistentVolumeClaim | Bench, MariaDB, Redis and code-server data. Kept on `helm uninstall` by default. |
| Secret | Site admin, MariaDB root and code-server passwords. Generated on first install and reused on every upgrade and reinstall. Kept together with the PVC. |
| ConfigMap | Settings shared by both containers. Changing it restarts the pod. |
| StorageClass | Optional, cluster-wide, shared by all releases. The first release that creates it owns it; later releases skip it. |
| Service | Ports 8000 (web) and 9000 (socket.io). 8080 only when code-server is exposed. MariaDB and Redis are never exposed. |
| Ingress | `/socket.io` → 9000, `/` → 8000. Optional second host for code-server. |
| NetworkPolicy | Admits only the ingress controller (k3s Traefik by default). |

## Common values

| Value | Default | |
|-------|---------|-|
| `image.repository` / `image.tag` | `neuron27/frappe-v15-devbox` / appVersion | |
| `site.name` | `dev.localhost` | Default site |
| `site.installApps` | `[]` | Installed after site creation |
| `persistence.storageClass` | `longhorn-devbox` | `local-path`, `longhorn`, any class |
| `persistence.size` | `20Gi` | |
| `persistence.keepOnUninstall` | `true` | Keeps PVC and Secret |
| `longhornStorageClass.create` | `true` | Set `false` for local-path or your own class |
| `bootstrap.resources` | req `250m`/`1Gi`, lim `4`/`8Gi` | First-boot build |
| `resources` | req `250m`/`1Gi`, lim `2`/`4Gi` | Running workspace |
| `ingress.host` | `frappe-devbox.example.com` | Required when `ingress.enabled` |
| `ingress.tls.enabled` | `false` | Add a cert-manager annotation under `ingress.annotations` |
| `codeServer.enabled` | `true` | |
| `codeServer.ingress.enabled` | `false` | Off: use `kubectl port-forward` |
| `auth.existingSecret` | `""` | Keys `SITE_ADMIN_PASSWORD`, `DB_ROOT_PASSWORD`, `PASSWORD` |
| `mariadb.local` / `redis.local` | `true` | `false` + `externalDatabase.host` / `externalRedis.url` |

See `values.yaml` for everything else (probes, scheduling, network policy selectors).

The chart rejects unsafe or incomplete settings at install time, for example exposing code-server without a password, running as root, or using an external database without a host.

## Passwords

Leave the `auth.*` values empty to generate random passwords. They are stored in the release Secret and reused on every upgrade.

Changing `auth.dbRootPassword` after the first boot does not change MariaDB's password; the workspace would refuse to start. Change it inside MariaDB first, then update the value.

## Removing a workspace

```bash
helm uninstall alice -n frappe-dev
# PVC and Secret are kept. To wipe the workspace:
kubectl -n frappe-dev delete pvc alice-frappe-devbox-data
kubectl -n frappe-dev delete secret alice-frappe-devbox
```

With the `longhorn-devbox` class (`reclaimPolicy: Retain`) the Longhorn volume itself also survives PVC deletion; delete it in the Longhorn UI when you are sure.
