#pragma once

// Instala todos los hooks del modulo Metadata en un solo paso:
//   - Spoof de hardware: sysctlbyname, sysctl, uname, host_statistics64 -> "iPad14,3 / iPadOS 17.5"
//   - Ocultacion de dylib: dladdr, _dyld_image_count, _dyld_get_image_name, getenv (DYLD_*)
//   - Bypass de firma: SecTrustEvaluate, SecTrustEvaluateWithError -> proceed/true
//   - Bypass de code-signing: csops(CS_OPS_STATUS) -> CS_VALID
//   - Spoof de bundle: NSBundle.bundleIdentifier -> "com.epicgames.fortnite"
//   - Spoof de dispositivo ObjC: UIDevice.model/systemName/systemVersion, NSProcessInfo.activeProcessorCount
//   - Ocultacion de jailbreak: NSFileManager.fileExistsAtPath para rutas de Cydia/apt/...
//
// Debe instalarse ANTES de cualquier hook de Update/Network para que los hooks de
// fileExistsAtPath se encadenen en el orden correcto (Metadata outer, Update inner).
void installSpoofHooks(void);
