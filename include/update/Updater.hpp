#pragma once
#import <Foundation/Foundation.h>
#include <string>

// Auto-actualizador: descarga el manifest de GitHub Releases, compara versiones,
// descarga la dylib nueva con verificacion SHA-256 y la deja en su sitio con rename atomico.
// La dylib actual permanece intacta hasta el ultimo paso (apagado seguro).
// Solo descarga desde github.com / githubusercontent.com (isTrustedURL).
class Updater {
public:
    static Updater& getInstance() {
        static Updater instance;
        return instance;
    }

    void setUpdateConfig(const std::string& manifestUrl, const std::string& currentVersion);
    void checkForUpdates();

private:
    Updater() = default;

    std::string m_manifestUrl;
    std::string m_currentVersion;

    bool isTrustedURL(NSURL* url);
    void downloadFile(NSURL* url, void (^completion)(NSString* path, NSError* error));
    std::string sha256OfFile(NSString* path);
    bool applyUpdate(const std::string& newDylibPath);
    bool isVersionNewer(const std::string& remote, const std::string& local);
};
