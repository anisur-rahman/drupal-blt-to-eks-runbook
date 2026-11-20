{{/* Image reference: an immutable digest when set (required for real deployments), otherwise a tag. */}}
{{- define "drupal.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else if .Values.image.tag -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- else -}}
{{ fail "Set image.digest (or image.tag for local test clusters)" }}
{{- end -}}
{{- end -}}

{{/* Shared environment for the web pods and the cron jobs. */}}
{{- define "drupal.env" -}}
- name: APP_ENV
  value: prod
- name: DB_HOST
  value: {{ .Values.database.host | quote }}
- name: DB_USER
  value: {{ .Values.database.user | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: password
{{- range .Values.sites }}
- name: {{ .id | upper }}_DB_NAME
  value: {{ .dbName | quote }}
- name: {{ .id | upper }}_TRUSTED_HOSTS
  value: {{ printf "^%s$" (.host | replace "." "\\.") | quote }}
{{- end }}
{{- end -}}
