# builds/

Todo lo que hay aqui lo genera `make` desde la raiz. Solo `Makefile` y este fichero
se versionan. Hay cuatro carpetas, una por canal:

| Carpeta    | Comando            | Contenido |
|------------|--------------------|-----------|
| `dev/`     | `make`             | iOS arm64, `-O0`: `FnFixUpdate-V<version>-dev.dylib` |
|            | `make sanitize`    | macOS con ASan + UBSan: `...-dev-mac-san.dylib` |
|            | `make mac`         | macOS para pruebas locales: `...-dev-mac.dylib` |
| `beta/`    | `make beta`        | iOS arm64, `-O2`, con todos los logs: `FnFixUpdate-V<version>-beta.dylib` |
| `public/`  | `make public`      | iOS arm64, `-O2`, `PRODUCTION` (sin LOG_D/LOG_I): `FnFixUpdate-V<version>.dylib` |
| `release/` | `make package`     | lo que se sube a GitHub Releases: la dylib de `public/` firmada ad-hoc y `manifest.json` |

`make package CHANNEL=beta` empaqueta la beta (para un prerelease). Los objetos
intermedios estan en `<canal>/.obj/` (carpeta oculta).

La version sale del fichero `VERSION` de la raiz. El nombre y el canal se calculan en
`common.mk`. Para probar en Fortnite.app inyecta la de `beta/` (o la de `dev/`);
la de `public/` es la que se publica.

`make clean` borra las cuatro carpetas.
