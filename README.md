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
    Create this with `pelican generate password`

-   Issuer key
    Create this with `pelican key create`

### Minimal installation

```bash
helm install my-cache ./pelican-cache \
  --set serverHostname=my-cache.example.com \
  --set sitename=my-site \
  --set cache.pvc.storageClass=my-storage-class \
  --set logging.persistence.storageClass=my-storage-class \
  --set issuerKey.pvc.storageClass=my-storage-class \
  --set webPassword.existingSecret=my-web-passwd-secret
```

### Installation with a values file

```bash
helm install my-cache ./pelican-cache -f my-values.yaml
```

See [ci/uw-osdf-cache-values.yaml](ci/uw-osdf-cache-values.yaml) for a complete example that mirrors the real UW-Madison OSDF cache deployment.

## Architecture

The chart deploys a single Pod with up to three containers:

| Container | Purpose | Optional |
|---|---|---|
| `pelican-cache` | Main Pelican cache process | No |
| `logrotate` | Rotates Pelican log files | No |
| `cvmfs-redirector` | CVMFS port redirector sidecar | Yes (`cvmfsRedirector.enabled`) |

### Pelican Configuration Layering

Pelican supports loading configuration from multiple files via `ConfigLocations`. This chart generates a single ConfigMap (`pelican-config`) containing two files:

- **`pelican.yaml`** — Fixed infrastructure config (storage paths, ports, TLS paths).
- **`50-instance.yaml`** — Generated from your values: federation URL, hostname, cache tuning, OIDC, Lotman, logging levels, XRootD settings, and any `extraPelicanConfig`.

Both are mounted under `/etc/pelican/` and Pelican merges them in order, with later files taking precedence.

### Storage

The chart manages several persistent volumes:

| Volume | Purpose | Backing |
|---|---|---|
| Cache data | XRootD file cache | PVC or hostPath (`cache.type`) |
| Logging | Pelican log files | Dedicated PVC (default) or shared with cache data (`logging.persistence.separateVolume`) |
| Issuer key | Pelican issuer/signing key | PVC or existing Secret (`issuerKey.type`) |
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
| `issuerKey.type` | `pvc` | `pvc` (Pelican auto-generates) or `existingSecret` |
| `issuerKey.pvc.storageClass` | `""` | StorageClass for key PVC |
| `issuerKey.pvc.size` | `10Mi` | Key PVC size |
| `issuerKey.existingSecret` | `""` | Pre-existing Secret name (when type is `existingSecret`) |
| `issuerKey.secretKey` | `private-key.pem` | Key within the Secret |

You must specify a way to store the issuer key (which is the key Pelican uses to sign credentials
and authenticate itself to the federation).
Your options are:

1.  Have Pelican generate the key and save it to a PVC that the chart creates.
    To do this, specify `issuerKey.type: pvc` and `issuerKey.pvc.storageClass` to one of the available storage types in your cluster.
    PVCs created by this chart will not be deleted on uninstall.

2.  Pre-create the key using the `pelican key create` command, and save it as a secret.
    To do this, specify `issuerKey.type: existingSecret` and specify the secret name as `issuerKey.existingSecret`.

### Logging (customization required)

| Parameter | Default | Description |
|---|---|---|
| `logging.persistence.separateVolume` | `true` | Provision a dedicated PVC for `/var/log/pelican`; when `false`, the data volume is also mounted at `/var/log` so `/var/log/pelican` can still live on cache storage. Logrotate always runs. |
| `logging.level` | `INFO` | Global Pelican log level |
| `logging.persistence.existingClaim` | `""` | Existing logging PVC name (if set, ignores `storageClass` and `size`) |
| `logging.persistence.storageClass` | `""` | StorageClass for new logging PVC (required if `existingClaim` is not set and `separateVolume=true`) |
| `logging.persistence.size` | `50Gi` | Logging PVC size (used when creating a new PVC) |
| `logging.cache` | `{}` | Per-subsystem log levels (map, e.g. `{Pss: debug, Pfc: debug}`) |

### Admin / Web UI (customization required)

| Parameter | Default | Description |
|---|---|---|
| `adminUsers` | `[]` | List of CILogon admin user identities |
| `webPassword.existingSecret` | `""` | Existing Secret for web UI password |
| `webPassword.key` | `server-web-passwd` | Key within the web password Secret |

You must create a secret containing a file named `server-web-passwd` that was created by running `pelican generate password`
and specify that as `webPassword.existingSecret`.

### Federation (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `federation.discoveryUrl` | `https://osg-htc.org` | Federation discovery URL. Change for non-OSDF or ITB. |
| `federation.label` | `osdf` | Resource label indicating the federation. This must match the discovery URL when set to known values. |

The federation label and discovery URL have to match for the OSDF and OSDF-ITB federations.
The valid pairs are:

| discoveryUrl | label |
|---|---|
| https://osg-htc.org | osdf |
| https://osdf-itb.osg-htc.org | osdf-itb |

Checks are not performed for other federations.
The default federation is OSDF so OSDF caches do not need to change this section.

### Images (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `image.repository` | `hub.opensciencegrid.org/pelican_platform/osdf-cache` | Cache container image |
| `image.tag` | `""` | Cache image tag (defaults to chart `appVersion` when empty) |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy for the cache container |
| `logrotate.image.repository` | `hub.opensciencegrid.org/opensciencegrid/logrotate` | Logrotate sidecar image |
| `logrotate.image.tag` | `24-release` | Logrotate image tag |

The logrotate sidecar always uses `imagePullPolicy: Always` and that behavior is
not configurable.

### Cache Tuning (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `cache.blocksToPrefetch` | `""` | Blocks to prefetch (e.g. `10`) |
| `cache.concurrency` | `""` | Max concurrent requests (e.g. `240` — guidance: 10× core count) |
| `cache.highWaterMark` | `""` | Eviction high watermark (e.g. `27000g`) |
| `cache.lowWaterMark` | `""` | Eviction low watermark (e.g. `25000g`) |
| `cache.filesMaxSize` | `""` | XRootD diskusage max tracked size. Must be < low watermark. |
| `cache.filesNominalSize` | `""` | XRootD diskusage nominal tracked size |
| `cache.filesBaseSize` | `""` | XRootD diskusage base tracked size |

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

| Parameter | Default | Description |
|---|---|---|
| `service.type` | `LoadBalancer` | Service type (ignored when `hostNetwork` is enabled) |
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
| `logrotate.size` | `500M` | Log file size threshold that triggers rotation |
| `logrotate.rotate` | `10` | Number of rotated log files to keep |

### Optional Components

| Parameter | Default | Description |
|---|---|---|
| `sleep` | `false` | Debug mode: run `sleep infinity` in the `pelican-cache` container instead of starting the cache process |
| `hostNetwork` | `false` | Use host networking (`spec.hostNetwork=true`) to bind directly to node IP. When enabled, no Service or NetworkPolicy is created. |
| `server.cachePort` | `8443` | Cache port exposed by Pelican and used by container/service/network policy mappings |
| `server.webPort` | `443` | Web UI port exposed by Pelican and container port mapping |
| `cvmfsRedirector.enabled` | `false` | Enable CVMFS port redirector sidecar |
| `lotman.enabled` | `false` | Enable Lotman (lot-based storage management) |
| `lotman.pvc.existingClaim` | `""` | Existing Lotman PVC name (if set, ignores `storageClass` and `size`) |
| `lotman.pvc.storageClass` | `""` | StorageClass for new Lotman PVC (required if `existingClaim` is not set and `enabled=true`) |
| `lotman.pvc.size` | `10Gi` | Lotman PVC size (used when creating a new PVC) |
| `oidc.enabled` | `false` | Enable OIDC authentication |
| `oidc.existingSecret` | `""` | Secret with `client.id` and `client.secret` keys |

When `sleep` is `true`, the `pelican-cache` container starts with `sleep infinity` for debugging. After you `kubectl exec` into the container, you can start the cache manually with `pelican cache serve`.

### XRootD (customization optional)

| Parameter | Default | Description |
|---|---|---|
| `xrootd.extraConfig` | `""` | Raw `xrootd.conf` content (e.g. `xrd.sched maxt 20000`) |

`xrootd.extraConfig` is an escape hatch for settings that cannot be expressed
through normal chart values. Prefer regular chart parameters when possible.

### Network Policy

| Parameter | Default | Description |
|---|---|---|
| `networkPolicy.enabled` | `true` | Create a NetworkPolicy (ignored when `hostNetwork` is enabled) |

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

issuerKey:
  pvc:
    storageClass: standard

webPassword:
  existingSecret: my-web-passwd-secret
```

### Production Cache (hostPath, like uw-osdf-cache)

```yaml
serverHostname: osdf-uw-cache.svc.osg-htc.org
sitename: MY_PELICAN_CACHE

image:
  tag: "v7.23.0"

cache:
  type: hostPath
  hostPath:
    path: /srv/pelican-cache/
  blocksToPrefetch: 10
  concurrency: 240
  highWaterMark: 27000g
  lowWaterMark: 25000g
  resources:
    requests:
      cpu: "24"
      memory: "48Gi"

issuerKey:
  type: existingSecret
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
  label: my-federation

image:
  # Use the generic Pelican cache image instead of the OSDF-specific one
  repository: hub.opensciencegrid.org/pelican_platform/cache

cache:
  type: pvc
  pvc:
    storageClass: local-nvme

# ...plus issuerKey, logging, and webPassword settings as shown above
```

## Validation Requirements

The chart enforces the following validation rules at render time to ensure a valid configuration:

**Storage:**
- If `cache.type` is `pvc`:
  - If `cache.pvc.existingClaim` is empty, `cache.pvc.storageClass` must be nonempty
  - If `cache.pvc.existingClaim` is set, `storageClass` and `size` are ignored
- If `cache.type` is `hostPath`:
  - `cache.hostPath.path` must be nonempty

**Issuer Key:**
- If `issuerKey.type` is `pvc`, `issuerKey.pvc.storageClass` must be nonempty
- If `issuerKey.type` is `existingSecret`, `issuerKey.existingSecret` must be nonempty

**Logging:**
- If `logging.persistence.separateVolume` is `true` and `logging.persistence.existingClaim` is empty, `logging.persistence.storageClass` must be nonempty

**Lotman:**
- If `lotman.enabled` is `true` and `lotman.pvc.existingClaim` is empty, `lotman.pvc.storageClass` must be nonempty

**OIDC:**
- If `oidc.enabled` is `true`, `oidc.existingSecret` must be nonempty

**Web UI:**
- `webPassword.existingSecret` must be nonempty

**Site Identity:**
- `serverHostname` must be nonempty
- `sitename` must be nonempty

**TLS:**
- `tls.certManager.enabled` and `tls.existingSecret` cannot both be set
- When `tls.certManager.enabled` is false, `tls.existingSecret` must be nonempty

**Federation:**
- If `federation.discoveryUrl` or `federation.label` match a known federation pair (OSDF or OSDF-ITB), both must be set consistently

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
helm lint . --set serverHostname=test.example.com --set sitename=test-site --set cache.pvc.storageClass=std --set logging.persistence.storageClass=std --set issuerKey.pvc.storageClass=std --set webPassword.existingSecret=pw

# Render templates locally
helm template my-cache . -f ci/uw-osdf-cache-values.yaml

# Diff against a live release
helm diff upgrade my-cache . -f my-values.yaml
```

## License

See repository license.
