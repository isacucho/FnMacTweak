# builds/

Todo lo que hay aqui lo genera `make` desde la raiz. Solo `Makefile` y este fichero
se versionan.

```
builds/
├── ios/FnFixUpdate-V<version>.dylib       make                  la dylib para Fortnite (arm64, iOS)
├── mac/FnFixUpdate-V<version>.dylib       make PLATFORM=mac     solo pruebas locales en macOS
├── mac-san/FnFixUpdate-V<version>.dylib   make sanitize         macOS, -O0, ASan + UBSan
├── obj/<variante>/                        objetos intermedios (se pueden ignorar)
└── release/                               make package          lo que se sube a GitHub Releases
    ├── FnFixUpdate-V<version>.dylib       ios/ firmada ad-hoc
    └── manifest.json                      version, download_url y sha256
```

La version sale del fichero `VERSION` de la raiz. Para inyectar en Fortnite.app usa el
de `release/` (o el de `ios/`: es el mismo salvo la firma ad-hoc).

`make clean` borra todo menos `Makefile` y este fichero.
