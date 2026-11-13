#pragma once
#include <cstdint>
#include <atomic>

namespace fndiag {

// Timestamp (mach_absolute_time units) of the last suppressed kick.
// Written by kicked_bypass_stub, read by bnf_bypass_stub to decide
// whether a ConnectionLost should be suppressed.
extern std::atomic<uint64_t> g_last_kick_suppressed_at;

void install_validation_patch();
void install_kick_bypass();

} // namespace fndiag
