## Qué cambia

<!-- Ej.: cliente-b recibe la carpeta aplicacion; panel nuevo gen-cpu en kubernetes -->

## Clientes afectados

| Cliente | Gana | Pierde |
|---|---|---|
|  |  |  |

## Comprobaciones

- [ ] `scripts/render.sh --check` da `OK`
- [ ] No he tocado `tenants/*/general/` ni `deploy/tenants.json` (los genera el bot)
- [ ] Los paneles generales usan `${ds_mimir}` / `${ds_loki}`, sin UIDs de datasource fijos
- [ ] No hay tokens, contraseñas, URLs internas ni nombres reales de clientes
