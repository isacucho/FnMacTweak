#pragma once
#include <atomic>
#include <cstdint>

namespace fndiag {

// Set by kick_bypass_stub when it suppresses a ClientWasKicked RPC.
// NetFailurePatcher reads this to decide whether to suppress a ConnectionLost
// that follows within 500ms (server's UDP disconnect fallback after kick).
extern std::atomic<uint64_t> g_last_kick_suppressed_ns;

void install_kick_bypass();
} // namespace fndiag
