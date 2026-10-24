{{/* Nombre base de los recursos */}}
{{- define "gitsync.name" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "gitsync.labels" -}}
app.kubernetes.io/name: grafana-gitsync
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Contenedor común. Recibe un dict con root (.) y env extra (lista). */}}
{{- define "gitsync.container" -}}
{{- $root := .root -}}
- name: gitsync
  image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
  imagePullPolicy: {{ $root.Values.image.pullPolicy }}
  command: ["/bin/sh", "-c"]
  args:
    - {{ if $root.Values.image.installTools }}apk add --no-cache -q curl jq && {{ end }}sh /work/gitsync-sync.sh
  env:
    - { name: GRAFANA_URL, value: {{ $root.Values.grafana.url | quote }} }
    - name: GRAFANA_USER
      valueFrom: { secretKeyRef: { name: {{ $root.Values.grafana.existingSecret }}, key: {{ $root.Values.grafana.userKey }} } }
    - name: GRAFANA_PASSWORD
      valueFrom: { secretKeyRef: { name: {{ $root.Values.grafana.existingSecret }}, key: {{ $root.Values.grafana.passwordKey }} } }
    - name: GITHUB_TOKEN
      valueFrom: { secretKeyRef: { name: {{ $root.Values.grafana.existingSecret }}, key: {{ $root.Values.grafana.githubTokenKey }} } }
    - { name: SYNC_TARGET, value: {{ $root.Values.gitSync.target | quote }} }
    - { name: SYNC_INTERVAL, value: {{ $root.Values.gitSync.intervalSeconds | quote }} }
    - { name: WORKFLOWS, value: {{ $root.Values.gitSync.workflows | toJson | quote }} }
    - { name: WAIT_SECONDS, value: {{ $root.Values.job.waitSeconds | quote }} }
    - { name: DRY_RUN, value: {{ $root.Values.job.dryRun | quote }} }
    {{- range .env }}
    - {{ toJson . }}
    {{- end }}
  volumeMounts:
    - { name: work, mountPath: /work, readOnly: true }
  resources:
    {{- toYaml $root.Values.job.resources | nindent 4 }}
{{- end -}}

{{- define "gitsync.volumes" -}}
- name: work
  configMap: { name: {{ include "gitsync.name" . }} }
{{- end -}}
