---
applyTo: "master/general/**/*.json,tenants/**/*.json"
---

# Paneles (dashboards JSON)

- Paneles de `master/general/`:
  - Ningún `datasource.uid` fijo. Solo `${ds_mimir}`, `${ds_loki}` u otra variable definida en `templating.list`, o los internos `grafana`, `-- Grafana --`, `-- Mixed --` y `-- Dashboard --`.
  - Deben incluir las variables `ds_mimir` (`type: datasource`, `query: prometheus`, `regex: /^Mimir/`, `hide: 2`) y `ds_loki` (`query: loki`, `regex: /^Loki/`, `hide: 2`).
  - Las consultas no filtran por un cliente concreto: el aislamiento lo da la cabecera `X-Scope-OrgID` de cada datasource.
- Todos los paneles: `uid` y `title` obligatorios; `uid` único dentro de cada cliente (general + custom), máximo 40 caracteres de `[A-Za-z0-9_-]` y distinto de `general`.
- Ficheros en `tenants/*/general/`: generados por `scripts/render.sh`. Una PR que los modifique es un error; el cambio va en `master/`.
- Para convertir un export de Grafana: `scripts/convert-dashboard.sh <export.json> <uid> <destino.json>`.
- `_folder.json`: `{"apiVersion":"folder.grafana.app/v1beta1","kind":"Folder","metadata":{"name":"<uid>"},"spec":{"title":"<título>"}}`. En `master/` solo cuenta `spec.title`.
