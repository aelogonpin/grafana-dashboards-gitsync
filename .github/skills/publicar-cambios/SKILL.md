---
name: publicar-cambios
description: Lista de comprobación para hacer commit y push en este repo público y verificar que el cambio llega a Grafana (GitHub Action en verde y Git Sync sincronizado). Úsala SIEMPRE antes de cualquier commit o push en este repo, aunque el cambio parezca pequeño.
---

# Publicar un cambio

El repo es **público**. Un dato de producción subido queda en el historial, en las PRs y en los logs de las Actions; para limpiarlo hubo que **borrar y recrear el repo**. No se repite.

## 1. Antes del commit

```bash
scripts/render.sh --check                                    # debe acabar en OK
git status --short                                           # revisa cada fichero
git diff --cached                                            # tras el git add
```

Revisa que **no** haya:

| Qué | Cómo buscarlo |
|---|---|
| Tokens y contraseñas | `grep -rIE "github_pat_[A-Za-z0-9]{20,}\|ghp_[A-Za-z0-9]{20,}" --exclude-dir=.git .` |
| Nombres reales de clientes, productos o proyectos | solo valen `cliente-a/b/c…` y temas genéricos (`kubernetes`, `aplicacion`, `alertas`, `tienda`). Si el usuario te ha dado nombres reales en la conversación, búscalos con grep |
| Infraestructura de producción | namespaces, hostnames, dominios, sub-paths, nombres de clústeres, repos internos, proveedores de nube, herramientas internas o número real de orgs |
| `dev/.env` o cualquier `.env` | `git check-ignore dev/.env` debe devolver la ruta |

Si dudas de si algo es de producción, **pregunta antes de subirlo**.

## 2. Commit y push (solo si el usuario lo ha pedido)

- Mensaje en español: una línea de resumen y, si hace falta, un párrafo o una lista corta de qué cambia.
- Termina con las líneas de atribución que indique el sistema.
- `git push`. Si lo rechaza con `fetch first`, el bot de la Action ha hecho un commit: `git pull --rebase` y repite.

## 3. Después del push

```bash
gh run watch $(gh run list -L1 --json databaseId -q '.[0].databaseId') --exit-status
git pull                          # trae el commit del bot si lo hubo
```

- Action en rojo: `gh run view --log-failed`, corrige y vuelve al paso 1.
- Si hay entorno de pruebas levantado: en ≤ 60 s `dev/status.sh` debe mostrar el cambio con `sync=success`. Si no, forzar un pull completo (skill `probar-en-local`).
- Si el cambio toca un panel con datos: `dev/check-queries.sh <panel.json> <org>`.

## 4. Si se ha subido algo que no debía

1. Para y avisa al usuario de inmediato, diciendo qué y dónde.
2. Quitarlo de la versión actual no basta: sigue en el historial, en las PRs y en los logs.
3. La limpieza completa es borrar el repo y recrearlo con un commit limpio. Es irreversible y lo decide el usuario. Tras recrearlo, el token de Git Sync pierde el acceso y hay que volver a dárselo.
