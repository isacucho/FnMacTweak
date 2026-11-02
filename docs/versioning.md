# Sistema de versiones

## Historial de proyectos predecesores

| Proyecto        | Ultima version | Repo GitHub              |
|-----------------|---------------|--------------------------|
| FnMacUpdateFix  | 0.5.8         | AlexGRDev/FnMacUpdateFix |
| FnMacKickFix    | sin releases  | AlexGRDev/FnMacKickFix   |

FnMacCompatLayer 1.0.0 unifica ambos. El repo de distribucion es FnMacUpdateFix.

## Esquema de version

`MAJOR.MINOR.PATCH` (SemVer):
- MAJOR: cambio de arquitectura o rotura de compatibilidad con configuracion anterior
- MINOR: nueva funcionalidad (nuevo modulo, nuevo flag de config)
- PATCH: correcciones de bugs sin cambio de interfaz

## Fichero VERSION

La version actual vive en `VERSION` (una linea, sin salto de linea final extra).
El Makefile lo lee con `$(shell cat $(ROOT)/VERSION)` y lo inyecta como
`-DMODULE_VERSION=\"$(VERSION)\"`. El nombre de la dylib lo incluye:
`FnMacCompatLayer-V$(VERSION)$(CH_TAG).dylib`

## Nombre de la dylib por canal

```
builds/dev/     FnMacCompatLayer-V1.0.0-dev.dylib
builds/beta/    FnMacCompatLayer-V1.0.0-beta.dylib
builds/public/  FnMacCompatLayer-V1.0.0.dylib
```

## Releases en GitHub (repo FnMacUpdateFix)

Cada release publica dos ficheros:
- `FnMacCompatLayer-V1.0.0.dylib` — la dylib de produccion (PRODUCTION=1, arm64)
- `manifest.json` — metadatos para el autoupdater

Formato de manifest.json:
```json
{
  "version": "1.0.0",
  "download_url": "https://github.com/AlexGRDev/FnMacUpdateFix/releases/download/v1.0.0/FnMacCompatLayer-V1.0.0.dylib",
  "sha256": "<hex sha256 de la dylib>"
}
```

El autoupdater (src/update/Updater.mm) verifica:
1. Descarga manifest.json desde la URL configurada en Core.mm (UPDATE_MANIFEST_URL)
2. Compara version remota con MODULE_VERSION (inyectado en compilacion)
3. Si la version remota es mayor, descarga la dylib
4. Verifica SHA-256 antes de aplicar
5. Reemplaza la dylib en disco con rename atomico (actual.new -> actual, guarda actual.bak)

## Proceso de release

```bash
# 1. Actualizar VERSION
echo "1.0.1" > VERSION

# 2. Build de produccion
make public

# 3. Calcular SHA-256
sha256sum builds/public/FnMacCompatLayer-V1.0.1.dylib

# 4. Crear manifest.json (sustituir SHA y URL)
cat > manifest.json << EOF
{
  "version": "1.0.1",
  "download_url": "https://github.com/AlexGRDev/FnMacUpdateFix/releases/download/v1.0.1/FnMacCompatLayer-V1.0.1.dylib",
  "sha256": "<sha256>"
}
EOF

# 5. Commit + tag
git add VERSION CHANGELOG.md
git commit -m "release: v1.0.1"
git tag v1.0.1

# 6. Crear release en GitHub
gh release create v1.0.1 \
  builds/public/FnMacCompatLayer-V1.0.1.dylib \
  manifest.json \
  --title "v1.0.1" \
  --notes "$(cat CHANGELOG.md | head -30)"
```

## Migracion al repo FnMacUpdateFix

Para inicializar FnMacCompatLayer usando el repositorio FnMacUpdateFix:

```bash
cd FnMacCompatLayer
git init
git remote add origin https://github.com/AlexGRDev/FnMacUpdateFix.git
git fetch origin

# Opcion A: historia limpia (orphan branch)
git checkout --orphan main
git add .
git commit -m "refactor: merge FnMacUpdateFix + FnMacKickFix -> FnMacCompatLayer v1.0.0"
git push --force origin main  # DESTRUCTIVO: elimina historia anterior

# Opcion B: conservar historia de FnMacUpdateFix
git reset --hard origin/main
git add .                     # los ficheros nuevos/modificados
git commit -m "refactor: ..."
git push origin main
```

Los tags antiguos (v0.1.0 ... v0.4.1) pueden eliminarse del remoto si ya no son
necesarios para el autoupdater de versiones anteriores:
```bash
git push origin --delete v0.1.0 v0.2.0 v0.2.1 v0.2.2 v0.3.0 v0.3.1 v0.3.2 v0.3.3 v0.4.0 v0.4.1
```
