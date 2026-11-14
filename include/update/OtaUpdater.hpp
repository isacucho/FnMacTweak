#pragma once
#import <Foundation/Foundation.h>
#include <string>

// Actualizador OTA de la propia dylib.
// Responsabilidad unica: descargar manifest de GitHub Releases, comparar version,
// descargar y validar la dylib nueva (SHA-256), y dejarla en el container para
// que el usuario la aplique con deploy.sh.
//
// NUNCA usa [NSURLSession sharedSession]; crea una sesion efimera dedicada para
// no interferir con las conexiones de Epic. Solo se ejecuta si config().autoupdate.
class OtaUpdater {
public:
    static OtaUpdater& getInstance() {
        static OtaUpdater instance;
        return instance;
    }

    void setConfig(const std::string& manifestUrl, const std::string& currentVersion);
    void checkForUpdates();

private:
    OtaUpdater() = default;

    std::string m_manifestUrl;
    std::string m_currentVersion;

    bool isTrustedURL(NSURL* url);
    NSURLSession* makeSession();
    void downloadFile(NSURLSession* session, NSURL* url,
                      void (^completion)(NSString* path, NSError* error));
    std::string sha256OfFile(NSString* path);
    bool applyUpdate(const std::string& newDylibPath);
    bool isVersionNewer(const std::string& remote, const std::string& local);
};
