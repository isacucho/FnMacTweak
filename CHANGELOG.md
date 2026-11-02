# Changelog

## [1.0.0] - 2026-11-03

Primera release estable. Fusion de FnMacUpdateFix 0.5.8 y FnMacKickFix en un unico
dylib con arquitectura modular.

### Cambios respecto a FnMacUpdateFix 0.5.x

- Integrado el modulo Metadata de FnMacKickFix: spoof de hardware (sysctlbyname, sysctl,
  uname, csops), spoof de bundle ID, ocultacion de rutas de jailbreak, bypass SSL
- Integrado el modulo Network de FnMacKickFix: hooks de delegado NSURLSession para
  intercepcion de trafico EAC (verify/match, oauth/token), log de payload TX/RX
- Logger unificado con subsistema `com.fnmaccompat` (antes: `com.alexgrdev.fnmackickfix`
  en KickFix, `fndiag` en UpdateFix)
- Arquitectura modular: Core / Hooks / Metadata / Network / Update / Input / Adapters
- Todos los .mm compilan con ARC (KickFix usaba MRC, compatible con ARC)
- og_installNetHooks movido de Metadata a Network para eliminar dependencia circular
- Makefile unificado con separacion CPP_SRC / MM_SRC y ARC solo para .mm

### Cambios respecto a FnMacKickFix

- Sistema de configuracion (FnDiag.conf + FNDIAG_* env vars) heredado de UpdateFix
- Pipeline de descarga de assets integrado (FileHooks, NetworkHooks, SessionOverride,
  EngineHooks)
- Autoupdater con verificacion SHA-256 y reemplazo atomico
- Modulo Input: FPS unlock, InputIni, NativeKbm scanner, InputProbe GameController
- GameLogMirror: espejo de FortniteGame.log con anillo de contexto

### Bugs corregidos

- URL del autoupdater apuntaba al repo incorrecto (FnMacCompatLayer -> FnMacUpdateFix)
- DiagLog usaba subsistema `fndiag` en lugar de `com.fnmaccompat`
- Codigo muerto eliminado: spoof_emit, cstr_spoof, gSpoofLogPath/gLogQueue/gLogFile
  en DeviceSpoof.mm; objDesc() en EngineHooks.mm (reemplazado por fndiag::objc::describe)
- og_shouldSkipURL definida fuera de #ifndef PRODUCTION aunque solo se usa dentro
