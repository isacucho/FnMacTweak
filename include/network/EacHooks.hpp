#pragma once
#include <string>

// Hooks de analisis del protocolo EAC/matchmaking (modulo Network).
//
// installNetHooks() instala:
//   - Hooks sobre los delegados NSURLSession del juego (didFinishDownloading, didComplete,
//     didReceiveData): intercepta el trafico verify/match para detectar kicks y refresh tokens.
//   - Hooks sobre NSMutableURLRequest (setHTTPBody:, setURL:, setValue:forHTTPHeaderField:):
//     registra el trafico hacia epicgames.com (EAC-RawTx, EAC-Auth).
//   - Hook sobre NSFileManager.moveItemAtURL:toURL:error: para trazas BackgroundHttp (dev).
//   - [dev only] og_installNetHooks: base64EncodedStringWithOptions: y CFURLRequestSetHTTPRequestBody.
//
// Nota: installNetHooks() y installSpoofHooks() son independientes. El orden en Core.mm es
// Metadata (spoof) primero, Network (EAC) despues.
void installNetHooks(void);

// Devuelve el account_id capturado de la respuesta /oauth/token.
// Vacio si el flujo OAuth todavia no ha completado.
std::string fndiag_get_logged_account_id();
