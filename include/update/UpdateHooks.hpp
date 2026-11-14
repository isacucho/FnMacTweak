#pragma once

namespace fndiag {

// Hooks sobre FBackgroundNSURLSession (clase del motor): registra SetDownloadResult /
// GetDownloadResult y con Config::patch_status corrige 201 -> 200.
void install_engine_hooks();

} // namespace fndiag
