# FnMacUpdateFix

Compatibility layer for running the Fortnite iOS binary on macOS (Apple Silicon).
Injected as a dylib via `DYLD_INSERT_LIBRARIES`.

## What it does

| Module | Description |
|--------|-------------|
| Metadata | Hardware spoof (iPad14,3 / iPadOS 17.5), bundle ID spoof, jailbreak path hide, SSL bypass |
| Network | EAC traffic interception (verify/match, oauth/token), NSURLSession delegate hooks |
| Update | Asset download pipeline fix: 201→200 patch, relative paths, session isolation |
| Input | FPS unlock, Input.ini, GameController probe, ARM64 KBM scanner |

## Requirements

- macOS 14+ (Apple Silicon)
- Xcode with iOS SDK (`xcrun --sdk iphoneos`)
- Fortnite iOS binary

## Build

```bash
# Dev build (unoptimized, verbose logging)
make

# Beta build
make beta

# Production build (optimized, minimal logging)
make public
```

Build variants per product:

```bash
make public PRODUCT=FnMacKickFix    # FnMacKickFix-V1.0.0.dylib
make public PRODUCT=FnMacUpdateFix  # FnMacUpdateFix-V1.0.0.dylib
```

Output: `builds/<channel>/<PRODUCT>-V<VERSION>[-beta|-dev].dylib`

## Configuration

Create `$HOME/Documents/FnDiag.conf`:

```
relative_paths=true
patch_status=true
create_dirs=true
unlock_fps=true
fps_target=120
```

All options documented in [docs/config.md](docs/config.md).

## Releases

Binaries are distributed via GitHub Releases — no source is published.

- [FnMacUpdateFix releases](https://github.com/AlexGRDev/FnMacUpdateFix/releases)
- [FnMacKickFix releases](https://github.com/AlexGRDev/FnMacKickFix/releases)

## Docs

- [docs/architecture.md](docs/architecture.md) — module overview, hook order, design decisions
- [docs/config.md](docs/config.md) — all configuration flags
- [docs/pitfalls.md](docs/pitfalls.md) — known bugs and workarounds
- [docs/versioning.md](docs/versioning.md) — version scheme and release process
