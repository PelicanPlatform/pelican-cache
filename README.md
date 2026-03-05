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
- [cert-manager](https://cert-manager.io/) (if using `certificate.enabled: true`)
- Pre-created Secrets for sensitive data (issuer keys, OIDC credentials, web UI passwords)

## Quick Start

### Minimal installation

```bash
helm install my-cache ./pelican-cache \
  --set serverHostname=my-cache.example.com \
  --set cache.storageClassName=my-storage-class \
  --set logging.storageClassName=my-storage-class \
  --set certificate.dnsNames[0]=my-cache.example.com
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

Pelican supports loading configuration from multiple files via `ConfigLocations`. This chart now generates a single ConfigMap that contains both layers:

1. **`pelican-config`** (mounted at `/etc/pelican/pelican.yaml` and `/etc/pelican/config.d/50-instance.yaml`) — Includes fixed infrastructure config (`pelican.yaml`) and generated instance settings (`50-instance.yaml`) from your values: federation URL, hostname, cache tuning, OIDC, Lotman, logging levels, XRootD settings, and any `extraPelicanConfig`.

Pelican merges these in order, with later files taking precedence.

### Storage

The chart manages several persistent volumes:

| Volume | Purpose | Backing |
|---|---|---|
| Cache data | XRootD file cache | PVC or hostPath (`cache.storageType`) |
| Logging | Pelican log files | PVC (always) |
| Namespace key | Pelican issuer/signing key | PVC or existing Secret (`namespaceKey.type`) |
| Lotman data | Lot-based storage management | PVC (when `lotman.enabled`) |

**NVMe storage is strongly recommended for the cache data volume.**

## Configuration Reference

### Required Values

| Parameter | Description |
|---|---|
| `serverHostname` | External FQDN of the cache. Chart fails to render without this. |

### Images

| Parameter | Default | Description |
|---|---|---|
| `image.repository` | `hub.opensciencegrid.org/pelican_platform/osdf-cache` | Cache container image |
| `image.tag` | `v7.23.0` | Cache image tag |
| `image.pullPolicy` | `Always` | Image pull policy |
| `logrotateImage.repository` | `hub.opensciencegrid.org/opensciencegrid/logrotate` | Logrotate sidecar image |
| `logrotateImage.tag` | `24-release` | Logrotate image tag |

### Federation

| Parameter | Default | Description |
|---|---|---|
| `federation.discoveryUrl` | `https://osg-htc.org` | Federation discovery URL. Change for non-OSDF or ITB. |

### Cache Storage

| Parameter | Default | Description |
|---|---|---|
| `cache.storageType` | `pvc` | `pvc` or `hostPath` |
| `cache.hostPath` | `""` | Host path (required when storageType is `hostPath`) |
| `cache.storageClassName` | `""` | StorageClass for cache data PVC |
| `cache.pvcSize` | `1000Gi` | Cache data PVC size |

### Cache Tuning

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

### Issuer / Namespace Key

| Parameter | Default | Description |
|---|---|---|
| `namespaceKey.type` | `pvc` | `pvc` (Pelican auto-generates) or `existingSecret` |
| `namespaceKey.pvc.storageClassName` | `""` | StorageClass for key PVC |
| `namespaceKey.pvc.size` | `10Mi` | Key PVC size |
| `namespaceKey.existingSecret` | `""` | Pre-existing Secret name (when type is `existingSecret`) |
| `namespaceKey.secretKey` | `issuer.pem` | Key within the Secret |

### TLS / Certificates

| Parameter | Default | Description |
|---|---|---|
| `certificate.enabled` | `true` | Create a cert-manager Certificate |
| `certificate.issuerRef.name` | `letsencrypt-prod` | Issuer name |
| `certificate.issuerRef.kind` | `ClusterIssuer` | Issuer kind |
| `certificate.dnsNames` | `[]` | DNS SANs (should include `serverHostname`) |
| `tls.existingSecret` | `""` | Use an existing TLS Secret instead of cert-manager |

### Service

| Parameter | Default | Description |
|---|---|---|
| `service.type` | `LoadBalancer` | Service type |
| `service.loadBalancerIP` | `""` | Request a specific LB IP |
| `service.externalTrafficPolicy` | `Local` | Traffic policy |
| `service.annotations` | `{}` | Extra annotations (external-dns, metallb, etc.) |

### Resources

| Parameter | Default | Description |
|---|---|---|
| `resources.cache.requests.cpu` | `1000m` | Cache container CPU request |
| `resources.cache.requests.memory` | `16Gi` | Cache container memory request |
| `resources.cache.limits` | `{}` | Cache container limits |
| `resources.logrotate.requests.cpu` | `1` | Logrotate CPU request |
| `resources.logrotate.requests.memory` | `500M` | Logrotate memory request |
| `resources.logrotate.limits.cpu` | `2` | Logrotate CPU limit |
| `resources.logrotate.limits.memory` | `2G` | Logrotate memory limit |

### Logging

| Parameter | Default | Description |
|---|---|---|
| `logging.level` | `INFO` | Global Pelican log level |
| `logging.storageClassName` | `""` | StorageClass for logging PVC |
| `logging.pvcSize` | `5Gi` | Logging PVC size |
| `logging.cache` | `{}` | Per-subsystem log levels (map, e.g. `{Pss: debug, Pfc: debug}`) |

### Optional Components

| Parameter | Default | Description |
|---|---|---|
| `cvmfsRedirector.enabled` | `false` | Enable CVMFS port redirector sidecar |
| `lotman.enabled` | `false` | Enable Lotman (lot-based storage management) |
| `lotman.storageClassName` | `""` | StorageClass for Lotman PVC |
| `lotman.pvcSize` | `10Gi` | Lotman PVC size |
| `oidc.enabled` | `false` | Enable OIDC authentication |
| `oidc.existingSecret` | `""` | Secret with `client.id` and `client.secret` keys |

### Admin / Web UI

| Parameter | Default | Description |
|---|---|---|
| `adminUsers` | `""` | Space-separated CILogon admin user identities |
| `webPasswordSecret` | `""` | Existing Secret for web UI password |
| `webPasswordSecretKey` | `password` | Key within the web password Secret |

### XRootD

| Parameter | Default | Description |
|---|---|---|
| `xrootd.sitename` | `""` | XRootD site name reported to the federation |
| `xrootd.extraConfig` | `""` | Raw `xrootd.conf` content (e.g. `xrd.sched maxt 20000`) |

### Network Policy

| Parameter | Default | Description |
|---|---|---|
| `networkPolicy.enabled` | `true` | Create a NetworkPolicy |

### Scheduling

| Parameter | Default | Description |
|---|---|---|
| `nodeSelector` | `{}` | Pod node selector |
| `tolerations` | `[]` | Pod tolerations |
| `affinity` | `{}` | Pod affinity rules |

### Escape Hatches

| Parameter | Default | Description |
|---|---|---|
| `extraPelicanConfig` | `{}` | Arbitrary YAML merged into the instance config |
| `extraEnv` | `[]` | Extra env vars for the cache container |
| `extraVolumes` | `[]` | Extra volumes for the pod |
| `extraVolumeMounts` | `[]` | Extra volume mounts for the cache container |
| `podAnnotations` | `{}` | Extra pod annotations |
| `securityContext` | `{}` | Security context for the cache container |

## Examples

### Minimal OSDF Cache (PVC-backed)

```yaml
serverHostname: my-cache.osg-htc.org

cache:
  storageClassName: fast-nvme
  pvcSize: 2000Gi

logging:
  storageClassName: standard

certificate:
  dnsNames:
    - my-cache.osg-htc.org
```

### Production Cache (hostPath, like uw-osdf-cache)

```yaml
serverHostname: osdf-uw-cache.svc.osg-htc.org

image:
  tag: "v7.23.0"

cache:
  storageType: hostPath
  hostPath: /srv/pelican-cache/
  blocksToPrefetch: 10
  concurrency: 240
  highWaterMark: 27000g
  lowWaterMark: 25000g

namespaceKey:
  type: existingSecret
  existingSecret: my-cache-issuer-key

certificate:
  dnsNames:
    - osdf-uw-cache.svc.osdf-prod.chtc.io
    - osdf-uw-cache.svc.osg-htc.org

service:
  loadBalancerIP: "128.105.82.176"
  annotations:
    external-dns.alpha.kubernetes.io/hostname: osdf-uw-cache.svc.osdf-prod.chtc.io
    metallb.universe.tf/address-pool: tiger-vlan5

resources:
  cache:
    requests:
      cpu: "24"
      memory: "48Gi"

logging:
  level: debug
  storageClassName: 3x-replica-hdd
  pvcSize: 50Gi
  cache:
    Pss: debug
    Pfc: debug

lotman:
  enabled: true
  storageClassName: 3x-replica-hdd

oidc:
  enabled: true
  existingSecret: osdf-component-oidc

adminUsers: "http://cilogon.org/serverE/users/12345 http://cilogon.org/serverA/users/67890"
webPasswordSecret: my-web-passwd-secret

xrootd:
  sitename: MY_PELICAN_CACHE
  extraConfig: |
    xrd.sched maxt 20000

nodeSelector:
  kubernetes.io/hostname: my-cache-node.example.com

securityContext:
  capabilities:
    add: ["SYS_PTRACE"]

extraEnv:
  - name: XRD_CURLDISABLEX509
    value: "1"
```

### Non-OSDF Federation

```yaml
serverHostname: my-cache.example.com

federation:
  discoveryUrl: "https://my-federation.example.com"

image:
  # Use the generic Pelican cache image instead of the OSDF-specific one
  repository: hub.opensciencegrid.org/pelican_platform/cache

cache:
  storageClassName: local-nvme
```

## Secrets Management

This chart **does not create Secrets**. All sensitive material must be provisioned separately before installing the chart. Common approaches:

- **[Sealed Secrets](https://sealed-secrets.netlify.app/)** — Used in the original tiger-osg-config deployment
- **[External Secrets Operator](https://external-secrets.io/)**
- **Manual creation** via `kubectl create secret`

Secrets the chart may reference:

| Value pointing to Secret | Keys expected | Purpose |
|---|---|---|
| `namespaceKey.existingSecret` | Key named per `namespaceKey.secretKey` (default: `issuer.pem`) | Pelican issuer/signing key |
| `oidc.existingSecret` | `client.id`, `client.secret` | OIDC client credentials |
| `webPasswordSecret` | Key named per `webPasswordSecretKey` (default: `password`) | Web UI password file |
| `tls.existingSecret` | `tls.crt`, `tls.key` | TLS certificate (if not using cert-manager) |

## Upgrading

When configuration values change, the Deployment will automatically roll because pod annotations include checksums of the ConfigMaps. Image tag changes trigger a rollout as usual.

The `Recreate` deployment strategy is used (not `RollingUpdate`) because the cache holds a lock on its data directory and cannot run two instances simultaneously.

## Development

```bash
# Lint the chart
helm lint . --set serverHostname=test.example.com

# Render templates locally
helm template my-cache . -f ci/uw-osdf-cache-values.yaml

# Diff against a live release
helm diff upgrade my-cache . -f my-values.yaml
```

## Relationship to tiger-osg-config

This chart is a standalone replacement for the Kustomize + Flux deployment model used in [opensciencegrid/tiger-osg-config](https://github.com/opensciencegrid/tiger-osg-config). The `ci/uw-osdf-cache-values.yaml` file demonstrates a 1:1 mapping from the `uw-osdf-cache` Kustomize overlays to Helm values.

| Kustomize layer | Helm equivalent |
|---|---|
| `base/pelican-cache/pelican.yaml` | `configmap-pelican.yaml` template (fixed) |
| `base/pelican-cache/deployment.yaml` | `deployment.yaml` template |
| `base/osdf-pelican-cache/10-osdf.yaml` | `federation.discoveryUrl` value |
| Instance `50-instance.yaml` | Generated by `_helpers.tpl` and stored in `configmap-pelican.yaml` |
| Instance `deployment-patch.yaml` | Values: `resources`, `nodeSelector`, `securityContext`, `extraEnv`, etc. |
| Instance `service-patch.yaml` | Values: `service.*` |
| Instance `cert-patch.yaml` | Values: `certificate.dnsNames` |
| Instance PVC patches | Values: `cache.storageType`, `logging.*`, `namespaceKey.*`, `lotman.*` |

## License

See repository license.
