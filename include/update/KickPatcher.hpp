#pragma once
#include <atomic>
#include <cstdint>

namespace fndiag {

// Set by kick_bypass_stub when it suppresses a ClientWasKicked RPC.
// NetFailurePatcher reads this to decide whether to suppress a ConnectionLost
// that follows within 500ms (server's UDP disconnect fallback after kick).
extern std::atomic<uint64_t> g_last_kick_suppressed_ns;

// Set by rejoin_scan_thread when it successfully calls RejoinViaSessionInternal.
// NetFailurePatcher checks this in the synthetic CT block to cancel lobby return.
extern std::atomic<bool> g_rejoin_attempted;

void install_kick_bypass();
void install_validation_patch();

} // namespace fndiag
