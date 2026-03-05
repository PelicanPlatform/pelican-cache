# AGENTS.md — Context for AI Coding Agents

This file provides context so that AI coding agents (GitHub Copilot, Cursor, Aider, etc.) can work effectively on this project when opened in a new session without prior conversation history.

## Project Overview

This is a **Helm chart** (`pelican-cache`) that deploys a [Pelican Platform](https://pelicanplatform.org) **cache** server on Kubernetes, targeting the [Open Science Data Federation (OSDF)](https://osg-htc.org/services/osdf.html).

## Origin and Reference Implementation

The chart was derived from a Kustomize + Flux deployment in the [opensciencegrid/tiger-osg-config](https://github.com/opensciencegrid/tiger-osg-config) repository. The reference instance is:

```
manifests/tiger/osdf-prod/uw-osdf-cache/
```

That deployment uses a **three-layer Kustomize inheritance chain**:

1. `manifests/base/pelican-cache/` — Generic Pelican cache base (Deployment with 3 containers: `pelican-cache`, `cvmfs-redirector`, `logrotate`; Service; 3 PVCs; NetworkPolicy; cert-manager Certificate; ConfigMaps for pelican.yaml and logrotate)
2. `manifests/base/osdf-pelican-cache/` — OSDF overlay (adds `osdf-` namePrefix, `federation: osdf` label, sets `Federation.DiscoveryUrl` to `https://osg-htc.org`, replaces overlay-config emptyDir with a ConfigMap)
3. `manifests/tiger/osdf-prod/uw-osdf-cache/` — Instance overlay (pins images, pins to a specific node, deletes cvmfs-redirector, replaces cache-data PVC with hostPath, replaces namespace-key PVC with a Secret from SealedSecret, adds lotman/OIDC/web-password volumes, sets heavy resources and cache tuning)

This chart collapses all three layers into parameterized Helm templates.

## File Structure

```
pelican-cache/
├── Chart.yaml                          # Chart metadata, appVersion tracks Pelican version
├── values.yaml                         # All configurable values with defaults
├── README.md                           # User-facing documentation
├── AGENTS.md                           # This file — AI agent context
├── .devcontainer/
│   └── devcontainer.json               # Dev container for chart development
├── ci/
│   └── uw-osdf-cache-values.yaml       # Test values mirroring the real uw-osdf-cache
└── templates/
    ├── _helpers.tpl                     # Template helpers:
    │                                    #   - pelican-cache.fullname
    │                                    #   - pelican-cache.labels / selectorLabels
    │                                    #   - pelican-cache.tlsSecretName
    │                                    #   - pelican-cache.issuerKeyPath
    │                                    #   - pelican-cache.instanceConfig (generates 50-instance.yaml)
    ├── deployment.yaml                  # Deployment: 2-3 containers, conditional volumes
    ├── service.yaml                     # LoadBalancer Service
    ├── networkpolicy.yaml               # NetworkPolicy (conditional)
    ├── certificate.yaml                 # cert-manager Certificate (conditional)
    ├── configmap-pelican.yaml           # Base + instance Pelican config (pelican.yaml + 50-instance.yaml)
    ├── configmap-logrotate.yaml         # Logrotate configuration
    ├── configmap-xrootd.yaml            # Custom xrootd.conf (conditional)
    ├── pvc-cache-data.yaml              # Cache data PVC (conditional on storageType=pvc)
    ├── pvc-logging.yaml                 # Logging PVC (always created)
    ├── pvc-namespace-key.yaml           # Namespace key PVC (conditional on type=pvc)
    ├── pvc-lotman.yaml                  # Lotman PVC (conditional on lotman.enabled)
    └── NOTES.txt                        # Post-install notes
```

## Key Design Decisions

1. **Pelican config layering**: One ConfigMap (`pelican-config`) contains both `pelican.yaml` (infrastructure paths) and `50-instance.yaml` (user settings). Pelican's `ConfigLocations` directive merges the files in order.

2. **Secrets are never chart-managed**: The chart only _references_ pre-existing Secrets. This is intentional — issuer keys, OIDC credentials, TLS certs, and passwords are sensitive and should be managed via SealedSecrets, External Secrets Operator, or manual creation.

3. **Storage flexibility**: Cache data can be PVC or hostPath (production OSDF caches often use hostPath to dedicated NVMe). The namespace/issuer key can be a PVC (Pelican auto-generates the key) or an existing Secret (for key portability across reinstalls).

4. **CVMFS redirector defaults to off**: The original base includes it, but the uw-osdf-cache (and most modern deployments) delete it. Defaulting to off matches the common case.

5. **`Recreate` strategy**: The Deployment uses `Recreate` (not `RollingUpdate`) because Pelican holds an exclusive lock on its cache data directory.

6. **ConfigMap checksum annotations**: The Deployment template includes `sha256sum` checksums of the ConfigMaps as pod annotations, so config changes trigger automatic rollouts.

## Pelican-Specific Knowledge

- **Pelican** is a data federation platform built on XRootD. A "cache" is a read-through caching proxy.
- **OSDF** = Open Science Data Federation, the primary Pelican federation run by OSG.
- **Federation Discovery URL** (`https://osg-htc.org`) tells Pelican where to find the OSDF director and registry.
- **IssuerKey** is a JWK used to sign tokens. When using a PVC, Pelican auto-generates it on first start. When using an existing Secret, the operator provides a pre-generated key.
- **Lotman** = lot-based storage management (experimental). Manages disk quotas per "lot."
- **CVMFS port redirector** = a sidecar that redirects legacy CVMFS clients (port 8000) to the Pelican cache.
- **Cache.StorageLocation**: In Pelican 7.12+, `StorageLocation` is the preferred cache path setting.
- **`Cache.HighWaterMark` / `LowWaterMark`**: XRootD's cache eviction thresholds. When total disk usage crosses the high watermark, files are evicted until it drops below the low watermark.
- **`Files*Size` parameters**: Fine-grained diskusage tracking specific to the mount where cache data lives. `FilesMaxSize` must be lower than the low water mark.
- **`Cache.Concurrency`**: Guidance is 10× the number of CPU cores.

## Testing the Chart

```bash
# Lint
helm lint . --set serverHostname=test.example.com

# Render with minimal values
helm template test . --set serverHostname=test.example.com

# Render with full uw-osdf-cache-equivalent values
helm template test . -f ci/uw-osdf-cache-values.yaml

# Verify required value validation
helm template test .   # Should fail with "serverHostname is required"
```

## Common Modification Patterns

### Adding a new Pelican config knob

1. Add the value to `values.yaml` with a sensible default (usually empty string to mean "omit").
2. Add a conditional block in the `pelican-cache.instanceConfig` template in `_helpers.tpl`.
3. Test with `helm template`.

### Adding a new optional sidecar container

1. Add an `enabled` toggle in `values.yaml`.
2. Add a `{{- if .Values.newSidecar.enabled }}` block in `deployment.yaml` in the `containers` list.
3. Add any associated volumes, PVCs, or ConfigMaps with the same conditional guard.

### Adding a new volume type

1. Add values (type, storageClassName, size, existingSecret, etc.) to `values.yaml`.
2. Add conditional PVC template if needed.
3. Add the volume to the `volumes` list in `deployment.yaml`.
4. Add the volumeMount to the appropriate container(s).

## Upstream Resources

- Pelican documentation: https://docs.pelicanplatform.org/
- Pelican GitHub: https://github.com/PelicanPlatform/pelican
- OSDF: https://osg-htc.org/services/osdf.html
- tiger-osg-config (reference Kustomize deployment): https://github.com/opensciencegrid/tiger-osg-config
- XRootD PFC configuration: https://xrootd.web.cern.ch/doc/dev56/pss_config.pdf
