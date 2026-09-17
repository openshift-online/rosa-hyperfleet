{{/* Expand the name of the chart. */}}
{{- define "ecr-creds-sync.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Create a default fully qualified app name. */}}
{{- define "ecr-creds-sync.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/* Create the chart label. */}}
{{- define "ecr-creds-sync.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels. */}}
{{- define "ecr-creds-sync.labels" -}}
helm.sh/chart: {{ include "ecr-creds-sync.chart" . }}
{{ include "ecr-creds-sync.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels. */}}
{{- define "ecr-creds-sync.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ecr-creds-sync.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ServiceAccount name. */}}
{{- define "ecr-creds-sync.serviceAccountName" -}}
{{ .Values.ecrCredsSync.serviceAccount.name }}
{{- end }}
