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

Si creas una carpeta nueva, define su título visible en Grafana (escribe su `_folder.json`; en `master/` el UID lo reasigna render.sh y en `custom/` se deriva de la ruta):

```bash
scripts/folder-title.sh <carpeta> "<Título>"
```

Y, si toca, añade la carpeta a los clientes en `master/config.yaml` (ver la skill `nuevo-cliente`).

## 4. Validar

```bash
scripts/render.sh --check
dev/check-queries.sh <destino.json> <org>     # si el entorno dev/ está levantado: cada consulta debe dar OK
```

`render.sh` requiere `yq` v4 (mikefarah) en el PATH; cómo instalarlo, en la skill `probar-en-local`.

Errores típicos: `datasource con UID fijo` (falta convertir), `uid repetido` (cambia el uid), `variables sin definir` (falta el bloque templating). Si el panel es nuevo y debe mostrar datos realistas, sigue la skill `panel-con-datos`.

## 5. Publicar

Solo si el usuario lo pide, y siempre con la skill `publicar-cambios`: el repo es público. Al hacer push a `main`, la Action `render-tenants` reparte el panel y Git Sync lo carga en cada org en ~1 minuto.
