# FnMacTweak-kbm

A Theos tweak for Fortnite iOS running on Apple Silicon Macs, using the graphics UI from **FnMac KBM Tweak v3**. Start with a Fortnite executable already patched by that version’s patcher. This project builds the replacement tweak; it does not patch the executable.

## Settings

Open **FnMac → Graphics Panel** or **FnMac → Settings** in the macOS menu bar. Both open the same glass panel on the corresponding tab. Close it with its Close button, Escape, or a click outside the card. The card scales to fit smaller windows and respects Reduce Transparency and Reduce Motion.

**Graphics** retains v3’s controls and implementations:

- Starting display, automatic monitor discovery and reconnection updates, and a saved resolution for each display. Native resolution uses that display’s pixel scale.
- Shadow detail, grass and foliage, detail at distance, water, bloom/light shafts/post effects, sky and haze, wind, sharper textures at distance, menu background blur, high-resolution textures, and full 3D resolution.
- Deuteranope, Protanope, and Tritanope colour correction with strength 0–10, applied immediately.
- The original always-on cosmetic budgets, texture pools, sharp menu/shop images, and Metal resource purge compatibility fix.
- The patched game’s graphics-setting callback, explicit CVar values, high-resolution download preference, and Metal sampler mip bias. The patcher supplies the executable changes, including its anisotropic filtering and optional texture bundle changes.

Display, resolution, and graphics switches apply after restarting Fortnite. The panel lists pending changes. V3’s `fnkbm.*` graphics preferences are preserved.

**Settings** contains:

- Borderless Windowed, Unlock Frame Rate, and Run When Unfocused.
- Separate **Settings Shortcut** and **Graphics Panel Shortcut**, plus optional **Lock / Unlock Cursor**. Click a shortcut and press a key, optionally with Shift, Control, Option, or Command. Escape cancels capture. The × beside each binding clears it. Conflicting bindings are rejected.
- Select Fortnite Data Folder, with persistent security-scoped access for external drives. Restart after changing the folder.

Settings defaults to **P**; Graphics Panel and cursor locking default to **Not assigned**. A shortcut opens its tab, switches to it when another tab is open, and closes the panel when that tab is already selected. Menu-bar entries work even with every shortcut cleared. Existing lite preferences, including the Settings shortcut and folder bookmark, are retained. Settings opens once on first launch if it has not already been shown.

The frame-rate unlock retains the Metal and Unreal pacer hooks and v3’s adaptive recovery from compositor refresh-rate locks. Fortnite’s saved PC Frame Rate Limit remains authoritative, including Unlimited. The Fortnite 43.10 renderer stall workaround and graphics CVar injection use that patched executable’s known layout.

Cursor capture follows Fortnite’s menu/gameplay state automatically. The panel and focus loss release the cursor and held keys/buttons. Unlocked menu clicks use UIKit touches; gameplay uses native mouse buttons with duplicate touches suppressed. Mouse wheel and trackpad input uses the v3 patch’s pointer-position protocol to scroll under the cursor. Physical controller input passes through.

Gyro synthesis, virtual controllers, custom input remapping, HID mouse processing/smoothing, typing mode, settings import/export, and the tutorial video remain removed. Platform/device compatibility, marketplace callbacks, the availability fallback, dyld filtering, and responder threading fixes are retained.

## Build and install

Requirements: Xcode with an iOS SDK, Theos, and an Apple Silicon Mac.

```sh
make package FINALPACKAGE=1
```

The package is written to `packages/`. The library retains the name `FnMacTweak.dylib` for existing injection paths; the displayed name is **FnMacTweak-kbm**.

Replace the tweak in an IPA already prepared by the external v3 patcher:

```sh
tools/make-ipa.sh /path/to/Fortnite_kbm.ipa .theos/obj/FnMacTweak.dylib
```

The helper writes a separate `_kbm.ipa`, refuses existing output paths, and verifies the archive. It preserves the patched executable and all other IPA contents. Sign/install using your usual installer.

## Regression checks

```sh
python3 tests/graphics_backend_test.py
python3 tests/shortcut_test.py
python3 tests/panel_input_test.py
clang -Wall -Wextra -Werror tests/cursor_state_test.c -o /tmp/fn-kbm-cursor-test
/tmp/fn-kbm-cursor-test
clang -Wall -Wextra -Werror tests/mouse_routing_test.c -o /tmp/fn-kbm-mouse-test
/tmp/fn-kbm-mouse-test
```

The Objective-C checks run the actual source functions with mocked game/device objects on macOS. They do not replace live testing of graphics output, display switching, or native input in Fortnite.
