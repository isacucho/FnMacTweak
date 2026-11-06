#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include "core/Config.hpp"
#include "core/DiagLog.hpp"
#include "input/InputHooks.hpp"

namespace fndiag {
namespace {

void describe_devices(const char* when) {
    GCKeyboard* kb  = GCKeyboard.coalescedKeyboard;
    GCMouse*    ms  = GCMouse.current;
    NSArray<GCController*>* pads = GCController.controllers;
    log_line("[Input] %s: teclado=%s raton=%s mandos=%lu mice=%lu",
             when, kb ? "si" : "no", ms ? "si" : "no",
             (unsigned long)pads.count, (unsigned long)GCMouse.mice.count);
    for (GCController* c in pads)
        log_line("[Input]   mando: %s categoria=%s extended=%d",
                 c.vendorName.UTF8String ?: "?", c.productCategory.UTF8String ?: "?", c.extendedGamepad != nil);
}

} // namespace

void install_input_probe() {
    if (!config().probe_input) return;
    describe_devices("arranque");
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    struct Note { NSString* name; const char* label; } notes[] = {
        {GCKeyboardDidConnectNotification,        "teclado conectado"},
        {GCKeyboardDidDisconnectNotification,     "teclado desconectado"},
        {GCMouseDidConnectNotification,           "raton conectado"},
        {GCMouseDidDisconnectNotification,        "raton desconectado"},
        {GCControllerDidConnectNotification,      "mando conectado"},
        {GCControllerDidDisconnectNotification,   "mando desconectado"},
        {GCControllerDidBecomeCurrentNotification,"mando activo"}
    };
    for (const Note& n : notes) {
        const char* label = n.label;
        [nc addObserverForName:n.name object:nil queue:nil usingBlock:^(NSNotification*) {
            describe_devices(label);
        }];
    }
    GCKeyboard* kb = GCKeyboard.coalescedKeyboard;
    if (kb.keyboardInput) {
        __block bool seen = false;
        kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput*, GCControllerButtonInput*, GCKeyCode code, BOOL pressed) {
            if (!seen) {
                seen = true;
                log_line("[Input] primera tecla via GameController: code=%ld pressed=%d", (long)code, pressed);
            }
        };
    }
}

} // namespace fndiag
