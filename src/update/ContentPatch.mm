/*
 * ContentPatch.mm - NSURLProtocol intercept para experience_br (v2.0.33)
 *
 * El endpoint cooked-content-package/link/experience_br devuelve HTTP 400 cuando
 * el servidor rechaza la combinacion platform=ios + major=43 en este build.
 * Eso causa que los assets de cosmeticos fallen al cargar durante la partida, y
 * al tercer fallo LogFortPerformance dispara NumLoadCustomizationFailed >= 3,
 * que saca al jugador del juego sin pasar por ClientWasKicked.
 *
 * Esta clase intercepta esas requests dentro de cada NSURLSession (inyectada via
 * protocolClasses en hook_session_factory de NetworkHooks.mm) y devuelve una
 * respuesta 200 sintetica con cuerpo JSON vacio. Resultado: el motor considera el
 * content link como exitoso (sin paquetes que cargar), no incrementa el contador
 * de fallos de customizacion, y el jugador permanece en la partida.
 */

#import <Foundation/Foundation.h>
#include "core/DiagLog.hpp"

@interface FnContentLinkProtocol : NSURLProtocol
@end

@implementation FnContentLinkProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *urlStr = [[request URL] absoluteString];
    return urlStr && [urlStr containsString:@"cooked-content-package/link/experience_br"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return NO;
}

- (void)startLoading {
    NSString *urlStr = [[[self request] URL] absoluteString];
    fndiag::log_line("[ContentPatch] experience_br intercepted -> synthetic 200 (url=%s)",
                     urlStr ? [urlStr UTF8String] : "(nil)");

    NSDictionary *headers = @{@"Content-Type": @"application/json; charset=utf-8"};
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:[[self request] URL]
        statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:headers];

    NSData *body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];

    [[self client] URLProtocol:self didReceiveResponse:response
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:body];
    [[self client] URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

namespace fndiag {

void install_content_patch() {
    // La clase queda disponible; la inyeccion real ocurre en hook_session_factory
    // de NetworkHooks.mm cuando el juego crea cada NSURLSession.
    fndiag::log_line("[ContentPatch] FnContentLinkProtocol lista (inyeccion via protocolClasses)");
}

} // namespace fndiag
