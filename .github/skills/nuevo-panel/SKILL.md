---
name: nuevo-panel
description: Añadir o actualizar un panel (dashboard) de Grafana en este repo, ya sea general (para varios clientes, en master/general/) o propio de un cliente (tenants/<cliente>/custom/). Úsala cuando el usuario quiera meter un JSON exportado de Grafana, crear un panel nuevo o mover uno.
---

# Añadir un panel

## 1. Decidir dónde va

| Si el panel es... | Va en | Quién lo recibe |
|---|---|---|
| para varios clientes | `master/general/<carpeta>/<nombre>.json` | los clientes con esa carpeta en `general` de `master/config.yaml` |
| solo de un cliente | `tenants/<cliente>/custom/<subcarpetas>/<nombre>.json` | solo ese cliente |

Nunca escribas en `tenants/*/general/`: lo genera `scripts/render.sh` y la PR fallaría.

## 2. Convertir el JSON

Si viene de un export de Grafana, conviértelo siempre (cambia los datasources por `${ds_mimir}` / `${ds_loki}`, añade las variables con regex, quita `id` y `__inputs`, y fija el uid):

```bash
scripts/convert-dashboard.sh <export.json> <uid> <destino.json>
```

Elegir el `uid`:
- Único dentro de cada cliente que lo vaya a recibir (general + custom). Comprueba con `grep -r '"uid": "<uid>"' master tenants`.
- Máximo 40 caracteres: letras, números, `-` y `_`. Nunca `general`.
- Convención: `gen-<tema>` para generales y `<cliente>-<tema>` para custom.

Si `convert-dashboard.sh` avisa de datasources con UID fijo de otros tipos, pregunta al usuario si añadir una variable para ese tipo (mismo patrón: `type: datasource`, `query: <tipo>`, `regex: /^<Prefijo>/`, `hide: 2`).

## 3. Carpeta nueva en master

Si creas una carpeta nueva en `master/general/`, añade su `_folder.json` con el título visible (el UID lo reescribe render.sh):

```json
{"apiVersion":"folder.grafana.app/v1beta1","kind":"Folder","metadata":{"name":"titulo"},"spec":{"title":"<Título bonito>"}}
```

Y, si toca, añade la carpeta a los clientes en `master/config.yaml` (ver la skill `nuevo-cliente`).

## 4. Validar

```bash
scripts/render.sh --check
```

Requiere `yq` v4 (mikefarah) en el PATH. Si no está, descárgalo en un directorio temporal: `https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64`.

Errores típicos: `datasource con UID fijo` (falta convertir), `uid repetido` (cambia el uid), `variables sin definir` (falta el bloque templating).

## 5. Commit

Un commit en español que diga qué panel y para quién. Al hacer push a `main`, la Action `render-tenants` reparte el panel y Git Sync lo carga en cada org en ~1 minuto. No hagas push sin que el usuario lo pida.
