{{/* Chart name, truncated to 63 chars. */}}
{{- define "frappe-devbox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name. */}}
{{- define "frappe-devbox.fullname" -}}
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

{{- define "frappe-devbox.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "frappe-devbox.labels" -}}
helm.sh/chart: {{ include "frappe-devbox.chart" . }}
{{ include "frappe-devbox.selectorLabels" . }}
app.kubernetes.io/version: {{ include "frappe-devbox.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "frappe-devbox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "frappe-devbox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "frappe-devbox.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{- define "frappe-devbox.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "frappe-devbox.imageTag" .) }}
{{- end }}

{{- define "frappe-devbox.secretName" -}}
{{- default (include "frappe-devbox.fullname" .) .Values.auth.existingSecret }}
{{- end }}

{{- define "frappe-devbox.claimName" -}}
{{- default (printf "%s-data" (include "frappe-devbox.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{- define "frappe-devbox.codeServerAuthOn" -}}
{{- if and .Values.codeServer.enabled (eq .Values.codeServer.auth "password") }}true{{ end }}
{{- end }}

{{/* Fail early on combinations the entrypoint would reject at runtime. */}}
{{- define "frappe-devbox.validate" -}}
{{- if and (not .Values.mariadb.local) (not .Values.externalDatabase.host) }}
{{- fail "mariadb.local=false requires externalDatabase.host" }}
{{- end }}
{{- if and (not .Values.redis.local) (not .Values.externalRedis.url) }}
{{- fail "redis.local=false requires externalRedis.url" }}
{{- end }}
{{- if not (has .Values.codeServer.auth (list "password" "none")) }}
{{- fail "codeServer.auth must be \"password\" or \"none\"" }}
{{- end }}
{{- if and .Values.codeServer.ingress.enabled (not .Values.codeServer.ingress.host) }}
{{- fail "codeServer.ingress.enabled requires codeServer.ingress.host" }}
{{- end }}
{{- if and .Values.codeServer.ingress.enabled (ne .Values.codeServer.auth "password") }}
{{- fail "refusing to expose code-server through the Ingress with codeServer.auth=none" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.host) }}
{{- fail "ingress.enabled requires ingress.host" }}
{{- end }}
{{- end }}

{{/* Shared by the bootstrap init container and the main container. */}}
{{- define "frappe-devbox.containerCommon" -}}
image: {{ include "frappe-devbox.image" . }}
imagePullPolicy: {{ .Values.image.pullPolicy }}
securityContext:
  {{- toYaml .Values.containerSecurityContext | nindent 2 }}
envFrom:
  - configMapRef:
      name: {{ include "frappe-devbox.fullname" . }}
  - secretRef:
      name: {{ include "frappe-devbox.secretName" . }}
{{- with .Values.extraEnv }}
env:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumeMounts:
  - name: data
    mountPath: /data
  - name: tmp
    mountPath: /tmp
  - name: home
    mountPath: /home/frappe
{{- end }}
