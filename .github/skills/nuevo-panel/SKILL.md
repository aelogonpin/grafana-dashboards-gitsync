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
scripts/convert-dashboard.sh <export.json> <uid> <destino.json> ["<título de la carpeta>"]
```

El 4.º dato es opcional y pone título a la **carpeta** destino, no al panel (el título del panel es el `title` del JSON). Úsalo **solo si la carpeta es nueva**: en una carpeta existente (p. ej. `kubernetes`) renombraría la carpeta para todos los clientes. Los scripts admiten rutas relativas al directorio actual (también `../master/...` desde `scripts/`).

Elegir el `uid`:
- Único dentro de cada cliente que lo vaya a recibir (general + custom). Comprueba con `grep -r '"uid": "<uid>"' master tenants`.
- Máximo 40 caracteres: letras, números, `-` y `_`. Nunca `general`.
- Convención: `gen-<tema>` para generales y `<cliente>-<tema>` para custom.

Si el panel viene de producción, revisa los **valores guardados de sus variables** (`templating.list[].current`): pueden llevar nombres de clúster, nodos o IPs internas. El repo es público: avisa al usuario antes de subirlo y ofrece vaciarlos.

Si `convert-dashboard.sh` avisa de datasources con UID fijo de otros tipos, pregunta al usuario si añadir una variable para ese tipo (mismo patrón: `type: datasource`, `query: <tipo>`, `regex: /^<Prefijo>/`, `hide: 2`).

### Formatos de export

`convert-dashboard.sh` acepta JSON o YAML en cualquiera de estas formas. Pásalo siempre por el script: un export v2 sin convertir falla en `render.sh`.

| Entrada | Cómo reconocerla | Resultado |
|---|---|---|
| Clásico | `uid`, `title`, `panels` | clásico |
| Envuelto | `{"dashboard": {...}}` | según lo que lleve dentro |
| Recurso v1 | `apiVersion: dashboard.grafana.app/v1...` | clásico |
| Recurso v2 | `apiVersion: dashboard.grafana.app/v2...`, `spec.elements` | v2 |
| Spec v2 suelto | `elements` sin `apiVersion` | v2 |

Después de convertir:

- **UID:** conserva el del export (`metadata.name` en v2) salvo que el usuario diga otra cosa. Si ese panel sigue en Grafana sin gestor con el mismo UID, avisa: hay que borrarlo antes de sincronizar.
- **Lee los avisos.** Enlaces a otros UIDs: comprueba que esos paneles existen. Datasources que quedan: en v2, comprueba que `ds_refs` no conserva variables eliminadas.
- **Datasource:** si el original elegía uno concreto y la org tiene varios, `/^Mimir/` puede resolverse a otro. Avisa.
- **Validación extra, si hay un Grafana 13 de pruebas:** `POST /apis/dashboard.grafana.app/v2/namespaces/<ns>/dashboards?dryRun=All` con el JSON. No guarda nada.
- **No hagas commit ni push** salvo que el usuario lo pida: lo que llega a la rama de `repo.branch` lo carga Grafana en un minuto.

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
