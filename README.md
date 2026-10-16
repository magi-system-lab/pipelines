# pipelines

Perfiles de despliegue del homelab. Los repos de apps no contienen lógica de CI:
solo un `launch.yml` que declara lo suyo y un disparador genérico de 10 líneas.

## Cómo agregar una app

1. Copia `ejemplos/launch.yml` a la raíz del repo y ajusta `app`, `port`, `host`.
2. Copia `ejemplos/pipeline.yml` a `.github/workflows/pipeline.yml`.
3. Crea los secretos de Actions del repo:
   - `CLUSTER_HOST` y `CLUSTER_USER` — obligatorios, apuntan a balthazar.
   - `APP_PROPERTIES_PREVIEW` y `APP_PROPERTIES_PROD` — opcionales, con el
     contenido de `application.properties`. Se montan en `/config` del pod.
4. Abre un PR: se crea su preview. Haz merge: se despliega a prod.

## Qué hace el flujo

| Evento | Resultado |
|---|---|
| PR abierto o actualizado | preview en el namespace `pr-<número>`, con tope de recursos |
| PR cerrado | su namespace se borra |
| push a una rama de `environments.prod.branches` | despliegue a `prod` |
| push a cualquier otra rama | no hace nada |

## Arquitectura

- **Build**: Podman en la Mac (arm64 nativo, sin emulación).
- **Entrega de imagen**: sin registry. `podman save` por SSH hacia
  `k3s ctr images import` en balthazar. El chart usa `imagePullPolicy: Never`.
  El registry entra cuando balthazar tenga SSD.
- **Despliegue**: Helm, un chart por perfil en `profiles/<perfil>/chart`.
- **Prioridades**: prod usa `prod-priority` (1000), los previews
  `preview-priority` (100). Si falta memoria, Kubernetes desaloja previews.

## Seguridad con repos públicos

El runner vive en mi red, así que hay dos barreras:

1. GitHub exige aprobación para **todo** contribuidor externo
   (`all_external_contributors`).
2. El job está condicionado a que el PR venga de una rama del propio repo. Un PR
   desde un fork no coincide con la condición, así que no puede ejecutarse en mi
   Mac ni aprobándolo por error.

Este repo es público **por obligación**: un repo público no puede consumir
workflows reusables de uno privado. Por eso la IP y el usuario de balthazar no
están en el código, sino en secretos de cada repo de app.

## Pendientes conocidos

- **Vault**: hoy las properties vienen de secretos de Actions. Cuando Vault y
  External Secrets estén arriba, cambia el origen, no el `launch.yml`.
- **DNS**: el chart ya genera el Ingress si declaras `host`, pero hasta que
  AdGuard resuelva `*.lab.home.arpa` se accede por `IP:NodePort`.
- **Perfil `node`**: 3 de los 5 pipelines actuales son Node o frontends.
- **Limpieza de previews olvidados**: falta la tarea que borre los de más de 24 h.
