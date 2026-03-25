{{/*
Expand the name of the chart.
*/}}
{{- define "pelican-cache.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this.
*/}}
{{- define "pelican-cache.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pelican-cache.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pelican-cache.labels" -}}
helm.sh/chart: {{ include "pelican-cache.chart" . }}
{{ include "pelican-cache.selectorLabels" . }}
{{- if .Values.federation.label }}
federation: {{ .Values.federation.label }}
{{- end }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pelican-cache.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pelican-cache.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
TLS Secret name - either from cert-manager Certificate or an existing Secret
*/}}
{{- define "pelican-cache.tlsSecretName" -}}
{{- if .Values.tls.existingSecret }}
{{- .Values.tls.existingSecret }}
{{- else }}
{{- include "pelican-cache.fullname" . }}-tls
{{- end }}
{{- end }}

{{/*
Generate the Pelican instance configuration (50-instance.yaml content).
This is the user-configurable layer that Pelican loads from /etc/pelican/config.d/.
*/}}
{{- define "pelican-cache.instanceConfig" -}}
{{- include "pelican-cache.validateFederation" . }}
---
Federation:
  DiscoveryUrl: {{ .Values.federation.discoveryUrl | quote }}

Server:
  Hostname: {{ required "serverHostname is required" .Values.serverHostname | quote }}
{{- if .Values.adminUsers }}
  UIAdminUsers:
    {{- toYaml .Values.adminUsers | nindent 4 }}
{{- end }}
{{- if .Values.webPasswordSecret }}
  UIPasswordFile: /etc/pelican/server-web-passwd
{{- end }}

{{- if .Values.cache.blocksToPrefetch }}
Cache.BlocksToPrefetch: {{ .Values.cache.blocksToPrefetch }}
{{- end }}
{{- if .Values.oidc.enabled }}
Cache.EnableOIDC: true
{{- end }}
{{- if .Values.lotman.enabled }}
Cache.EnableLotman: true
{{- end }}
{{- if .Values.cache.highWaterMark }}
Cache.HighWaterMark: {{ .Values.cache.highWaterMark }}
{{- end }}
{{- if .Values.cache.lowWaterMark }}
Cache.LowWaterMark: {{ .Values.cache.lowWaterMark }}
{{- end }}
{{- if .Values.cache.filesMaxSize }}
Cache.FilesMaxSize: {{ .Values.cache.filesMaxSize }}
{{- end }}
{{- if .Values.cache.filesNominalSize }}
Cache.FilesNominalSize: {{ .Values.cache.filesNominalSize }}
{{- end }}
{{- if .Values.cache.filesBaseSize }}
Cache.FilesBaseSize: {{ .Values.cache.filesBaseSize }}
{{- end }}
{{- if .Values.cache.concurrency }}
Cache.Concurrency: {{ .Values.cache.concurrency }}
{{- end }}

{{- if .Values.oidc.enabled }}

OIDC:
  ClientIDFile: /etc/pelican/oidc/client.id
  ClientSecretFile: /etc/pelican/oidc/client.secret
{{- end }}

Logging:
  Level: {{ .Values.logging.level | quote }}
{{- if .Values.logging.cache }}
  Cache:
{{ toYaml .Values.logging.cache | indent 4 }}
{{- end }}

{{- if .Values.lotman.enabled }}

Lotman:
  LotHome: /var/lib/pelican/lotman
{{- end }}

XrootD.Sitename: {{ required "sitename is required" .Values.sitename | quote }}
{{- if .Values.xrootd.extraConfig }}
XrootD.ConfigFile: /etc/pelican/xrootd.conf
{{- end }}

{{- if .Values.extraPelicanConfig }}

{{ toYaml .Values.extraPelicanConfig }}
{{- end }}
{{- end }}

{{/*
Return true when a PVC should be rendered by this chart.

Behavior:
- If the PVC does not exist yet, render it.
- If the PVC already exists and is managed by this same Helm release, render it
  so upgrades can continue to manage metadata.
- Otherwise, skip rendering to avoid creation/adoption conflicts.
*/}}
{{- define "pelican-cache.shouldRenderPvc" -}}
{{- $root := .root -}}
{{- $pvcName := .pvcName -}}
{{- $existing := lookup "v1" "PersistentVolumeClaim" $root.Release.Namespace $pvcName -}}
{{- if not $existing -}}
true
{{- else -}}
{{- $annotations := default (dict) $existing.metadata.annotations -}}
{{- $labels := default (dict) $existing.metadata.labels -}}
{{- if and
  (eq (index $annotations "meta.helm.sh/release-name") $root.Release.Name)
  (eq (index $annotations "meta.helm.sh/release-namespace") $root.Release.Namespace)
  (eq (index $labels "app.kubernetes.io/managed-by") "Helm") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate that federation.discoveryUrl and federation.label are consistent.
The two known federations each require a specific pairing:
  - https://osg-htc.org           <-> osdf
  - https://osdf-itb.osg-htc.org  <-> osdf-itb
If either value in a pair is set to one of the known values, the other must
match exactly.
*/}}
{{- define "pelican-cache.validateFederation" -}}
{{- $url   := .Values.federation.discoveryUrl | default "" }}
{{- $label := .Values.federation.label        | default "" }}

{{- /* url → required label */}}
{{- if eq $url "https://osg-htc.org" }}
  {{- if and $label (ne $label "osdf") }}
    {{- fail (printf "federation.discoveryUrl is %q but federation.label is %q — it must be \"osdf\"" $url $label) }}
  {{- end }}
{{- end }}

{{- if eq $url "https://osdf-itb.osg-htc.org" }}
  {{- if and $label (ne $label "osdf-itb") }}
    {{- fail (printf "federation.discoveryUrl is %q but federation.label is %q — it must be \"osdf-itb\"" $url $label) }}
  {{- end }}
{{- end }}

{{- /* label → required url */}}
{{- if eq $label "osdf" }}
  {{- if and $url (ne $url "https://osg-htc.org") }}
    {{- fail (printf "federation.label is %q but federation.discoveryUrl is %q — it must be \"https://osg-htc.org\"" $label $url) }}
  {{- end }}
{{- end }}

{{- if eq $label "osdf-itb" }}
  {{- if and $url (ne $url "https://osdf-itb.osg-htc.org") }}
    {{- fail (printf "federation.label is %q but federation.discoveryUrl is %q — it must be \"https://osdf-itb.osg-htc.org\"" $label $url) }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Validate required values and conditional requirements.
*/}}
{{- define "pelican-cache.validateRequiredValues" -}}
{{- $cacheStorageType := .Values.cache.type | default "" }}
{{- $issuerKeyType := .Values.issuerKey.type | default "" }}
{{- $loggingPersist := .Values.logging.persistence.separateVolume }}

{{- if eq $cacheStorageType "pvc" }}
  {{- if not .Values.cache.pvc.existingClaim }}
    {{- if eq (trim (default "" .Values.cache.pvc.storageClass)) "" }}
      {{- fail "cache.pvc.storageClass must be nonempty when cache.type is \"pvc\" and cache.pvc.existingClaim is not set" }}
    {{- end }}
  {{- end }}
{{- end }}

{{- if eq $cacheStorageType "hostPath" }}
  {{- if eq (trim (default "" .Values.cache.hostPath.path)) "" }}
    {{- fail "cache.hostPath.path must be nonempty when cache.type is \"hostPath\"" }}
  {{- end }}
{{- end }}

{{- if eq $issuerKeyType "pvc" }}
  {{- if eq (trim (default "" .Values.issuerKey.pvc.storageClass)) "" }}
    {{- fail "issuerKey.pvc.storageClass must be nonempty when issuerKey.type is \"pvc\"" }}
  {{- end }}
{{- end }}

{{- if eq $issuerKeyType "existingSecret" }}
  {{- if eq (trim (default "" .Values.issuerKey.existingSecret)) "" }}
    {{- fail "issuerKey.existingSecret must be nonempty when issuerKey.type is \"existingSecret\"" }}
  {{- end }}
{{- end }}

{{- if eq (trim (default "" .Values.sitename)) "" }}
  {{- fail "sitename must be nonempty" }}
{{- end }}

{{- if $loggingPersist }}
  {{- if not .Values.logging.persistence.existingClaim }}
    {{- if eq (trim (default "" .Values.logging.persistence.storageClass)) "" }}
      {{- fail "logging.persistence.storageClass must be nonempty when logging.persistence.separateVolume is true and logging.persistence.existingClaim is not set" }}
    {{- end }}
  {{- end }}
{{- end }}

{{- if .Values.lotman.enabled }}
  {{- if not .Values.lotman.pvc.existingClaim }}
    {{- if eq (trim (default "" .Values.lotman.pvc.storageClass)) "" }}
      {{- fail "lotman.pvc.storageClass must be nonempty when lotman.enabled is true and lotman.pvc.existingClaim is not set" }}
    {{- end }}
  {{- end }}
{{- end }}

{{- if .Values.oidc.enabled }}
  {{- if eq (trim (default "" .Values.oidc.existingSecret)) "" }}
    {{- fail "oidc.existingSecret must be nonempty when oidc.enabled is true" }}
  {{- end }}
{{- end }}

{{- if eq (trim (default "" .Values.webPasswordSecret)) "" }}
  {{- fail "webPasswordSecret must be nonempty" }}
{{- end }}
{{- end }}

