#pragma once

namespace fndiag {

// Verificador de version del cliente del juego.
// Responsabilidad unica: leer CFBundleVersion, comparar contra builds conocidos
// y registrar en el log si el build activo esta soportado.
// No hace red. Se ejecuta al inicio, antes de OtaUpdater.
void install_game_updater();

} // namespace fndiag
