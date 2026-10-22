#import "Updater.hpp"
#import "Logger.hpp"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define TAG "Updater"

namespace {

NSError *makeError(NSString *msg) {
    return [NSError errorWithDomain:@"FnFixUpdater" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

std::vector<long> parseVersion(const std::string& v) {
    std::vector<long> parts;
    const char *p = v.c_str();
    while (*p) {
        char *end = nullptr;
        parts.push_back(strtol(p, &end, 10));
        if (end == p)
            break; // texto no numerico: se corta aqui
        p = (*end == '.') ? end + 1 : end;
    }
    return parts;
}

} // namespace

void Updater::setUpdateConfig(const std::string& manifestUrl, const std::string& currentVersion) {
    m_manifestUrl = manifestUrl;
    m_currentVersion = currentVersion;
}

void Updater::checkForUpdates() {
    if (m_manifestUrl.empty()) {
        LOG_E(TAG, "URL del manifiesto no configurada.");
        return;
    }

    LOG_I(TAG, "Comprobando actualizaciones desde: %s (version actual: %s)", m_manifestUrl.c_str(), m_currentVersion.c_str());

    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:m_manifestUrl.c_str()]];

    downloadFile(url, ^(NSString *downloadedPath, NSError *error) {
        if (error || !downloadedPath) {
            LOG_E(TAG, "Error descargando el manifiesto: %s", [(error ? [error localizedDescription] : @"ruta invalida") UTF8String]);
            return;
        }

        NSData *data = [NSData dataWithContentsOfFile:downloadedPath];
        if (!data) {
            LOG_E(TAG, "No se pudo leer el manifiesto descargado.");
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

        if (jsonError || ![manifest isKindOfClass:[NSDictionary class]]) {
            LOG_E(TAG, "Error al parsear el JSON de actualizacion.");
            return;
        }

        NSString *latestVersion = manifest[@"version"];
        NSString *downloadUrlStr = manifest[@"download_url"];
        NSString *expectedSha = manifest[@"sha256"];

        if (![latestVersion isKindOfClass:[NSString class]] || ![downloadUrlStr isKindOfClass:[NSString class]] ||
            ![expectedSha isKindOfClass:[NSString class]] || [expectedSha length] != 64) {
            LOG_E(TAG, "Manifiesto invalido (faltan version, download_url o sha256).");
            return;
        }

        std::string remoteVer = [latestVersion UTF8String];
        if (!isVersionNewer(remoteVer, m_currentVersion)) {
            LOG_I(TAG, "El modulo ya esta en la ultima version (%s).", m_currentVersion.c_str());
            return;
        }

        LOG_I(TAG, "Nueva version encontrada: %s. Descargando dylib...", remoteVer.c_str());
        NSURL *dylibUrl = [NSURL URLWithString:downloadUrlStr];
        downloadFile(dylibUrl, ^(NSString *dylibPath, NSError *dlError) {
            if (dlError || !dylibPath) {
                LOG_E(TAG, "Error descargando la nueva dylib: %s", [(dlError ? [dlError localizedDescription] : @"ruta invalida") UTF8String]);
                return;
            }

            std::string actualSha = sha256OfFile(dylibPath);
            if (actualSha != [[expectedSha lowercaseString] UTF8String]) {
                LOG_E(TAG, "SHA-256 no coincide (esperado %s, obtenido %s). Actualizacion descartada.", [expectedSha UTF8String], actualSha.c_str());
                unlink([dylibPath fileSystemRepresentation]);
                return;
            }

            if (applyUpdate([dylibPath fileSystemRepresentation])) {
                LOG_I(TAG, "Actualizacion %s preparada. Se usara en el proximo arranque.", remoteVer.c_str());
            } else {
                LOG_E(TAG, "Fallo al aplicar la actualizacion.");
            }
        });
    });
}

bool Updater::isTrustedURL(NSURL* url) {
    NSString *host = [[url host] lowercaseString];
    if (![[[url scheme] lowercaseString] isEqualToString:@"https"] || !host)
        return false;
    return [host isEqualToString:@"github.com"] || [host hasSuffix:@".githubusercontent.com"];
}

void Updater::downloadFile(NSURL* url, void (^completion)(NSString* downloadedPath, NSError* error)) {
    if (!url || !isTrustedURL(url)) {
        completion(nil, makeError(@"URL no permitida (solo https a github.com)"));
        return;
    }

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                completion(nil, error);
                return;
            }

            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            if (status != 200) {
                completion(nil, makeError([NSString stringWithFormat:@"HTTP %ld", (long)status]));
                return;
            }

            NSString *tempDir = NSTemporaryDirectory();
            NSString *destinationPath = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];

            NSError *fileError = nil;
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:destinationURL error:&fileError];

            if (fileError) {
                completion(nil, fileError);
            } else {
                completion(destinationPath, nil);
            }
        }];

    [task resume];
}

std::string Updater::sha256OfFile(NSString* path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data)
        return "";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([data bytes], (CC_LONG)[data length], digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return hex;
}

// Deja la dylib nueva en su sitio sin tocar la actual hasta el ultimo paso:
// copia a <actual>.new (mismo directorio, rename atomico), guarda <actual>.bak
// y renombra. Un fallo en cualquier paso deja la dylib vigente intacta.
bool Updater::applyUpdate(const std::string& newDylibPath) {
    Dl_info info;
    if (dladdr((const void*)&Updater::getInstance, &info) == 0 || !info.dli_fname) {
        LOG_E(TAG, "No se pudo determinar la ruta local de la dylib actual.");
        return false;
    }

    std::string current = info.dli_fname;
    std::string staged = current + ".new";
    std::string backup = current + ".bak";
    LOG_I(TAG, "Reemplazando dylib en: %s", current.c_str());

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stagedNS = [NSString stringWithUTF8String:staged.c_str()];
    NSString *backupNS = [NSString stringWithUTF8String:backup.c_str()];
    NSString *currentNS = [NSString stringWithUTF8String:current.c_str()];
    [fm removeItemAtPath:stagedNS error:nil];
    [fm removeItemAtPath:backupNS error:nil];

    NSError *err = nil;
    if (![fm copyItemAtPath:[NSString stringWithUTF8String:newDylibPath.c_str()] toPath:stagedNS error:&err] ||
        ![fm copyItemAtPath:currentNS toPath:backupNS error:&err]) {
        LOG_E(TAG, "No se pudo preparar la actualizacion: %s", [[err localizedDescription] UTF8String]);
        [fm removeItemAtPath:stagedNS error:nil];
        return false;
    }
    chmod(staged.c_str(), 0755);

    if (rename(staged.c_str(), current.c_str()) != 0) {
        LOG_E(TAG, "rename fallo (errno %d). Dylib actual intacta.", errno);
        [fm removeItemAtPath:stagedNS error:nil];
        return false;
    }
    return true;
}

bool Updater::isVersionNewer(const std::string& remoteVersion, const std::string& localVersion) {
    std::vector<long> remote = parseVersion(remoteVersion);
    std::vector<long> local = parseVersion(localVersion);
    size_t n = std::max(remote.size(), local.size());
    for (size_t i = 0; i < n; ++i) {
        long r = i < remote.size() ? remote[i] : 0;
        long l = i < local.size() ? local[i] : 0;
        if (r != l)
            return r > l;
    }
    return false;
}
