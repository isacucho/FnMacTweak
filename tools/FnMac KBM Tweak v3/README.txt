Fortnite on Mac: real keyboard and mouse
========================================

WARNING: Epic does not allow this on iOS and it is not hidden.
You can be removed from matches or banned. Use at your own risk.

Needs: Apple Silicon Mac, Fortnite 43.10 Tweaked IPA, FnMacAssistant, Sideloadly.

Install
1. Download the zip. You need the folder "FnMac KBM Tweak". If you only see
   the zip, double-click it and the folder appears.
2. Open the Terminal app (press Command + Space, type Terminal, press Enter).
3. Copy the whole line below and paste it into Terminal. It starts with
   "fnkbm" and ends with "NoFolderYet": leave out any ` marks around it.

fnkbm() ( IFS=; test $# = 0 && echo Drag the FnMac KBM Tweak folder here, then press Enter >&2 && read -r d && eval set -- $d; cd $1 2>/dev/null && test -f make-ipa.sh || exec echo That was not the FnMac KBM Tweak folder. Paste the line again and drag the folder in, not the zip >&2; bash make-ipa.sh >&2 ); fnkbm $NoFolderYet

4. Drag the "FnMac KBM Tweak" folder into the Terminal window. Press Enter.
   (If you pressed Enter before dragging, that is fine: drag the folder in
   now and press Enter again.)
5. Drag your Fortnite IPA file into the Terminal window. Press Enter.
   Wait about a minute until it says DONE.
6. Install the new file ending in _kbm.ipa with Sideloadly, as usual.

If the Mac asks to let Terminal use a folder, click Allow.
If you drag in the wrong thing, it tells you and lets you try again.
If Terminal ever shows a prompt like "else>" and just waits, press
Control + C and start again from step 3.

What you get
- Real keyboard and mouse in matches and menus. The cursor locks by itself
  in a match and comes back in menus.
- Fortnite's own "Keyboard Controls" page (every bind, like on PC).
- Fortnite's own "Mouse and Keyboard" page (sensitivity).
- Right click, wheel click and wheel up/down can be bound there. Mouse side
  buttons should bind there too.
- Caps Lock can be bound, as a tap only (it cannot be held).
- Command can be bound. It shows as "Insert" (left) and "Home" (right).
- Smooth mouse movement.
- Fortnite keeps running and stays connected when you switch to another app.
- Frame rate unlock: Fortnite's PC "Frame Rate Limit" row is in Video
  settings (30 to 360, or Unlimited), and the game follows it, menus too.
- Better graphics than the iPad settings allow. See CHANGELOG.txt.
- Mouse wheel and trackpad scroll menus from launch.
- Mac screenshots (Command + Shift + 3, 4, 5) work in a match.

About the frame rate unlock
- Your Mac runs hotter and louder with it, and uses more battery.
- A 120 Hz screen still shows 120 frames a second. The gain is less delay.
- If the game drops to 60 for a moment after you switch back to it, or while
  a notification is on screen, it clears by itself. A Focus mode stops
  notifications while you play.
- It was tested on one Mac only. If your game freezes, use the older
  "120 version" of this zip instead.

There are no tweak keys. Binds, sensitivity and frame rate are set in
Fortnite's own Settings. Resolution, start display, colour blind mode and the
graphics switches are in the Mac menu bar: FnMac, Graphics Panel. They are
saved, and most apply at the next start of Fortnite.
Binds and sensitivity from an older version of this tweak no longer apply:
set them again in Fortnite's Settings.
A few Joy-Con mouse rows may show in the mouse page: ignore them.

If no keys work in the game but the mouse does: in the lobby, open the menu
bar at the top, Fortnite, Settings. Turn "Touch Alternatives" off and set
"Controller Emulation" (under Game Control) to Off. Restart Fortnite.

If the mouse feels uneven: System Settings, Mouse, Advanced, turn
"Pointer acceleration" off.

What is in "files"
  FnMacTweak.dylib      the tweak (rebuilt FnMacTweak 5.0.0, MIT licence)
  fn_kbm_patch.py       patches your own copy of the game file
  game-43.10.diff       the list of changes it makes (Fortnite 43.10 only)
  source-changes.patch  every change made to the FnMacTweak 5.0.0 source
  LICENSE               FnMacTweak's licence
