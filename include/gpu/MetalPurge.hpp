#pragma once

namespace fndiag {

// Hooks setPurgeableState: on all concrete MTLResource subclasses to prevent
// IOGPU "setPurgeableState not supported for resource" spam on Mac Catalyst.
// Private/Memoryless resources don't support purgeable state; intercept those
// calls and return NonVolatile so the game sees a valid state without the
// IOGPU error path, which otherwise causes stalls and visual glitches.
void install_metal_purge();

} // namespace fndiag
