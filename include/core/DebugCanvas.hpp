#pragma once
#include <string>
#include <vector>

struct CanvasElement {
    std::string text;
    float x, y;
    uint32_t color;
};

// Overlay de depuracion en pantalla. Solo activo fuera de PRODUCTION.
// addText() encola elementos; render() los vuelca (stub: TODO integrar drawString).
class DebugCanvas {
public:
    static DebugCanvas& getInstance() {
        static DebugCanvas instance;
        return instance;
    }

    void addText(const std::string& text, float x, float y, uint32_t color = 0xFFFFFFFF) {
        m_elements.push_back({text, x, y, color});
    }

    void clear() { m_elements.clear(); }

    void render() {
        for (const auto& el : m_elements)
            (void)el; // TODO: integrar llamadas graficas reales
        clear();
    }

private:
    DebugCanvas() = default;
    std::vector<CanvasElement> m_elements;
};
