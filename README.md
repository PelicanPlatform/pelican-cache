# Pelican Cache Helm Chart

A Helm chart for deploying a [Pelican Platform](https://pelicanplatform.org) cache server in Kubernetes, designed for the [Open Science Data Federation (OSDF)](https://osg-htc.org/services/osdf.html).

## Background

This chart was created by analyzing the Kustomize-based deployment in the [tiger-osg-config](https://github.com/opensciencegrid/tiger-osg-config) repository, specifically the `uw-osdf-cache` instance at `manifests/tiger/osdf-prod/uw-osdf-cache/`. That deployment uses a three-layer Kustomize inheritance chain:

1. **`base/pelican-cache`** — Generic Pelican cache (Deployment with 3 containers, Service, PVCs, NetworkPolicy, cert-manager Certificate, ConfigMaps)
2. **`base/osdf-pelican-cache`** — OSDF-specific overlay (adds `osdf-` prefix, sets `Federation.DiscoveryUrl` to `https://osg-htc.org`)
3. **`tiger/osdf-prod/uw-osdf-cache`** — Instance-specific overlay (pins images, node, resources, storage, cache tuning, OIDC, Lotman, etc.)

This Helm chart collapses these three layers into a single, parameterized chart with sensible defaults for OSDF deployments.

## Prerequisites

- Kubernetes 1.24+
- Helm 3.x
- Optional: [cert-manager](https://cert-manager.io/) for creating certificates.
- Pre-created Secrets for sensitive data (issuer keys, OIDC credentials, web UI passwords),
  see "Create Required Secrets" below.


## Quick Start

### Create Required Secrets

The following secrets must exist before the cache can be started:

-   Web server admin key
    Create this with `pelican-server generate password`

-   Issuer key
    Create this with `pelican-server key create`

### Minimal installation

```bash
helm install my-cache ./pelican-cache \
  --set serverHostname=my-cache.example.com \
  --set sitename=my-site \
  --set cache.pvc.storageClass=my-storage-class \
  --set logging.persistence.storageClass=my-storage-class \
  --set database.persistence.storageClass=my-storage-class \
  --set issuerKey.existingSecret=my-issuer-key-secret \
  --set webPassword.existingSecret=my-web-passwd-secret
```

### Installation with a values file

```bash
helm install my-cache ./pelican-cache -f my-values.yaml
```

See [ci/uw-osdf-cache-values.yaml](ci/uw-osdf-cache-values.yaml) for a complete example that mirrors the real UW-Madison OSDF cache deployment.

## Architecture

The chart deploys a single Pod with two containers:

| Container | Purpose | Optional |
|---|---|---|
| `pelican-cache` | Main Pelican cache process | No |
| `logrotate` | Rotates Pelican log files | No |

### Pelican Configuration

This chart generates a single ConfigMap (`pelican-config`) containing one file:

- **`config.yaml`** — Mounted at `/etc/pelican/config.d/config.yaml`. Contains all settings: infrastructure config (storage paths, ports, TLS paths) and user-configurable settings (federation URL, hostname, cache tuning, OIDC, Lotman, logging levels, XRootD settings, and any `extraPelicanConfig`).

### Storage

The chart manages several persistent volumes:

| Volume | Purpose | Backing |
|---|---|---|
| Cache data | XRootD file cache | PVC or hostPath (`cache.type`) |
| Logging | Pelican log files | Dedicated PVC (default) or shared with cache data (`logging.persistence.separateVolume`) |
| Database | Pelican database files | Dedicated PVC (default) or shared with cache data (`database.persistence.separateVolume`) |
| Issuer key | Pelican issuer/signing key | Existing Secret (`issuerKey.existingSecret`) |
| Lotman data | Lot-based storage management | PVC (when `lotman.enabled`) |

**NVMe storage is strongly recommended for the cache data volume.**

## Configuration Reference

### Site Identity (customization required)

| Parameter | Description |
|---|---|
| `serverHostname` | External FQDN of the cache. Chart fails to render without this. |
| `sitename` | Site name reported to the federation |

Both of these values are required for the cache to be able to identify itself to the federation.

### Cache Storage (customization required)

Cache persistence must be specified; you must choose a value for `cache.type`, either `pvc` or `hostPath`,
and then fill out the fields in the appropriate subsections.

**PVC option** (`cache.type: pvc`): Use Kubernetes persistent volumes, creating new or referencing existing PVCs.

If using a PVC, you can use an existing PVC or have the chart create a new one.
If using an existing PVC, you must set `cache.pvc.existingClaim` to the name of the PVC.
If creating a new PVC, you must set `cache.pvc.storageClass` to one of the available storage classes in your cluster.
PVCs created by this chart will not be deleted on uninstall.

**HostPath option** (`cache.type: hostPath`): Bind-mount a directory from the node.

If using a host path, you must specify the path in `cache.hostPath.path`.

| Parameter | Default | Description |
|---|---|---|
| `cache.type` | `pvc` | `pvc` or `hostPath` |
| `cache.hostPath.path` | `""` | Host path (required when type is `hostPath`) |
| `cache.pvc.existingClaim` | `""` | Existing PVC name (if set, ignores `storageClass` and `size`) |
| `cache.pvc.storageClass` | `""` | StorageClass for new cache data PVC (required if `existingClaim` is not set) |
| `cache.pvc.size` | `1000Gi` | Cache data PVC size (used when creating a new PVC) |

### Issuer Key (customization required)

| Parameter | Default | Description |
|---|---|---|
| `issuerKey.existingSecret` | `""` | Pre-existing Secret name containing the issuer key |
| `issuerKey.secretKey` | `private-key.pem` | Key within the Secret |

You must pre-create the issuer key using `pelican key create` and save it in a Secret.
Set `issuerKey.existingSecret` to that Secret name.

### Logging (customization required)

| Parameter | Default | Description |
|---|---|---|
| `logging.persistence.separateVolume` | `true` | Provision a dedicated PVC for `/var/log/pelican`; when `false`, the data volume is also mounted at `/var/log` so `/var/log/pelican` can still live on cache storage. Logrotate always runs. |
| `logging.persistence.existingClaim` | `""` | Existing logging PVC name (if set, ignores `storageClass` and `size`) |
| `logging.persistence.storageClass` | `""` | StorageClass for new logging PVC (required if `existingClaim` is not set and `separateVolume=true`) |
| `logging.persistence.size` | `50Gi` | Logging PVC size (used when creating a new PVC) |
| `loggingConfig.level` | `INFO` | Global Pelican log level |
| `loggingConfig.cache` | `{}` | Per-subsystem log levels (map, e.g. `{Pss: debug, Pfc: debug}`) |
| `loggingConfig.rotateSize` | `500M` | Log file size threshold that triggers rotation |
| `loggingConfig.rotateCount` | `10` | Number of rotated log files to keep |

### Database (customization required)

| Parameter | Default | Description |
|---|---|---|
| `database.persistence.separateVolume` | `true` | Provision a dedicated PVC for `/var/lib/pelican`; when `false`, the data volume is also mounted at `/var/lib` so `/var/lib/pelican` can still live on cache storage. Logrotate always runs. |
| `database.persistence.existingClaim` | `""` | Existing database PVC name (if set, ignores `storageClass` and `size`) |
| `database.persistence.storageClass` | `""` | StorageClass for new database PVC (required if `existingClaim` is not set and `separateVolume=true`) |
| `database.persistence.size` | `20Gi` | Database PVC size (used when creating a new PVC) |

### Admin / Web UI (customization required)

| Parameter | Default | Description |
|---|---|---|
| `webPassword.existingSecret` | `""` | Existing Secret for web UI password |
| `webPassword.key` | `server-web-passwd` | Key within the web password Secret |
| `oidc.enabled` | `false` | Enable OIDC authentication |
| `oidc.existingSecret` | `""` | Secret with `client.id` and `client.secret` keys |
| `oidc.adminUsers` | `[]` | OIDC `sub` claims for UI admins; when OIDC is enabled, either this or `oidc.adminGroups` (or both) must be nonempty |
| `oidc.adminGroups` | `[]` | CILogon group names for UI admins; when OIDC is enabled, either this or `oidc.adminUsers` (or both) must be nonempty |

You must create a secret containing a file named `server-web-passwd` that was created by running `pelican generate password`
and specify that as `webPassword.existingSecret`.

You may also have admins log in via OIDC. In this case, set `oidc.enabled` to `true`,
add a Secret for contacting the Identity Provider with an OIDC client ID and secret
(`client.id` and `client.secret`, respectively), and set one or both of:

- `oidc.adminUsers` (a list of OIDC `sub` claims)
- `oidc.adminGroups` (a list of CILogon group names)

Validation rules for admin authorization are:

- If `oidc.enabled=true`, at least one of `oidc.adminUsers` or `oidc.adminGroups` must be nonempty.
- If either `oidc.adminUsers` or `oidc.adminGroups` is nonempty, then `oidc.enabled` must be `true`.

Example OIDC configurations:

```yaml
# Users-only admin authorization
oidc:
  enabled: true
  existingSecret: my-oidc-client-secret
  adminUsers:
    - "http://cilogon.org/serverA/users/12345"
```

```yaml
# Groups-only admin authorization
oidc:
  enabled: true
  existingSecret: my-oidc-client-secret
  adminGroups:
    - "osg-ops"
```

```yaml
# Mixed users + groups admin authorization
oidc:
  enabled: true
  existingSecret: my-oidc-client-secret
  adminUsers:
    - "http://cilogon.org/serverA/users/12345"
  adminGroups:
    - "osg-ops"
```

### Federation (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `federation.discoveryUrl` | `https://osg-htc.org` | Federation discovery URL. Change for non-OSDF or ITB. |

All resources are labelled with `pelicanplatform.org/federation` set to the sanitized value of `federation.discoveryUrl` (scheme and special characters removed).
The default federation is OSDF so OSDF caches do not need to change this section.

### Images (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `cache.image.repository` | `hub.opensciencegrid.org/pelican_platform/cache` | Cache container image |
| `cache.image.tag` | `""` | Cache image tag (defaults to chart `appVersion` when empty) |
| `cache.image.pullPolicy` | `IfNotPresent` | Image pull policy for the cache container |
| `logrotate.image.repository` | `hub.opensciencegrid.org/opensciencegrid/logrotate` | Logrotate sidecar image |
| `logrotate.image.tag` | `24-release` | Logrotate image tag |

The logrotate sidecar always uses `imagePullPolicy: Always` and that behavior is
not configurable.

### Cache Tuning (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `cacheConfig.blocksToPrefetch` | `""` | Blocks to prefetch (e.g. `10`) |
| `cacheConfig.concurrency` | `""` | Max concurrent requests (e.g. `240` — guidance: 10× core count) |
| `cacheConfig.highWaterMark` | `""` | Eviction high watermark (e.g. `27000g` or `95`) |
| `cacheConfig.lowWaterMark` | `""` | Eviction low watermark (e.g. `25000g` or `90`) |
| `cacheConfig.filesMaxSize` | `""` | XRootD diskusage max tracked size. Must be &lt; low watermark. |
| `cacheConfig.filesNominalSize` | `""` | XRootD diskusage nominal tracked size |
| `cacheConfig.filesBaseSize` | `""` | XRootD diskusage base tracked size |

`highWaterMark` and `lowWaterMark` may be absolute sizes ending in `g` (gigabytes) or disk space percentages (no suffix).

For details on `Files*Size` parameters, see the [XRootD PFC documentation](https://xrootd.web.cern.ch/doc/dev56/pss_config.pdf) (search for "diskusage").

### TLS / Certificates

`serverHostname` is always included in the rendered cert-manager `Certificate.spec.dnsNames`; use `tls.certManager.dnsNames` only for additional SANs.

| Parameter | Default | Description |
|---|---|---|
| `tls.certManager.enabled` | `true` | Create a cert-manager Certificate |
| `tls.certManager.issuerRef.name` | `letsencrypt-prod` | Issuer name |
| `tls.certManager.issuerRef.kind` | `ClusterIssuer` | Issuer kind |
| `tls.certManager.dnsNames` | `[]` | Additional DNS SANs (`serverHostname` is always included) |
| `tls.existingSecret` | `""` | Use an existing TLS Secret instead of cert-manager |

### Service (customization optional)

Note: When `hostNetwork` is enabled, a Service does not get created, in which case these settings have no effect.

| Parameter | Default | Description |
|---|---|---|
| `service.type` | `LoadBalancer` | Service type |
| `service.loadBalancerIP` | `""` | Request a specific LB IP |
| `service.externalTrafficPolicy` | `Local` | Traffic policy |
| `service.annotations` | `{}` | Extra annotations (external-dns, metallb, etc.) |

### Resources (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `cache.resources.requests.cpu` | `1000m` | Cache container CPU request |
| `cache.resources.requests.memory` | `16Gi` | Cache container memory request |
| `cache.resources.limits` | `{}` | Cache container limits |
| `logrotate.resources.requests.cpu` | `1` | Logrotate CPU request |
| `logrotate.resources.requests.memory` | `500M` | Logrotate memory request |
| `logrotate.resources.limits.cpu` | `2` | Logrotate CPU limit |
| `logrotate.resources.limits.memory` | `2G` | Logrotate memory limit |

### Optional Components

| Parameter | Default | Description |
|---|---|---|
| `sleep` | `false` | Debug mode: run `sleep infinity` in the `pelican-cache` container instead of starting the cache process |
| `hostNetwork` | `false` | Use host networking (`spec.hostNetwork=true`) to bind directly to node IP. When enabled, no Service or NetworkPolicy is created. |
| `server.cachePort` | `8443` | Cache port exposed by Pelican and used by container/service/network policy mappings |
| `server.webPort` | `443` | Web UI port exposed by Pelican and container port mapping |
| `lotman.enabled` | `false` | Enable Lotman (lot-based storage management) |
| `lotman.pvc.existingClaim` | `""` | Existing Lotman PVC name (if set, ignores `storageClass` and `size`) |
| `lotman.pvc.storageClass` | `""` | StorageClass for new Lotman PVC (required if `existingClaim` is not set and `enabled=true`) |
| `lotman.pvc.size` | `10Gi` | Lotman PVC size (used when creating a new PVC) |

When `sleep` is `true`, the `pelican-cache` container starts with `sleep infinity` for debugging. After you `kubectl exec` into the container, you can start the cache manually with `pelican cache serve`.

### XRootD (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `xrootd.extraConfig` | `""` | Raw `xrootd.conf` content (e.g. `xrd.sched maxt 20000`) |

`xrootd.extraConfig` is an escape hatch for settings that cannot be expressed
through normal chart values. Prefer regular chart parameters when possible.

### Network Policy

Note: When `hostNetwork` is enabled, a NetworkPolicy does not get created, regardless of the setting of `networkPolicy.enabled`.

| Parameter | Default | Description |
|---|---|---|
| `networkPolicy.enabled` | `true` | Create a NetworkPolicy |

### Scheduling (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `nodeSelector` | `{}` | Pod node selector |
| `tolerations` | `[]` | Pod tolerations |
| `affinity` | `{}` | Pod affinity rules |

### Escape Hatches (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `extraPelicanConfig` | `{}` | Arbitrary YAML merged into the instance config |
| `extraEnv` | `[]` | Extra env vars for the cache container |
| `extraVolumes` | `[]` | Extra volumes for the pod |
| `extraVolumeMounts` | `[]` | Extra volume mounts for the cache container |
| `podAnnotations` | `{}` | Extra pod annotations |
| `podSecurityContext` | `{}` | Pod-level security context (fsGroup, runAsUser, etc.) |
| `securityContext` | `{}` | Security context for the cache container |

## Examples

### Minimal OSDF Cache (PVC-backed)

```yaml
serverHostname: my-cache.osg-htc.org
sitename: MY_OSDF_CACHE

cache:
  type: pvc
  pvc:
    storageClass: fast-nvme
    size: 2000Gi

logging:
  persistence:
    storageClass: standard

database:
  persistence:
    storageClass: standard

issuerKey:
  existingSecret: my-issuer-key-secret

webPassword:
  existingSecret: my-web-passwd-secret
```

### Production Cache (hostPath, like uw-osdf-cache)

```yaml
serverHostname: osdf-uw-cache.svc.osg-htc.org
sitename: MY_PELICAN_CACHE

cache:
  image:
    tag: "v7.23.0"
  type: hostPath
  hostPath:
    path: /srv/pelican-cache/
  resources:
    requests:
      cpu: "24"
      memory: "48Gi"

cacheConfig:
  blocksToPrefetch: 10
  concurrency: 240
  highWaterMark: 27000g
  lowWaterMark: 25000g

issuerKey:
  existingSecret: my-cache-issuer-key

tls:
  certManager:
    enabled: true
    dnsNames:
      - osdf-uw-cache.svc.osdf-prod.chtc.io
      - osdf-uw-cache.svc.osg-htc.org

service:
  loadBalancerIP: "128.105.82.176"
  annotations:
    external-dns.alpha.kubernetes.io/hostname: osdf-uw-cache.svc.osdf-prod.chtc.io
    metallb.universe.tf/address-pool: tiger-vlan5

logging:
  level: debug
  persistence:
    storageClass: 3x-replica-hdd
    size: 50Gi
  cache:
    Pss: debug
    Pfc: debug

database:
  persistence:
    storageClass: 3x-replica-hdd
    size: 50Gi

lotman:
  enabled: true
  pvc:
    storageClass: 3x-replica-hdd

oidc:
  enabled: true
  existingSecret: osdf-component-oidc
  adminUsers:
    - "http://cilogon.org/serverE/users/12345"
    - "http://cilogon.org/serverA/users/67890"
  adminGroups:
    - "osg-ops"
webPassword:
  existingSecret: my-web-passwd-secret

xrootd:
  extraConfig: |
    xrd.sched maxt 20000

nodeSelector:
  kubernetes.io/hostname: my-cache-node.example.com

securityContext:
  capabilities:
    add: ["SYS_PTRACE"]

```

### Non-OSDF Federation

```yaml
serverHostname: my-cache.example.com
sitename: MY_CACHE

federation:
  discoveryUrl: "https://my-federation.example.com"


cache:
  image:
    # Use the generic Pelican cache image instead of the OSDF-specific one
    repository: hub.opensciencegrid.org/pelican_platform/cache
  type: pvc
  pvc:
    storageClass: local-nvme

# ...plus issuerKey, logging, database and webPassword settings as shown above
```

## Validation Requirements

The chart enforces the following validation rules at render time to ensure a valid configuration:

**Issuer Key:**
- `issuerKey.existingSecret` must be nonempty

## Secrets Management

This chart **does not create Secrets**. All sensitive material must be provisioned separately before installing the chart. Common approaches:

- **[Sealed Secrets](https://sealed-secrets.netlify.app/)** — Used in the original tiger-osg-config deployment
- **[External Secrets Operator](https://external-secrets.io/)**
- **Manual creation** via `kubectl create secret`

Secrets the chart may reference:

| Value pointing to Secret | Keys expected | Purpose |
|---|---|---|
| `issuerKey.existingSecret` | Key named per `issuerKey.secretKey` (default: `private-key.pem`) | Pelican issuer/signing key |
| `oidc.existingSecret` | `client.id`, `client.secret` | OIDC client credentials |
| `webPassword.existingSecret` | Key named per `webPassword.key` (default: `server-web-passwd`) | Web UI password file |
| `tls.existingSecret` | `tls.crt`, `tls.key` | TLS certificate (if not using cert-manager) |

## Upgrading

When configuration values change, the Deployment will automatically roll because pod annotations include checksums of the ConfigMaps. Image tag changes trigger a rollout as usual.

The `Recreate` deployment strategy is used (not `RollingUpdate`) because the cache holds a lock on its data directory and cannot run two instances simultaneously.

## Development

```bash
# Lint the chart
helm lint . --set serverHostname=test.example.com --set sitename=test-site --set cache.pvc.storageClass=std --set logging.persistence.storageClass=std --set database.persistence.storageClass=std --set issuerKey.existingSecret=issuer-key --set webPassword.existingSecret=pw

# Render templates locally
helm template my-cache . -f ci/uw-osdf-cache-values.yaml

# Diff against a live release
helm diff upgrade my-cache . -f my-values.yaml
```

## License

See repository license.
