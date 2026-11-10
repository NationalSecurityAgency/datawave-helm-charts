{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "accumulo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
This is truncated to 63 chars to conform with the DNS naming spec.
If release name contains chart name it will be used as a full name.
*/}}
{{- define "accumulo.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "accumulo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "accumulo.labels" -}}
helm.sh/chart: {{ include "accumulo.chart" . }}
{{ include "accumulo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.labels }}
{{ toYaml .Values.labels }}
{{- end -}}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "accumulo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "accumulo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "accumulo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "accumulo.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{- define "accumulo.zookeepers" -}}
    {{- required ".Values.zookeeper.enabled = false, so .Values.zookeeper.externalHosts must be set" .Values.zookeeper.externalHosts }}
{{- end -}}

{{- define "accumulo.callSubChartTemplate" }}
{{- $dot := index . 0 }}
{{- $subchart := index . 1 | splitList "." }}
{{- $template := index . 2 }}
{{- $values := $dot.Values }}
{{- range $subchart }}
{{- $values = index $values . }}
{{- end }}
{{- include $template (dict "Chart" (dict "Name" (last $subchart)) "Values" $values "Release" $dot.Release "Capabilities" $dot.Capabilities) }}
{{- end }}

{{- define "accumulo.hdfsNamenodeHostname" -}}
    {{ required ".Values.hdfs.namenode.hostname needs to be set as .Values.hdfs.enabled = false" .Values.hdfs.namenode.hostname }}
  :{{ .Values.hdfs.namenode.ports.clientRpc }}
{{- end -}}

{{- define "accumulo.volumeMount" -}}
- mountPath: {{ .destination }}
  name: {{ .name }}
  {{- if .readOnly }}
  readOnly: true
  {{- end }}
{{- end }}

{{- define "accumulo.volume" -}}
- name: {{ .name }}
  {{- if eq .source.type "hostPath" }}
  hostPath:
    path: {{ .source.path }}
    type: Directory
  {{- else if eq .source.type "configmap" }}
  configMap:
    name: {{ .source.name }}
  {{- end }}
{{- end }}

{{/*
Renders a complete accumulo.properties file for a single server role.
As well as the common config.accumuloSite map merged with that role's own accumuloSite overrides
Usage: {{ include "accumulo.accumuloProperties" (dict "ctx" $ "overrides" $.Values.manager.accumuloSite) }}
*/}}
{{- define "accumulo.accumuloProperties" -}}
{{- $ := .ctx }}
## Sets location in HDFS where Accumulo will store data
instance.volumes=hdfs://{{ $.Values.global.hdfs.namenode }}/accumulo

## Sets location of Zookeepers
instance.zookeeper.host={{ $.Values.global.accumulo.zookeepers }}

## Add additional global values here
{{- range $k, $v := merge (dict) .overrides $.Values.config.accumuloSite }}
{{ $k }}={{ $v }}
{{- end }}

#enable external compactions
{{- range $.Values.compactors.resourceGroups }}
compaction.service.{{ .serviceName }}.planner={{ .plannerClass }}
compaction.service.{{ .serviceName }}.planner.opts.executors={{ .jsonConfig }}
{{- end }}
{{- end -}}

{{/*
Projected volume combining the common accumulo ConfigMap with a role-specific
accumulo ConfigMap, both mounted at the same ACCUMULO_CONF_DIR.
Usage: {{ include "accumulo.accumuloConfVolume" (list $ "accumulo-config-tserver") }}
*/}}
{{- define "accumulo.accumuloConfVolume" -}}
{{- $dot := index . 0 }}
{{- $roleConfigMapName := index . 1 }}
- name: {{ $dot.Values.global.volumes.accumulo.name }}
  projected:
    sources:
    - configMap:
        name: {{ $dot.Values.global.volumes.accumulo.source.name }}
    - configMap:
        name: {{ $roleConfigMapName }}
{{- end -}}
