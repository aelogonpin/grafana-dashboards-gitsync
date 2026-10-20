# Manual de uso (muy fácil)

Este repo es una **caja de paneles de Grafana**. Tú metes los paneles aquí, y cada cliente los ve en su Grafana.

## La idea en 4 dibujos

```
1. Tú guardas los paneles "para todos" en una caja grande:      master/general/
2. Una lista dice qué caja le toca a cada cliente:               master/config.yaml
3. Un robot (GitHub Actions) reparte las cajas a cada cliente:   tenants/<cliente>/general/
4. Grafana de cada cliente mira su carpeta y muestra los paneles (Git Sync)
```

> ¿Aún no lo tienes montado? Empieza por el [quick start](QUICKSTART.md).

Y además cada cliente tiene su **cajón propio** para paneles solo suyos: `tenants/<cliente>/custom/`.

## Las 3 reglas de oro

1. **Los paneles "para todos" se tocan solo en `master/general/`.** Nunca en `tenants/<cliente>/general/`: esa carpeta la escribe el robot y borra lo que pongas a mano (y la PR fallará).
2. **En los paneles no se escribe el UID de un datasource.** Se usa `${ds_mimir}` o `${ds_loki}`. Así el mismo panel vale para todos los clientes.
3. **Nunca subas contraseñas, tokens ni nombres de clientes reales.** El repo es público.

---

## Recetas

### Receta 1: darle a un cliente una carpeta más

Ejemplo: que `cliente-b` también reciba `aplicacion`.

1. Abre `master/config.yaml`.
2. Busca `cliente-b` y añade la carpeta en `general`:
   ```yaml
   cliente-b:
     orgId: 2
     gitSync: true
     general:
       - kubernetes
       - alertas
       - aplicacion        # <- nueva
   ```
3. Guarda, haz commit y push a `main`.
4. Espera 1 minuto: el robot crea un commit "regenerar paneles" y Grafana de `cliente-b` muestra la carpeta Aplicación.

### Receta 2: quitarle a un cliente una parte de una carpeta

Ejemplo: `cliente-a` recibe `aplicacion` pero **no** `licencias`.

```yaml
cliente-a:
  general:
    - aplicacion
  exclude:
    - aplicacion/licencias     # <- esta subcarpeta no la recibe
```

Si quitas algo del config, **desaparece** de ese cliente en el siguiente push.

### Receta 3: dar un solo panel suelto

```yaml
cliente-c:
  general:
    - aplicacion/metrics/api.json    # solo ese fichero
```

### Receta 4: crear un panel nuevo para todos

1. Haz el panel en Grafana (en cualquier org de pruebas).
2. *Dashboard → Export → Export as JSON* y descárgalo.
3. Conviértelo con el script, que hace todo el trabajo sucio por ti (cambia los datasources por `${ds_mimir}` / `${ds_loki}`, añade las variables y le pone el `uid`):
   ```bash
   scripts/convert-dashboard.sh ~/Descargas/mi-panel.json gen-mi-panel master/general/kubernetes/mi-panel.json
   ```
   El `uid` (aquí `gen-mi-panel`) tiene que ser nuevo: que no lo tenga ningún otro panel.
4. Prueba en tu máquina: `scripts/render.sh --check`. Si dice `OK`, haz push.

Los clientes que tengan `kubernetes` en su config lo verán solos.

### Receta 5: crear un panel solo para un cliente

1. Guarda el JSON en `tenants/<cliente>/custom/` (puedes hacer subcarpetas).
2. Ponle un `uid` que ese cliente no tenga ya.
3. Push. Solo ese cliente lo verá, en la carpeta "Paneles propios".

En los paneles propios **sí** puedes usar el UID real de un datasource, pero es mejor usar las variables.

También se puede crear desde Grafana: guardas el panel en la carpeta "Paneles propios" del cliente y Grafana abre una PR en GitHub. Cuando la aceptas, queda en el repo.

### Receta 6: añadir un cliente nuevo

1. En Grafana, crea la org del cliente y sus datasources. Sus nombres **tienen que empezar** por `Mimir` y `Loki` (por ejemplo `Mimir-cliente-d`, `Loki-cliente-d`).
2. En `master/config.yaml`:
   ```yaml
   cliente-d:
     orgId: 4             # el ID de su org en Grafana
     gitSync: false       # todavía no se conecta
     general:
       - kubernetes
   ```
3. Push. El robot crea `tenants/cliente-d/`.
4. Cuando quieras que su Grafana lo lea, cambia a `gitSync: true` y haz push.
5. El Job de Git Sync (en Kubernetes o en Docker) crea su conexión la próxima vez que se ejecute.

### Receta 7: carpetas con nombre bonito

Los títulos de las carpetas salen de `_folder.json`. Para cambiar cómo se ve una carpeta de `master/general/`:

```json
{"apiVersion":"folder.grafana.app/v1beta1","kind":"Folder","metadata":{"name":"titulo"},"spec":{"title":"Kubernetes"}}
```

Solo importa `spec.title`. El UID lo pone el robot. Nunca uses `general` como UID: Grafana lo tiene reservado.

---

## Cómo saber si algo va mal

| Lo que ves | Qué pasa | Qué hacer |
|---|---|---|
| La Action sale en rojo con `ERROR: ... la ruta 'x' no existe` | Escribiste mal una carpeta en el config | Corrige el nombre |
| `datasource con UID fijo` | Un panel general lleva un UID de datasource | Cámbialo por `${ds_mimir}` o `${ds_loki}` |
| `uid 'x' repetido` | Dos paneles del mismo cliente tienen el mismo `uid` | Cambia uno |
| La PR falla con `no se editan a mano` | Tocaste `tenants/*/general/` | Haz el cambio en `master/` |
| Grafana: `write permission denied` | El token no puede escribir en el repo | Token con *Contents*, *Pull requests* y *Webhooks* en Read and write |
| Grafana: el panel sale vacío | La org no tiene datasource que empiece por `Mimir`/`Loki` | Renómbralo |

---

## Probar todo en tu ordenador

Necesitas Docker. Desde la raíz del repo:

```bash
scripts/render.sh                                     # prepara deploy/tenants.json
cp dev/.env.example dev/.env                          # y pon tu token en GITHUB_TOKEN (no se sube nunca)
docker compose -f dev/docker-compose.yml up -d         # arranca todo
```

Abre **http://localhost:3001** (usuario `admin`, contraseña `admin`) y cambia de org arriba a la izquierda.

| Comando | Para qué |
|---|---|
| `dev/status.sh` | ver la conexión de Git Sync y los paneles de cada org |
| `dev/check-isolation.sh` | comprobar que cada org solo ve los datos de su cliente |
| `dev/check-queries.sh <panel.json> [org]` | comprobar que cada consulta de un panel devuelve datos |
| `docker compose -f dev/docker-compose.yml run --rm gitsync-init` | volver a lanzar el Job |
| `docker compose -f dev/docker-compose.yml down -v` | borrarlo todo |

## Glosario

| Palabra | Qué es |
|---|---|
| **Org** | un "Grafana dentro de Grafana" para cada cliente |
| **Datasource** | de dónde saca los datos un panel (Mimir = métricas, Loki = logs) |
| **Git Sync** | la función de Grafana que lee paneles de un repo de GitHub |
| **Job** | un programa que se ejecuta una vez y termina; aquí crea las conexiones de Git Sync |
| **Tenant** | cliente |
| **UID** | el DNI de un panel o carpeta; no puede repetirse dentro de una org |
