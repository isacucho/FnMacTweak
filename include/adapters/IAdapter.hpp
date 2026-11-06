#pragma once
#include <string>

namespace fncompat {

// Interfaz que cada adaptador por version debe implementar.
// Un adaptador decide que hooks aplicar segun la version del binario del juego
// detectada en tiempo de carga (por patron, build string o UUID de DSYM).
//
// Uso tipico:
//   std::unique_ptr<IAdapter> adapter = AdapterRegistry::detect();
//   adapter->install();
//
// Si la version no se reconoce, AdapterRegistry devuelve DefaultAdapter
// (aplica todos los hooks sin condicion de version).
class IAdapter {
public:
    virtual ~IAdapter() = default;

    // Identificador legible de la version que cubre este adaptador.
    virtual std::string name() const = 0;

    // Instala los hooks especificos de esta version.
    // Se llama una sola vez desde el constructor de la dylib (post Core/Metadata).
    virtual void install() = 0;
};

} // namespace fncompat
