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
│   ├── devcontainer.json               # Dev container for chart development
│   └── post-create.sh                  # Post-creation setup script
├── ci/
│   ├── uw-osdf-cache-values.yaml              # Test values mirroring the real uw-osdf-cache (hostPath-backed)
│   ├── houston2-i2-pelican-cache-values.yaml  # Test values for Nautilus deployment (hostPath-backed)
│   └── itb-osdf-pelican-cache-values.yaml     # Test values for ITB federation (PVC-backed)
└── templates/
    ├── _helpers.tpl                     # Template helpers:
    │                                    #   - pelican-cache.fullname
    │                                    #   - pelican-cache.labels / selectorLabels
    │                                    #   - pelican-cache.tlsSecretName
    │                                    #   - pelican-cache.instanceConfig (generates 50-instance.yaml)
    │                                    #   - pelican-cache.shouldRenderPvc (avoids PVC adoption conflicts)
    │                                    #   - pelican-cache.validateFederation / validateRequiredValues
    ├── deployment.yaml                  # Deployment: 2-3 containers, conditional volumes
    ├── service.yaml                     # LoadBalancer Service
    ├── networkpolicy.yaml               # NetworkPolicy (conditional)
    ├── certificate.yaml                 # cert-manager Certificate (conditional)
    ├── configmap-pelican.yaml           # Base + instance Pelican config (pelican.yaml + 50-instance.yaml)
    ├── configmap-logrotate.yaml         # Logrotate configuration
    ├── configmap-xrootd.yaml            # Custom xrootd.conf (conditional)
    ├── pvc-cache-data.yaml              # Cache data PVC (conditional on type=pvc)
    ├── pvc-logging.yaml                 # Logging PVC (conditional on logging.persistence.separateVolume)
    ├── pvc-lotman.yaml                  # Lotman PVC (conditional on lotman.enabled)
    ├── validate.yaml                    # Render-time validation trigger (no resources emitted)
    └── NOTES.txt                        # Post-install notes
```

## Key Design Decisions

1. **Pelican config layering**: One ConfigMap (`pelican-config`) contains both `pelican.yaml` (infrastructure paths) and `50-instance.yaml` (user settings). Pelican's `ConfigLocations` directive merges the files in order.

2. **Secrets are never chart-managed**: The chart only _references_ pre-existing Secrets. This is intentional — issuer keys, OIDC credentials, TLS certs, and passwords are sensitive and should be managed via SealedSecrets, External Secrets Operator, or manual creation.

3. **Storage flexibility with discriminated union pattern**: Cache data uses a `type` discriminator:
   - `type: pvc` → uses `cache.pvc.*` settings (supports both creating new PVCs and referencing existing ones via `cache.pvc.existingClaim`)
   - `type: hostPath` → uses `cache.hostPath.path` for direct node attachment
  - Issuer key is always sourced from a pre-existing Secret via `issuerKey.existingSecret`.
   
   **Why discriminated union, not optional `persistence`?** Unlike typical services where persistence is optional,
   a cache **requires** persistent storage by design. Using the optional `persistence.enabled` pattern would allow
   misconfiguration (e.g., accidentally disabling persistence or omitting storage config). The discriminated union
   pattern forces the user to choose WHERE to persist and ensures all required fields for that branch are explicitly set,
   preventing silent misconfiguration.

4. **CVMFS redirector defaults to off**: The original base includes it, but the uw-osdf-cache (and most modern deployments) delete it. Defaulting to off matches the common case.

5. **Public service exposure by default**: `service.type` defaults to `LoadBalancer` intentionally. This cache is expected to be publicly reachable; `ClusterIP` is not useful for the primary deployment target, and routing through Ingress adds an extra hop that can hurt throughput and latency.

6. **`Recreate` strategy**: The Deployment uses `Recreate` (not `RollingUpdate`) because Pelican holds an exclusive lock on its cache data directory.

7. **ConfigMap checksum annotation**: The Deployment template includes a `sha256sum` checksum of the Pelican ConfigMap as a pod annotation (`checksum/pelican-config`), so Pelican config changes trigger automatic rollouts.

8. **Open ingress policy by default**: The NetworkPolicy allows ingress from any source (on explicit service ports) intentionally. This cache serves federation clients globally, so restrictive source allowlists are not a sensible default.

9. **Template-time validation**: The chart enforces required values at render time via the `pelican-cache.validateRequiredValues` helper in `_helpers.tpl`. This ensures:
   - `serverHostname` is set
  - Storage configurations are complete for their type (e.g., `cache.pvc.storageClass` required for new PVCs, but not if using `cache.pvc.existingClaim`)
   - Namespace key and logging storage configured appropriately
   - Optional features (Lotman, OIDC) have their required secrets/storage when enabled
   - Federation label/URL consistency (OSDF and OSDF-ITB have defined pairs)

10. **Safe PVC rendering with `lookup`**: The PVC templates use the `pelican-cache.shouldRenderPvc` helper to render only when a PVC is absent or already managed by the same Helm release. This avoids Helm trying to adopt unrelated pre-existing PVCs while still allowing upgrades to manage release-owned PVC metadata.

## Pelican-Specific Knowledge

- **Pelican** is a data federation platform built on XRootD. A "cache" is a read-through caching proxy.
- **OSDF** = Open Science Data Federation, the primary Pelican federation run by OSG.
- **Federation Discovery URL** (`https://osg-htc.org`) tells Pelican where to find the OSDF director and registry.
- **IssuerKey** is a JWK used to sign tokens. The chart expects operators to pre-generate it and provide it via an existing Secret.
- **Lotman** = lot-based storage management (experimental). Manages disk quotas per "lot."
- **CVMFS port redirector** = a sidecar that redirects legacy CVMFS clients (port 8000) to the Pelican cache.
- **Cache.StorageLocation**: In Pelican 7.12+, `StorageLocation` is the preferred cache path setting.
- **`Cache.HighWaterMark` / `LowWaterMark`**: XRootD's cache eviction thresholds. When total disk usage crosses the high watermark, files are evicted until it drops below the low watermark.
- **`Files*Size` parameters**: Fine-grained diskusage tracking specific to the mount where cache data lives. `FilesMaxSize` must be lower than the low water mark.
- **`Cache.Concurrency`**: Guidance is 10× the number of CPU cores.

## Testing the Chart

```bash
# Lint
helm lint . --set serverHostname=test.example.com --set sitename=test-site --set cache.pvc.storageClass=std --set logging.persistence.storageClass=std --set issuerKey.existingSecret=issuer-key --set webPassword.existingSecret=pw

# Render with minimal values
helm template test . --set serverHostname=test.example.com --set sitename=test-site --set cache.pvc.storageClass=std --set logging.persistence.storageClass=std --set issuerKey.existingSecret=issuer-key --set webPassword.existingSecret=pw

# Render with full uw-osdf-cache-equivalent values (hostPath-backed)
helm template test . -f ci/uw-osdf-cache-values.yaml

# Render with Houston (hostPath) or ITB (PVC) values
helm template test . -f ci/houston2-i2-pelican-cache-values.yaml
helm template test . -f ci/itb-osdf-pelican-cache-values.yaml

# Test validation: should fail (first error: cache.pvc.storageClass required since type=pvc is the default)
helm template test .

# Test validation: should fail with "cache.pvc.storageClass must be nonempty..."
helm template test . --set serverHostname=test.local --set sitename=test-site --set cache.type=pvc --set logging.persistence.storageClass=std --set issuerKey.existingSecret=issuer-key --set webPassword.existingSecret=pw

# Test existingClaim path: should succeed without storageClass
helm template test . -f ci/uw-osdf-cache-values.yaml --set cache.pvc.existingClaim=my-existing-pvc
```

## Storage Configuration (Discriminated Union Pattern)

The `cache` block uses a discriminated union pattern controlled by a `type` field:

### Cache Storage

```yaml
cache:
  type: "pvc" | "hostPath"
  
  # When type: pvc
  pvc:
    existingClaim: ""           # If set, use this existing PVC; ignores storageClass/size
    storageClass: ""            # Required if existingClaim is empty; defines StorageClass for new PVC
    size: 1000Gi                # PVC size (used only when creating a new PVC)
  
  # When type: hostPath
  hostPath:
    path: ""                    # Required; node path to mount
```

### Issuer Key Storage

```yaml
issuerKey:
  existingSecret: ""           # Required; Secret name containing the issuer key
  secretKey: private-key.pem   # Key within the Secret
```

## Validation Requirements

The chart enforces these rules at render time:

| Condition | Requirement |
|-----------|-------------|
| `cache.type == "pvc"` AND `cache.pvc.existingClaim` is empty | `cache.pvc.storageClass` must be nonempty |
| `cache.type == "hostPath"` | `cache.hostPath.path` must be nonempty |
| Always | `issuerKey.existingSecret` must be nonempty |
| `logging.persistence.separateVolume == true` AND `logging.persistence.existingClaim` is empty | `logging.persistence.storageClass` must be nonempty |
| `lotman.enabled == true` AND `lotman.pvc.existingClaim` is empty | `lotman.pvc.storageClass` must be nonempty |
| `oidc.enabled == true` | `oidc.existingSecret` must be nonempty |
| Always | `sitename` must be nonempty |
| Always | `webPassword.existingSecret` must be nonempty |
| Always | `serverHostname` must be nonempty |
| Federation consistency | If `federation.discoveryUrl` or `federation.label` match OSDF or OSDF-ITB, both must pair correctly |
| TLS consistency | `tls.certManager.enabled` and `tls.existingSecret` cannot both be set |
| TLS completeness | When `tls.certManager.enabled` is false, `tls.existingSecret` must be nonempty |

## Common Modification Patterns

### Adding a new Pelican config knob

1. Add the value to `values.yaml` with a sensible default (usually empty string to mean "omit").
2. Add a conditional block in the `pelican-cache.instanceConfig` template in `_helpers.tpl`.
3. Test with `helm template`.

### Adding a new optional sidecar container

1. Add an `enabled` toggle in `values.yaml`.
2. Add a `{{- if .Values.newSidecar.enabled }}` block in `deployment.yaml` in the `containers` list.
3. Add any associated volumes, PVCs, or ConfigMaps with the same conditional guard.
4. Update validation rules if the sidecar requires resources or Secrets.

### Adding support for existing resources (PVC, Secret, etc.)

Follow the discriminated union pattern:

1. In `values.yaml`, restructure the relevant block to nest under a key matching the `type` discriminator (e.g., `pvc.*` for PVC config, `secret.*` for Secret config).
2. Add an `existingClaim` or `existingSecret` field to reference pre-existing resources.
3. In templates, conditionally skip resource creation if the existing field is set (e.g., skip PVC if `existingClaim` is populated).
4. In deployment volumes, resolve the claim/secret name correctly based on the discriminator.
5. Add validation rules in `_helpers.tpl` `validateRequiredValues` helper to enforce that required fields are set for each branch.

## Upstream Resources

- Pelican documentation: https://docs.pelicanplatform.org/
- Pelican GitHub: https://github.com/PelicanPlatform/pelican
- OSDF: https://osg-htc.org/services/osdf.html
- tiger-osg-config (reference Kustomize deployment): https://github.com/opensciencegrid/tiger-osg-config
- XRootD PFC configuration: https://xrootd.web.cern.ch/doc/dev56/pss_config.pdf
