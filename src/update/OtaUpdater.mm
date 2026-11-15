#import "update/OtaUpdater.hpp"
#import "core/Logger.hpp"
#import "core/Config.hpp"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define TAG "OtaUpdater"

namespace {

NSError* makeError(NSString* msg) {
    return [NSError errorWithDomain:@"FnMacOtaUpdater" code:1
                          userInfo:@{NSLocalizedDescriptionKey: msg}];
}

std::vector<long> parseVersion(const std::string& v) {
    std::vector<long> parts;
    const char* p = v.c_str();
    while (*p) {
        char* end = nullptr;
        parts.push_back(strtol(p, &end, 10));
        if (end == p) break;
        p = (*end == '.') ? end + 1 : end;
    }
    return parts;
}

} // namespace

void OtaUpdater::setConfig(const std::string& manifestUrl,
                            const std::string& currentVersion) {
    m_manifestUrl    = manifestUrl;
    m_currentVersion = currentVersion;
}

void OtaUpdater::checkForUpdates() {
    if (!fndiag::config().autoupdate) {
        LOG_I(TAG, "autoupdate desactivado, omitiendo comprobacion");
        return;
    }
    if (m_manifestUrl.empty()) { LOG_E(TAG, "URL del manifiesto no configurada"); return; }
    LOG_I(TAG, "Comprobando actualizaciones desde: %s (version actual: %s)",
          m_manifestUrl.c_str(), m_currentVersion.c_str());

    NSURLSession* session = makeSession();
    NSURL* url = [NSURL URLWithString:[NSString stringWithUTF8String:m_manifestUrl.c_str()]];
    downloadFile(session, url, ^(NSString* downloadedPath, NSError* error) {
        if (error || !downloadedPath) {
            LOG_E(TAG, "Error descargando manifiesto: %s",
                  [(error ? [error localizedDescription] : @"ruta invalida") UTF8String]);
            [session finishTasksAndInvalidate];
            return;
        }
        NSData* data = [NSData dataWithContentsOfFile:downloadedPath];
        if (!data) {
            LOG_E(TAG, "No se pudo leer el manifiesto");
            [session finishTasksAndInvalidate];
            return;
        }
        NSError* jsonError = nil;
        NSDictionary* manifest = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:&jsonError];
        if (jsonError || ![manifest isKindOfClass:[NSDictionary class]]) {
            LOG_E(TAG, "Error al parsear JSON de actualizacion");
            [session finishTasksAndInvalidate];
            return;
        }

        NSString* latestVersion  = manifest[@"version"];
        NSString* downloadUrlStr = manifest[@"download_url"];
        NSString* expectedSha    = manifest[@"sha256"];

        if (![latestVersion isKindOfClass:[NSString class]] ||
            ![downloadUrlStr isKindOfClass:[NSString class]] ||
            ![expectedSha isKindOfClass:[NSString class]] ||
            [expectedSha length] != 64) {
            LOG_E(TAG, "Manifiesto invalido (faltan version, download_url o sha256)");
            [session finishTasksAndInvalidate];
            return;
        }

        std::string remoteVer = [latestVersion UTF8String];
        if (!isVersionNewer(remoteVer, m_currentVersion)) {
            LOG_I(TAG, "Ya en la ultima version (%s)", m_currentVersion.c_str());
            [session finishTasksAndInvalidate];
            return;
        }

        LOG_I(TAG, "Nueva version encontrada: %s. Descargando dylib...", remoteVer.c_str());
        NSURL* dylibUrl = [NSURL URLWithString:downloadUrlStr];
        downloadFile(session, dylibUrl, ^(NSString* dylibPath, NSError* dlError) {
            if (dlError || !dylibPath) {
                LOG_E(TAG, "Error descargando dylib: %s",
                      [(dlError ? [dlError localizedDescription] : @"ruta invalida") UTF8String]);
                [session finishTasksAndInvalidate];
                return;
            }
            std::string actualSha = sha256OfFile(dylibPath);
            if (actualSha != [[expectedSha lowercaseString] UTF8String]) {
                LOG_E(TAG, "SHA-256 no coincide (esperado %s, obtenido %s). Descartada.",
                      [expectedSha UTF8String], actualSha.c_str());
                unlink([dylibPath fileSystemRepresentation]);
                [session finishTasksAndInvalidate];
                return;
            }
            if (applyUpdate([dylibPath fileSystemRepresentation]))
                LOG_I(TAG, "Actualizacion %s lista para el proximo arranque.", remoteVer.c_str());
            else
                LOG_E(TAG, "Fallo al aplicar la actualizacion.");
            [session finishTasksAndInvalidate];
        });
    });
}

bool OtaUpdater::isTrustedURL(NSURL* url) {
    NSString* host = [[url host] lowercaseString];
    if (![[[url scheme] lowercaseString] isEqualToString:@"https"] || !host) return false;
    return [host isEqualToString:@"github.com"] ||
           [host hasSuffix:@".githubusercontent.com"];
}

NSURLSession* OtaUpdater::makeSession() {
    // Sesion efimera dedicada: aislada del sharedSession del juego.
    NSURLSessionConfiguration* cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest  = 30.0;
    cfg.timeoutIntervalForResource = 120.0;
    return [NSURLSession sessionWithConfiguration:cfg];
}

void OtaUpdater::downloadFile(NSURLSession* session, NSURL* url,
                               void (^completion)(NSString*, NSError*)) {
    if (!url || !isTrustedURL(url)) {
        completion(nil, makeError(@"URL no permitida (solo https a github.com)"));
        return;
    }
    NSURLSessionDownloadTask* task = [session downloadTaskWithURL:url
        completionHandler:^(NSURL* location, NSURLResponse* response, NSError* error) {
            if (error) { completion(nil, error); return; }
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? [(NSHTTPURLResponse*)response statusCode] : 0;
            if (status != 200) {
                completion(nil, makeError([NSString stringWithFormat:@"HTTP %ld", (long)status]));
                return;
            }
            NSString* dest = [NSTemporaryDirectory()
                stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
            NSError* fileError = nil;
            [[NSFileManager defaultManager] moveItemAtURL:location
                                                    toURL:[NSURL fileURLWithPath:dest]
                                                    error:&fileError];
            if (fileError) completion(nil, fileError);
            else           completion(dest, nil);
        }];
    [task resume];
}

std::string OtaUpdater::sha256OfFile(NSString* path) {
    NSData* data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (!data) return "";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([data bytes], (CC_LONG)[data length], digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return hex;
}

bool OtaUpdater::applyUpdate(const std::string& newDylibPath) {
    NSString* home = NSHomeDirectory();
    if (!home) {
        LOG_E(TAG, "NSHomeDirectory() devolvio nil");
        return false;
    }
    NSString* docs = [home stringByAppendingPathComponent:@"Documents"];
    NSFileManager* fm = [NSFileManager defaultManager];

    NSError* mkdirErr = nil;
    if (![fm createDirectoryAtPath:docs
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&mkdirErr]) {
        LOG_E(TAG, "No se pudo crear Documents/: %s",
              [[mkdirErr localizedDescription] UTF8String]);
        return false;
    }

    std::string stagePath = [docs UTF8String];
    stagePath += "/FnMacBypass-update.dylib";
    NSString* stageNS = [NSString stringWithUTF8String:stagePath.c_str()];
    [fm removeItemAtPath:stageNS error:nil];

    NSError* err = nil;
    if (![fm copyItemAtPath:[NSString stringWithUTF8String:newDylibPath.c_str()]
                    toPath:stageNS
                     error:&err]) {
        LOG_E(TAG, "No se pudo copiar update al container: %s",
              [[err localizedDescription] UTF8String]);
        return false;
    }
    chmod(stagePath.c_str(), 0755);
    LOG_I(TAG, "Update guardado en: %s", stagePath.c_str());
    LOG_I(TAG, "Para aplicar: cp '%s' <Frameworks>/FnMacBypass.dylib && bash tools/resign.sh",
          stagePath.c_str());
    return true;
}

bool OtaUpdater::isVersionNewer(const std::string& remote, const std::string& local) {
    std::vector<long> r = parseVersion(remote);
    std::vector<long> l = parseVersion(local);
    size_t n = std::max(r.size(), l.size());
    for (size_t i = 0; i < n; ++i) {
        long rv = i < r.size() ? r[i] : 0;
        long lv = i < l.size() ? l[i] : 0;
        if (rv != lv) return rv > lv;
    }
    return false;
}
