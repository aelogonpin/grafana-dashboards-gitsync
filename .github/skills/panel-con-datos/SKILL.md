---
name: panel-con-datos
description: Diseñar y construir paneles de Grafana con información realista (KPIs de negocio, latencias, errores, plataforma) usando LogQL y PromQL sobre los datos del entorno de pruebas, y verificar que cada consulta devuelve datos antes de subirlo. Úsala cuando el usuario pida un panel "de verdad", con datos realistas, o un dashboard de negocio para un cliente.
---

# Panel con datos realistas

## Datos disponibles en `dev/`

**Logs (Loki)**, etiquetas `{app="tienda", cliente="<cliente>", level="info|warn|error"}`, línea en logfmt (`dev/stack/log-generator.sh`):

| `msg` | Campos | Nivel | Proporción |
|---|---|---|---|
| `pedido creado` | `pedido importe metodo canal region endpoint=/checkout status=201 duration_ms` | info | ~60 % |
| `carrito abandonado` | `importe canal region endpoint=/cart duration_ms` | info | ~15 % |
| `pago rechazado` | `pedido importe metodo canal region status=402 duration_ms motivo` | error | ~8 % |
| `latencia alta` | `endpoint canal region duration_ms` (800–3000) | warn | ~10 % |
| `stock bajo` | `sku unidades region` | warn | ~7 % |

Valores: `metodo` ∈ tarjeta/bizum/paypal/transferencia; `canal` ∈ web/app/tienda; `region` ∈ norte/sur/este/oeste/centro; `motivo` ∈ fondos_insuficientes/tarjeta_caducada/fraude/timeout_pasarela. Volumen por ciclo de 2 s: cliente-a 1, cliente-b 2, cliente-c 3.

**Métricas (Mimir)**: node-exporter (`node_cpu_seconds_total`, `node_memory_*`, `node_network_*`, `node_uname_info`…), Prometheus y Mimir (`up`, `prometheus_http_requests_total`, `process_resident_memory_bytes`…), todas con las etiquetas `cliente` y `cluster="dev"`. Variables típicas de paneles de nodos: `cluster` → `label_values(cluster)`, `host` → `label_values(node_uname_info{cluster="$cluster"}, nodename)`, `instance` → `node-exporter:9100`.

## Patrones de consulta

```logql
# base: parsear y descartar líneas mal formadas
{app="tienda"} | logfmt | __error__=""

# KPI de una ventana
sum(sum_over_time({app="tienda"} | logfmt | __error__="" | msg="pedido creado" | unwrap importe [1h]))   # facturación
sum(count_over_time({app="tienda"} | logfmt | __error__="" | msg="pedido creado" [1h]))                  # pedidos
# ratio (%): 100 * rechazados / (pedidos + rechazados)

# por dimensión: filtra la etiqueta vacía para que no salgan series sin nombre
sum by (canal) (sum_over_time({app="tienda"} | logfmt | __error__="" | msg="pedido creado" | canal!="" | unwrap importe [5m]))

# percentil de latencia
quantile_over_time(0.95, {app="tienda"} | logfmt | __error__="" | endpoint="/checkout" | canal!="" | unwrap duration_ms [5m]) by (canal)
```

## Construcción

1. Estructura recomendada (24 columnas de ancho): fila de KPIs (`stat`, h 5), tendencias (`timeseries`), repartos (`piechart` donut, `bargauge` horizontal), calidad (latencias, motivos de error), operación (`logs`) y plataforma (Mimir: `gauge` de CPU, peticiones).
2. Datasources solo por variable: `{"type":"loki","uid":"${ds_loki}"}` y `{"type":"prometheus","uid":"${ds_mimir}"}`, con el bloque `templating` estándar (ver `master/general/*`). Nada de UIDs fijos.
3. Unidades y umbrales: `currencyEUR`, `percent` (con `min`/`max` en gauges), `ms`; umbrales verde/naranja/rojo en las tasas de error.
4. `stat`: `reduceOptions.calcs: ["lastNotNull"]`. Títulos que digan la ventana ("última hora", "cada 5 min").
5. Lo más cómodo es generar el JSON con `jq` a partir de una función por panel (tipo, título, gridPos, ds, expr, leyenda, opciones), como en `tenants/cliente-a/custom/negocio/negocio-online.json`. Ese fichero sirve de ejemplo completo.

## Verificación (obligatoria antes de subir)

```bash
dev/check-queries.sh <panel.json> <org> [now-1h]   # todas las filas en OK y con cifras con sentido
scripts/render.sh --check
```

- Las consultas con variables del panel salen como `VAR`: sustituye a mano los valores (`cluster=dev`, `instance=node-exporter:9100`) para probarlas, o revísalas en Grafana.
- Comprueba que las cifras son verosímiles (ticket medio entre 5 y 250 €, % de rechazo ~10–15 %, p95 de checkout cientos de ms) y que ninguna serie sale sin nombre.
- Si es un panel general, pruébalo en dos orgs: mismo JSON y datos distintos por cliente.
- Para subirlo, sigue la skill `publicar-cambios`.
