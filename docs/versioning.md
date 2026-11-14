# Versioning

## Version scheme

`X.Y.Z` aligned with the official Fortnite iOS version:

- `X`: major version of official Fortnite iOS (e.g. 23 for Fortnite 23.0.0).
  Changes when the Fortnite target is updated (new base IPA).
- `Y`: new feature in the dylib (new hook, new subsystem, new module).
  Accumulated since base IPA 42.40.1.
- `Z`: bugfix / behavior adjustment in existing dylib functionality.

IPA: `Fortnite-[X].0.0-V[X].[Y].[Z]-min.ipa`
Dylib: `FnMacBypass-V[X].[Y].[Z].dylib`

Current in VERSION: `23.8.1` (Fortnite 23.0.0, 8 features, 1 patch since 42.40.1)

## VERSION file

The current version lives in `VERSION` (one line, no trailing newline).
The Makefile reads it with `$(shell cat $(ROOT)/VERSION)` and injects it as
`-DMODULE_VERSION=\"$(VERSION)\"`. The dylib name includes it:
`FnMacBypass-V$(VERSION)$(CH_TAG).dylib`

## Dylib name by channel

```
builds/dev/     FnMacBypass-V23.8.1-dev.dylib
builds/beta/    FnMacBypass-V23.8.1-beta.dylib
builds/public/  FnMacBypass-V23.8.1.dylib
```

## GitHub Releases (repo FnMacUpdateFix)

Each release publishes the production dylib as an attached asset.

Release process:
```bash
# 1. Update VERSION
echo "23.8.2" > VERSION

# 2. Production build
make public

# 3. Commit + push
git add VERSION
git commit -m "release: V23.8.2"
git push origin main

# 4. Create GitHub release
gh release create V23.8.2 \
  builds/public/FnMacBypass-V23.8.2.dylib \
  --title "V23.8.2 - Fortnite 43.10 (build 60278837)" \
  --notes "..."
```
