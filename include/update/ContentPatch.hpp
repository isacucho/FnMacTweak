#pragma once

namespace fndiag {

// Intercepta requests a cooked-content-package/link/experience_br devolviendo
// HTTP 200 sintetico para prevenir que NumLoadCustomizationFailed >= 3
// dispare el performance exit que bypasea ClientWasKicked.
void install_content_patch();

} // namespace fndiag
