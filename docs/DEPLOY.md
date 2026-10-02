# Preparación y despliegue desde GitHub Actions

El workflow `.github/workflows/tests.yml` ejecuta las pruebas locales en cada
PR. Un push a `main` ejecuta las pruebas, prepara `xml-dian` y luego despliega
`func-dian-xml-cpabaas-dev`. No instala ni modifica procedimientos Azure SQL.

## Configuración previa en GitHub

En **Settings → Secrets and variables → Actions → Variables** configure:

| Variable | Valor |
|---|---|
| `AZURE_CLIENT_ID` | Client ID de la identidad federada usada por `azure/login` |
| `AZURE_TENANT_ID` | Tenant ID de Azure |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID donde están Storage y la Function |
| `DIAN_STORAGE_ACCOUNT` | Nombre de la cuenta que usa la app en `DIAN_STORAGE_ACCOUNT` |
| `DIAN_STORAGE_RESOURCE_GROUP` | Resource group de esa cuenta Storage |
| `AZURE_FUNCTIONAPP_RESOURCE_GROUP` | Resource group de `func-dian-xml-cpabaas-dev` |

La identidad federada del workflow necesita permiso para crear contenedores
en esa cuenta (`Microsoft.Storage/storageAccounts/blobServices/containers/write`)
y para crear asignaciones de roles (`Microsoft.Authorization/roleAssignments/write`)
en el alcance del contenedor. Normalmente son permisos de administración
distintos; poder desplegar la Function no implica poder asignar roles. El
workflow fallará **antes de desplegar** si faltan los permisos. No use claves
de la cuenta Storage para resolver este requisito.

La Function debe tener identidad administrada **asignada por el sistema**.
`DIAN_STORAGE_ACCOUNT` en la configuración de la Function debe coincidir con
la variable de GitHub; el workflow no altera los App Settings. El contenedor
es `xml-dian` porque ese nombre forma parte del contrato SQL.

## Qué hace el paso de preparación

`scripts/Prepare-XmlStorage.ps1` obtiene los identificadores de los recursos,
crea `xml-dian` como contenedor privado solo si falta y comprueba que un
contenedor existente no permita acceso público. Concede a la identidad de la
Function `Storage Blob Data Contributor` en el alcance de **ese contenedor**,
solo si no tiene ya ese rol allí o heredado. No borra contenedores, blobs ni
asignaciones existentes. Si encuentra un contenedor público, se detiene para
revisión en lugar de cambiarlo silenciosamente.

La asignación RBAC puede tardar hasta 10 minutos en propagarse. Por ello, un
despliegue correcto no demuestra por sí mismo que un mensaje real ya puede
escribir en Blob. La prueba de extremo a extremo queda para la ventana de
validación operativa posterior.

## Secuencia recomendada

1. Revisar el PR y confirmar que no contiene certificados, XML reales ni
   `local.settings.json`.
2. Verificar las seis variables de GitHub y los permisos de la identidad
   federada.
3. Integrar en `main`; el workflow ejecutará pruebas, preparación y despliegue
   en ese orden. Si la preparación falla, no se publica la Function.
4. Esperar la propagación de RBAC antes de probar un mensaje real. No se
   necesita reenviar mensajes para el despliegue del código.

La preparación se prueba localmente sin Azure con
`tests/Test-PrepareXmlStorage.ps1`.
