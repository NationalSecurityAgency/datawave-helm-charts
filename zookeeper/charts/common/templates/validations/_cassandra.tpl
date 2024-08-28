{{/* vim: set filetype=mustache: */}}
{{/*
Validate Cassandra required passwords are not empty.

Usage:
{{ include "common.validations.Values.cassandra.passwords" (dict "secret" "secretName" "subchart" false "context" $) }}
Params:
  - secret - String - Required. Name of the secret where Cassandra values are stored, e.g: "cassandra-passwords-secret"
  - subchart - Boolean - Optional. Whether Cassandra is used as subchart or not. Default: false
*/}}
{{- define "common.validations.Values.cassandra.passwords" -}}
  {{- $existingSecret := include "common.cassandra.Values.existingSecret" . -}}
  {{- $enabled := include "common.cassandra.Values.enabled" . -}}
  {{- $dbUserPrefix := include "common.cassandra.Values.key.dbUser" . -}}
  {{- $valueKeyPassword := printf "%s.password" $dbUserPrefix -}}

  {{- if and (or (not $existingSecret) (eq $existingSecret "\"\"")) (eq $enabled "true") -}}
    {{- $requiredPasswords := list -}}

    {{- $requiredPassword := dict "valueKey" $valueKeyPassword "secret" .secret "field" "cassandra-password" -}}
    {{- $requiredPasswords = append $requiredPasswords $requiredPassword -}}

    {{- include "common.validations.Values.multiple.empty" (dict "required" $requiredPasswords "context" .context) -}}

  {{- end -}}
{{- end -}}

{{/*
Auxiliary function to get the right value for existingSecret.

Usage:
{{ include "common.cassandra.Values.existingSecret" (dict "context" $) }}
Params:
  - subchart - Boolean - Optional. Whether Cassandra is used as subchart or not. Default: false
*/}}
{{- define "common.cassandra.Values.existingSecret" -}}
  {{- if .subchart -}}
    {{- .context.Values.cassandra.dbUser.existingSecret | quote -}}
  {{- else -}}
    {{- .context.Values.dbUser.existingSecret | quote -}}
  {{- end -}}
{{- end -}}

{{/*
Auxiliary function to get the right value for enabled cassandra.

Usage:
{{ include "common.cassandra.Values.enabled" (dict "context" $) }}
*/}}
{{- define "common.cassandra.Values.enabled" -}}
  {{- if .subchart -}}
    {{- printf "%v" .context.Values.cassandra.enabled -}}
  {{- else -}}
    {{- printf "%v" (not .context.Values.enabled) -}}
  {{- end -}}
{{- end -}}

{{/*
Auxiliary function to get the right value for the key dbUser

Usage:
{{ include "common.cassandra.Values.key.dbUser" (dict "subchart" "true" "context" $) }}
Params:
  - subchart - Boolean - Optional. Whether Cassandra is used as subchart or not. Default: false
*/}}
{{- define "common.cassandra.Values.key.dbUser" -}}
  {{- if .subchart -}}
    cassandra.dbUser
  {{- else -}}
    dbUser
  {{- end -}}
{{- end -}}
