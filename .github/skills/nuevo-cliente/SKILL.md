---
name: nuevo-cliente
description: Dar de alta, modificar o quitar un cliente (tenant) en master/config.yaml, elegir qué carpetas generales recibe (general/exclude) y activar su conexión de Git Sync. Úsala cuando el usuario hable de clientes, orgs, tenants, qué paneles ve cada cliente o de conectar un cliente nuevo.
---

# Gestionar clientes

Todo se decide en `master/config.yaml`; nada más se toca a mano.

```yaml
tenants:
  <cliente>:                 # minúsculas, números y guiones; será la ruta tenants/<cliente>
    orgId: <n>               # ID de su org en Grafana; único
    gitSync: false           # true = el Job crea su conexión de Git Sync
    general:                 # rutas relativas a master/general/ (carpeta entera o fichero)
      - kubernetes
    exclude:                 # opcional: rutas que se quitan de lo seleccionado
      - aplicacion/licencias
```

## Alta de un cliente

1. Confirma con el usuario el `orgId` real de la org en Grafana. La org y sus datasources deben existir antes, con nombres que empiecen por `Mimir` y `Loki` (las variables de los paneles los buscan con `/^Mimir/` y `/^Loki/`).
2. Añade el bloque con `gitSync: false` y valida: `scripts/render.sh --check`.
3. Cuando el usuario quiera conectarlo, pasa a `gitSync: true`. Al sincronizar ArgoCD, el chart `deploy/chart/grafana-gitsync` crea el Job `gitsync-<cliente>`, que crea el `Repository` `gitsync-<cliente>` en el namespace `default` (org 1) u `org-<id>`, con `path: tenants/<cliente>` y `target: folder`.

## Cambiar lo que recibe

- Añadir o quitar rutas en `general`/`exclude`. Lo que deje de estar seleccionado **se borra** de `tenants/<cliente>/general/` y desaparece de su Grafana.
- `exclude` solo tiene sentido dentro de algo seleccionado en `general`.
- Las rutas deben existir en `master/general/` (render.sh falla si no).

## Baja de un cliente

Quitar su bloque: render.sh borra su `general/` y conserva su `custom/`. La conexión de Git Sync en Grafana **no** la borra el Job; avisa al usuario de que la quite desde Grafana (*Administration → Provisioning*) o con `DELETE /apis/provisioning.grafana.app/<versión>/namespaces/<ns>/repositories/gitsync-<cliente>`.

## Reglas

- El repo es público: con datos de prueba, usa nombres genéricos (`cliente-x`). No pongas nombres reales de clientes sin que el usuario lo pida expresamente.
- Valida siempre con `scripts/render.sh --check` antes de proponer el commit.
