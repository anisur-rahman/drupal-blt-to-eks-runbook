{{/* Image reference for "app" or "web": an immutable digest when set, otherwise a tag. */}}
{{- define "drupal.image" -}}
{{- $root := index . 0 -}}{{- $which := index . 1 -}}
{{- $img := index $root.Values.image $which -}}
{{- if $img.digest -}}
{{ $root.Values.image.repository }}@{{ $img.digest }}
{{- else if $img.tag -}}
{{ $root.Values.image.repository }}:{{ $img.tag }}
{{- else -}}
{{ fail (printf "Set image.%s.digest (or image.%s.tag for local test clusters)" $which $which) }}
{{- end -}}
{{- end -}}

{{- define "drupal.envFrom" -}}
- configMapRef: {name: {{ .Release.Name }}-config}
- secretRef: {name: {{ .Values.existingSecret }}}
{{- end -}}

{{/* Files volume mounts. Pass (list $ siteId) for one site, (list $ "") for every site. */}}
{{- define "drupal.fileMounts" -}}
{{- $root := index . 0 -}}{{- $only := index . 1 -}}
{{- range $root.Values.sites }}
{{- if or (eq $only "") (eq $only .id) }}
- name: files
  mountPath: /var/www/html/web/sites/{{ .id }}/files
  subPath: public/{{ .id }}
- name: files
  mountPath: /mnt/private/{{ .id }}
  subPath: private/{{ .id }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "drupal.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  fsGroup: 82   # www-data in the Alpine PHP image: Drupal can write files
  seccompProfile: {type: RuntimeDefault}
{{- end -}}

{{- define "drupal.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities: {drop: [ALL]}
{{- end -}}
