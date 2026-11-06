---
name: desplegar-en-kubernetes
description: Desplegar en un clúster de Kubernetes el chart de Helm grafana-gitsync (un Job por cliente que conecta su Git Sync), con ArgoCD o con helm, comprobar que funciona y diagnosticar fallos de los Jobs o de la Application. Úsala cuando el usuario hable de ArgoCD, del chart, de los Jobs gitsync-<cliente>, de llevarlo a un clúster o a producción, o de por qué un cliente no queda conectado.
---

# Desplegar el chart grafana-gitsync

El chart `deploy/chart/grafana-gitsync` lee `master/config.yaml` como fichero de values y crea **un Job `gitsync-<cliente>` por cada cliente con `gitSync: true`**. Cada Job crea la conexión de Git Sync de su org solo si no existe (idempotente). Son hooks `post-install,post-upgrade` de Helm, que ArgoCD ejecuta como **PostSync** en cada sincronización.

## Es independiente del stack de monitorización

| Lo gestiona el repo del stack (no este) | Lo gestiona este repo |
|---|---|
| Grafana con Git Sync activado (`[feature_toggles] provisioning = true`) | paneles por cliente (`master/`, `tenants/`) |
| Orgs y datasources (aprovisionamiento del chart de Grafana) | el chart con un Job por cliente |
| su Application y su namespace | su Application `grafana-gitsync` y su namespace `grafana-gitsync` |

Los Jobs solo necesitan llegar a Grafana por la red. No metas nada de este sistema en el repo ni en el namespace del stack.

## Requisitos antes de desplegar

1. Grafana 13.x con Git Sync activado y fuera de legacy storage (el Job aborta si sigue en legacy).
2. Las orgs de los clientes existen y tienen sus datasources con nombres que empiezan por `Mimir` / `Loki` (los buscan las variables de los paneles). Lo crea el aprovisionamiento del stack, no este chart. Grafana no arranca si un datasource provisionado apunta a una org inexistente: la org va antes.
3. Secret `grafana-gitsync` en el namespace del chart, con **4 claves**: `grafana-user`, `grafana-password` (admin de Grafana), `github-token` (PAT con permiso `repo`, aunque no sea GitHub; con SSO autorizado si aplica) y `git-user` (usuario del PAT). Puede venir de un SealedSecret, cuyo nombre y namespace deben coincidir. Compruébalo sin ver valores: `kubectl -n <ns> get secret grafana-gitsync -o json | jq '.data | keys'`.
4. Si el repo de paneles es privado, una credencial de repo en ArgoCD con `type: git`, `url` completa (`https://...git`, idéntica a los `repoURL`), usuario y PAT, sin `enableOCI`. Es independiente del token que usa Grafana.
5. En producción, una imagen que ya traiga `curl` y `jq` y `image.installTools: false` (por defecto instala los paquetes al arrancar y necesita salida a internet).

Antes de aplicar, comprueba también: `repo.branch` y los `targetRevision` apuntan a una rama subida con el chart y `tenants/`; un solo cliente piloto en `gitSync: true`; ningún panel con el mismo UID cargado por ConfigMap; y que no quedan conexiones antiguas con otro tipo o nombre.

## Desplegar

**Con ArgoCD** (recomendado): parte de `deploy/argocd/application.example.yaml`. Usa dos fuentes del mismo repo: el chart y el repo como `ref: paneles` para pasar `$paneles/master/config.yaml` como values. Ajusta `grafana.url` (Service de Grafana visto desde el clúster, con sub-path si lo usa) como parámetro de la Application, no en el repo. Destino: namespace `grafana-gitsync` con `CreateNamespace=true`.

**Sin ArgoCD:**

```bash
helm upgrade --install grafana-gitsync deploy/chart/grafana-gitsync -n grafana-gitsync --create-namespace \
  -f master/config.yaml --set grafana.url=http://<service-de-grafana>
```

Antes de cualquier cambio en el chart: `helm lint deploy/chart/grafana-gitsync -f master/config.yaml` y `helm template ... -f master/config.yaml`. La validación de PRs ejecuta lo mismo.

## Comprobar

```bash
kubectl -n argocd get application grafana-gitsync          # Synced / Healthy
kubectl -n grafana-gitsync get jobs                        # un gitsync-<cliente> por cliente con gitSync: true
kubectl -n grafana-gitsync logs job/gitsync-<cliente>      # "creado ..." o "ya existe ...; no se toca"
```

Estado de la conexión en Grafana, sin pasar credenciales a ningún pod (port-forward desde tu máquina):

```bash
kubectl -n <ns-de-grafana> port-forward svc/<grafana> 3999:80 &
curl -s -u "$USER:$PASS" http://127.0.0.1:3999/<sub-path>/apis/provisioning.grafana.app/v0alpha1/namespaces/<ns>/repositories/gitsync-<cliente> | jq .status
```

(`<ns>`: `default` para la org 1, `org-<id>` para el resto.) Evita `kubectl run` con credenciales en `--env`: quedan en los logs del contenedor.

Prueba de creación sin tocar el config: borra la conexión de un cliente en Grafana (`DELETE .../repositories/gitsync-<cliente>`), relanza el sync y su Job debe decir "creado". Para probar un cliente ficticio sin tocar el repo, añádelo como parámetro de la Application (`tenants.<nombre>.orgId`, `tenants.<nombre>.gitSync`) y quítalo después.

## Alta de un cliente

1. Org y datasources en el repo del stack (aprovisionamiento de Grafana). Despliega y comprueba que la org existe.
2. El cliente en `master/config.yaml` con su `orgId` real (skill `nuevo-cliente`) y `gitSync: true`.
3. Push a `main` (skill `publicar-cambios`). ArgoCD detecta el cambio, pinta el Job `gitsync-<cliente>` y lo conecta.

Desplegar por tandas = ir poniendo `gitSync: true` a unos clientes en cada commit.

## Qué hace el Job y cuándo corre

- Solo crea la conexión si falta. Compara por nombre y **no cambia una conexión existente**.
- Corre en cada sync de ArgoCD: al cambiar `config.yaml` o el chart, o con *Sync* manual. Cambiar solo paneles no lo lanza: esos cambios los recoge Grafana cada `intervalSeconds`.
- Para cambiar token, URL, rama o tipo: actualiza el Secret o el config, borra la conexión (`DELETE .../repositories/gitsync-<cliente>`) y lanza un *Sync*. Se van sus paneles gestionados y vuelven desde el repo.
- Pure Git no usa webhooks y no abre PR. `workflows: []` deja la conexión en solo lectura; `["branch"]` crea ramas al guardar desde la web.

## Diagnóstico

| Síntoma | Causa | Solución |
|---|---|---|
| Sync `Failed` y un Job en rojo | el Job de ese cliente falló | `kubectl -n grafana-gitsync logs job/gitsync-<cliente>`: el mensaje dice si es la org, Grafana o el token |
| pod en `CreateContainerConfigError`, ArgoCD en `Running` | falta el Secret o una de sus 4 claves | añádela: el Job arranca solo |
| el Job dice `ya existe` pero la conexión sigue con el tipo, token o rama antiguos | el Job no cambia conexiones | borra la conexión y lanza un *Sync* |
| `Invalid username or token` | PAT de otro servidor o caducado | usa uno de ese servidor Git |
| `SAML SSO` en el error | PAT o clave SSH sin autorizar | *Configure SSO → Authorize* en la organización |
| `strconv.ParseBool` en ArgoCD | booleano mal escrito en el Secret del repo | quita ese campo o corrígelo |
| ArgoCD no conecta con el repo | `url` sin `https://`, o `enableOCI` puesto | corrige el Secret del repo |
| `repository URL host must resolve to a public or allowed address` | servidor Git con IP privada | añádelo a `[provisioning] allowed_git_urls` |
| `401` con `identity.disabled` en el log de Grafana | admin deshabilitado | habilítalo en *Administration → Users* |
| `Access denied` en una org | el admin no es miembro | añádelo en *Administration → Organizations* |
| Git Sync no se hace cargo de un panel | existe sin gestor con el mismo UID | borra ese panel de Grafana |
| `la org N no existe` | falta la org en el aprovisionamiento del stack o el `orgId` del config no es el real | crearla en el stack / corregir `orgId` |
| `Grafana está en legacy storage` | Grafana aún no se ha subido a la 13 o la migración no terminó | subir Grafana; el Job no crea nada mientras tanto |
| `Grafana no responde` | `grafana.url` mal (Service, puerto o sub-path) o NetworkPolicy | revisar el value y la conectividad desde el namespace `grafana-gitsync` |
| la conexión se crea pero sale `write permission denied` | el token no puede escribir en el repo, o no tiene acceso a ese repo concreto | permisos del token (Read and write) y *Repository access* |
| `repo.url está vacío` al renderizar | falta `master/config.yaml` como values | revisar `valueFiles` y la fuente `ref: paneles` de la Application |
| tras cambiar el namespace destino, no hay Jobs en el nuevo | el sync automático solo movió los recursos; los hooks corren en el siguiente sync | relanzar el sync |
| quedan Jobs antiguos (otro namespace, otro nombre) | ArgoCD no hace *prune* de los hooks | borrarlos a mano |
| el Secret falta en el namespace nuevo | el chart no gestiona el Secret | crearlo o copiarlo al namespace `grafana-gitsync` |

## Baja de un cliente

Quitarlo de `master/config.yaml` (o `gitSync: false`) hace que su Job deje de pintarse, pero **la conexión en Grafana no se borra**: hazlo desde Grafana (*Administration → Provisioning*) o con `DELETE .../repositories/gitsync-<cliente>`.
