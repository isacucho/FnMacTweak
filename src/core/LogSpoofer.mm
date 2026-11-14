#import <Foundation/Foundation.h>
#include "core/LogSpoofer.hpp"
#include "core/DiagLog.hpp"
#include <cstdio>
#include <string>

#ifndef MODULE_VERSION
#define MODULE_VERSION "0.0.0"
#endif

static const char* kSubsystem = "com.alexgrdev.fnmacbypass";
static const char* kCategory  = "diag";

namespace fndiag {

void write_log_key_file(const std::string& container_path) {
    std::string key_path = container_path + "/Documents/FnDiag_LogKey.txt";
    FILE* f = fopen(key_path.c_str(), "w");
    if (!f) {
        log_line("[LogSpoofer] no se pudo escribir %s", key_path.c_str());
        return;
    }

    std::string log_path = container_path + "/Documents/FnDiag.log";

    fprintf(f,
        "=== FnMacBypass v" MODULE_VERSION " - Log Collection Key ===\n"
        "\n"
        "Subsistema os_log : %s\n"
        "Categoria         : %s\n"
        "Log de diagnostico: %s\n"
        "\n"
        "--- Captura en tiempo real (pega en Terminal) ---\n"
        "log stream --predicate 'subsystem == \"%s\"' --info --debug --color always\n"
        "\n"
        "--- Solo errores ---\n"
        "log stream --predicate 'subsystem == \"%s\" && messageType == error' --color always\n"
        "\n"
        "--- Volcar el log de esta sesion ---\n"
        "cat \"%s\"\n"
        "\n"
        "Adjunta la salida al reporte y enviala al desarrollador.\n",
        kSubsystem, kCategory, log_path.c_str(),
        kSubsystem,
        kSubsystem,
        log_path.c_str()
    );

    fclose(f);
    log_line("[LogSpoofer] LogKey escrito en %s", key_path.c_str());
}

} // namespace fndiag
