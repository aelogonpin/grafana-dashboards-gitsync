#!/usr/bin/env bash
# Define el título con el que se muestra una carpeta en Grafana (escribe su _folder.json).
#
# Uso: scripts/folder-title.sh <carpeta> "<título>"
# Ej.: scripts/folder-title.sh master/general/poc "Prueba de concepto"
#      scripts/folder-title.sh tenants/cliente-a/custom/negocio "Negocio"
#
# Es opcional: sin él, la carpeta se muestra con el nombre del directorio.
# En master/general/ solo cuenta el título (render.sh asigna el UID). En custom/ el UID
# se deriva de la ruta y no debe cambiar después, porque Grafana identifica la carpeta por él.
set -euo pipefail

[[ $# -eq 2 ]] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
title="$2"
[[ -n "$title" ]] || { echo "El título no puede estar vacío" >&2; exit 1; }
# Admite rutas relativas al directorio actual (p. ej. ../master/general/x desde scripts/) o absolutas.
abs="$(realpath -m "$1")"
[[ "$abs" == "$ROOT"/* ]] || { echo "La carpeta debe estar dentro del repo ($ROOT)" >&2; exit 1; }
dir="${abs#"$ROOT"/}"

case "$dir" in
  master/general/*) prefix=gen;    rel="${dir#master/general/}" ;;
  tenants/*/custom) prefix=custom; rel="" ;;
  tenants/*/custom/*) prefix=custom; rel="${dir#tenants/*/custom/}" ;;
  *) echo "La carpeta debe estar en master/general/... o en tenants/<cliente>/custom/..." >&2; exit 1 ;;
esac

uid="$prefix${rel:+-$(echo "$rel" | tr '/' '-' | tr -c 'a-zA-Z0-9_\n-' '-' | tr '[:upper:]' '[:lower:]')}"
[[ ${#uid} -le 40 ]] || uid="$prefix-$(echo -n "$rel" | md5sum | cut -c1-20)"

mkdir -p "$ROOT/$dir"
jq -n --arg uid "$uid" --arg title "$title" \
  '{apiVersion: "folder.grafana.app/v1beta1", kind: "Folder", metadata: {name: $uid}, spec: {title: $title}}' \
  > "$ROOT/$dir/_folder.json"
echo "Título de $dir: \"$title\""
