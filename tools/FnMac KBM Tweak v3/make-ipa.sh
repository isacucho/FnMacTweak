#!/bin/bash
# Makes a keyboard-and-mouse IPA from the Tweaked Fortnite IPA of FnMacAssistant.
# Usage: bash make-ipa.sh            (asks for the IPA)
#        bash make-ipa.sh <your.ipa> [tweak.dylib]
# Your IPA is not changed. The result is written next to it as <name>_kbm.ipa.
set -euo pipefail
VERSION="16 Nov (bundle9)"
HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRY="Payload/FortniteClient-IOS-Shipping.app/Frameworks/FnMacTweak.dylib"
say() { printf '\n%s\n' "$*"; }
stop() { printf '\nSTOPPED: %s\n\n' "$*"; exit 1; }

# Prints why a file cannot be used. Prints nothing when the file is fine.
problem() {
  local f="$1"
  if [ -z "$f" ]; then echo "Nothing was dragged in."
  elif [ -d "$f" ]; then echo "That is a folder. Drag in the Fortnite file ending in .ipa."
  elif [ ! -e "$f" ]; then echo "Cannot find this file: $f"
  elif [ "${f%.ipa}" = "$f" ]; then echo "That is not an .ipa file: $(basename "$f")"
  elif [ "${f%_kbm.ipa}" != "$f" ]; then echo "That file was made by this tool. Drag in your original Fortnite IPA (the name does not end in _kbm)."
  elif ! head -c 4 "$f" >/dev/null 2>&1; then echo "Terminal is not allowed to read that file. Open System Settings, Privacy & Security, Files and Folders, Terminal, and switch on the folder the file is in."
  elif ! unzip -l "$f" "$ENTRY" >/dev/null 2>&1; then echo "That IPA has no FnMacTweak in it. Use the Tweaked IPA from FnMacAssistant."
  fi
}

[ -f "$HERE/files/fn_kbm_patch.py" ] && [ -f "$HERE/files/game-43.10.diff" ] || stop "This folder is not complete. Download the zip again."
if ! python3 -I -c "" >/dev/null 2>&1; then
  echo
  echo "Your Mac needs Apple's developer tools first (free, from Apple)."
  echo "A window from Apple should be open now: click Install, wait until it is done."
  echo "If no window shows, paste this and press Enter:   xcode-select --install"
  stop "Install the developer tools, then paste the command again."
fi

SRC="${1:-}"
if [ -z "$SRC" ]; then
  echo
  echo "=============================================="
  echo " Fortnite keyboard and mouse: make the IPA"
  echo " Version: $VERSION"
  echo "=============================================="
  TRIES=0
  while :; do
    echo
    echo "STEP 1 of 3"
    echo "Drag your Fortnite IPA file from Finder into this window."
    echo "It is the file you install with Sideloadly. Its name ends in .ipa,"
    echo "for example Fortnite-43.10_Tweaked.ipa. It is usually in Downloads."
    echo "Then press Enter."
    echo
    printf '> '
    IFS= read -r SRC || stop "No file given. Paste the command again."
    # A dragged file arrives with quotes or backslashes; remove them.
    SRC="$(printf '%s' "$SRC" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^'\\(.*\\)'\$/\\1/" -e 's/^"\(.*\)"$/\1/' -e 's/\\\(.\)/\1/g')"
    P="$(problem "$SRC")" || true
    if [ -z "$P" ]; then break; fi
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge 5 ]; then stop "$P"; fi
    echo
    echo "NOT RIGHT: $P"
    echo "Try again."
  done
else
  P="$(problem "$SRC")" || true
  [ -z "$P" ] || stop "$P"
fi
IN="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
D="${2:-files/FnMacTweak.dylib}"
case "$D" in /*) DYLIB="$D" ;; *) DYLIB="$HERE/$D" ;; esac
OUT="${IN%.ipa}_kbm.ipa"
[ -f "$DYLIB" ] || stop "This folder is not complete. Download the zip again."

say "STEP 2 of 3"
if [ -e "$OUT" ]; then
  echo "An older result is there already. It is replaced with the new one."
  rm -f "$OUT"
fi
echo "Making the new IPA. This takes about a minute. Please wait..."
LOG="$(mktemp)"; W="$(mktemp -d)"; trap 'rm -rf "$W" "$LOG"' EXIT
if ! python3 -I "$HERE/files/fn_kbm_patch.py" patch "$IN" "$OUT" >"$LOG" 2>&1; then
  rm -f "$OUT"
  echo; tail -5 "$LOG"
  stop "The game file could not be patched. This is made for Fortnite 43.10. Check too that the Mac has 3 GB of free space."
fi
mkdir -p "$W/$(dirname "$ENTRY")"
cp "$DYLIB" "$W/$ENTRY"
(cd "$W" && zip -q "$OUT" "$ENTRY")
if ! python3 -I "$HERE/files/fn_kbm_patch.py" check "$OUT" >"$LOG" 2>&1 || grep -q "unpatched" "$LOG"; then
  echo; cat "$LOG"
  rm -f "$OUT"
  stop "The new IPA did not pass its check, so it was removed."
fi

say "DONE. Your new file is:"
echo "  $OUT"
say "STEP 3 of 3: install it"
echo "  1. Open Sideloadly."
echo "  2. Drag the file ending in _kbm.ipa into Sideloadly."
echo "     (A Finder window is opening now with that file selected.)"
echo "  3. Click Start, with the same Apple ID as usual."
echo "  4. Run the FnMacAssistant patch like you normally do."
echo "  5. Open Fortnite. If it closes, open it again a few times."
say "In the game: binds and sensitivity are in Fortnite's own Settings."
echo "There are no tweak keys: the cursor locks by itself in a match."
echo "Set your frame rate in Fortnite's Video settings, Frame Rate Limit."
echo "Unlimited means more heat and fan noise."
echo
[ -n "${FNKBM_NO_OPEN:-}" ] || open -R "$OUT" 2>/dev/null || true
