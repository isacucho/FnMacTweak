#include "fndiag/config.hpp"
#include "fndiag/hooks.hpp"
#include "fndiag/log.hpp"
#include "fndiag/objc_util.hpp"

#include <algorithm>
#include <mutex>
#include <set>
#include <string>

// Desbloqueo de FPS. El HUD de Fortnite en Mac marca ~29 FPS (intervalo de 34 ms): el juego pide
// 30 al sistema de pintado. Se fuerza la tasa pedida a fps_target en las tres APIs por las que
// una app iOS la fija. Si el juego tambien limita por dentro (configuracion, perfil de
// dispositivo), esto solo no basta: las lineas [FPS] dicen que llamadas hace.

namespace fndiag {
namespace {

using objc::sel;

struct FrameRateRange { // CAFrameRateRange: tres float, se pasa en registros (HFA)
    float minimum, maximum, preferred;
};

IMP g_set_pref = nullptr;   // -[CADisplayLink setPreferredFramesPerSecond:]
IMP g_set_range = nullptr;  // -[CADisplayLink setPreferredFrameRateRange:]
IMP g_mtk_pref = nullptr;   // -[MTKView setPreferredFramesPerSecond:]
IMP g_ui_max = nullptr;     // -[UIScreen maximumFramesPerSecond]

std::mutex g_mutex;
std::set<std::string> g_seen;

// Registra una sola vez cada combinacion distinta (el motor las repite en cada frame).
void note_once(const std::string &msg) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_seen.insert(msg).second)
        log_line("[FPS] %s", msg.c_str());
}

long hook_pref(id self, SEL cmd, long fps) {
    long target = config().fps_target;
    note_once("CADisplayLink setPreferredFramesPerSecond: " + std::to_string(fps) + " -> " + std::to_string(target));
    reinterpret_cast<void (*)(id, SEL, long)>(g_set_pref)(self, cmd, target);
    return 0;
}

void hook_range(id self, SEL cmd, FrameRateRange r) {
    auto orig = reinterpret_cast<void (*)(id, SEL, FrameRateRange)>(g_set_range);
    // Rango vacio (0/0/0): lo usa el sistema para "sin preferencia". CoreAnimation lanza una
    // excepcion con rangos invalidos, asi que se deja pasar tal cual.
    if (r.maximum <= 0.0f && r.preferred <= 0.0f) {
        orig(self, cmd, r);
        return;
    }
    float t = static_cast<float>(config().fps_target);
    note_once("CADisplayLink setPreferredFrameRateRange: " + std::to_string((int)r.minimum) + "/" + std::to_string((int)r.maximum) +
              "/" + std::to_string((int)r.preferred) + " -> " + std::to_string((int)t));
    // minimo valido: > 0 y <= objetivo
    float lo = r.minimum > 0.0f ? std::min(r.minimum, t) : std::min(30.0f, t);
    orig(self, cmd, FrameRateRange{lo, t, t});
}

void hook_mtk(id self, SEL cmd, long fps) {
    long target = config().fps_target;
    note_once("MTKView setPreferredFramesPerSecond: " + std::to_string(fps) + " -> " + std::to_string(target));
    reinterpret_cast<void (*)(id, SEL, long)>(g_mtk_pref)(self, cmd, target);
}

long hook_ui_max(id self, SEL cmd) {
    long orig = reinterpret_cast<long (*)(id, SEL)>(g_ui_max)(self, cmd);
    long v = std::max<long>(orig, config().fps_target);
    note_once("UIScreen maximumFramesPerSecond: " + std::to_string(orig) + " -> " + std::to_string(v));
    return v;
}

} // namespace

void install_fps_hooks() {
    if (!config().unlock_fps)
        return;
    bool a = objc::replace_instance_method("CADisplayLink", "setPreferredFramesPerSecond:", reinterpret_cast<IMP>(hook_pref), &g_set_pref);
    bool b = objc::replace_instance_method("CADisplayLink", "setPreferredFrameRateRange:", reinterpret_cast<IMP>(hook_range), &g_set_range);
    bool c = objc::replace_instance_method("MTKView", "setPreferredFramesPerSecond:", reinterpret_cast<IMP>(hook_mtk), &g_mtk_pref);
    bool d = objc::replace_instance_method("UIScreen", "maximumFramesPerSecond", reinterpret_cast<IMP>(hook_ui_max), &g_ui_max);
    log_line("[FPS] unlock_fps objetivo=%d: CADisplayLink.pref=%d range=%d MTKView=%d UIScreen.max=%d", config().fps_target, a, b, c, d);
}

} // namespace fndiag
