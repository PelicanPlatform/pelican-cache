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
app: pelican-cache
{{- if .Values.federation.label }}
federation: {{ .Values.federation.label }}
{{- end }}
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
IssuerKey path based on namespaceKey.type
*/}}
{{- define "pelican-cache.issuerKeyPath" -}}
{{- if eq .Values.namespaceKey.type "existingSecret" -}}
/etc/pelican/issuer-keys/{{ .Values.namespaceKey.secretKey }}
{{- else -}}
/etc/pelican/jwks/issuer.jwk
{{- end -}}
{{- end }}

{{/*
Generate the Pelican instance configuration (50-instance.yaml content).
This is the user-configurable layer that Pelican loads from /etc/pelican/config.d/.
*/}}
{{- define "pelican-cache.instanceConfig" -}}
---
Federation:
  DiscoveryUrl: {{ .Values.federation.discoveryUrl | quote }}

Server:
  Hostname: {{ required "serverHostname is required" .Values.serverHostname | quote }}
{{- if .Values.adminUsers }}
  UIAdminUsers: {{ .Values.adminUsers | quote }}
{{- end }}
{{- if .Values.webPasswordSecret }}
  UIPasswordFile: /etc/pelican/web-passwd/password
{{- end }}

Cache:
{{- if .Values.cache.blocksToPrefetch }}
  BlocksToPrefetch: {{ .Values.cache.blocksToPrefetch }}
{{- end }}
{{- if .Values.oidc.enabled }}
  EnableOIDC: true
{{- end }}
{{- if .Values.lotman.enabled }}
  EnableLotman: true
{{- end }}
{{- if .Values.cache.highWaterMark }}
  HighWaterMark: {{ .Values.cache.highWaterMark }}
{{- end }}
{{- if .Values.cache.lowWaterMark }}
  LowWaterMark: {{ .Values.cache.lowWaterMark }}
{{- end }}
{{- if .Values.cache.filesMaxSize }}
  FilesMaxSize: {{ .Values.cache.filesMaxSize }}
{{- end }}
{{- if .Values.cache.filesNominalSize }}
  FilesNominalSize: {{ .Values.cache.filesNominalSize }}
{{- end }}
{{- if .Values.cache.filesBaseSize }}
  FilesBaseSize: {{ .Values.cache.filesBaseSize }}
{{- end }}
{{- if .Values.cache.concurrency }}
  Concurrency: {{ .Values.cache.concurrency }}
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

{{- if or .Values.xrootd.sitename .Values.xrootd.extraConfig }}

XrootD:
{{- if .Values.xrootd.sitename }}
  Sitename: {{ .Values.xrootd.sitename | quote }}
{{- end }}
{{- if .Values.xrootd.extraConfig }}
  ConfigFile: /etc/pelican/xrootd.conf
{{- end }}
{{- end }}

{{- if .Values.extraPelicanConfig }}

{{ toYaml .Values.extraPelicanConfig }}
{{- end }}
{{- end }}
