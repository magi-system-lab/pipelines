{{- define "sb.name" -}}
{{ .Values.app }}
{{- end -}}

{{- define "sb.labels" -}}
app.kubernetes.io/name: {{ .Values.app }}
app.kubernetes.io/managed-by: pipelines
{{- end -}}
