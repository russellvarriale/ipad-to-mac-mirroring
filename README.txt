iPad to Mac Mirroring 2.2.0
===========================
USB and wireless iPad screen mirroring in a capturable Mac window.
Apple Silicon; macOS 14 or later. Locally tested on macOS 26.

USB MIRRORING
1. Open iPad to Mac Mirroring.app, select USB at the top, and connect the iPad
   with a USB data cable.
2. Unlock the iPad and accept Trust if asked.
3. Select the iPad and click Connect. Allow Camera access when macOS
   asks; Apple presents the iPad screen as a capture source.
4. Resize the window. It maintains the iPad image's proportions.
5. Press Command-Shift-H for Clean View, which hides controls and the
   title bar. Press it again or right-click to restore the controls.
6. In the Loom desktop app, choose Record window and this viewer,
   enable your Mac camera bubble, and choose your microphone.

The control bar reports actual incoming pixel dimensions. View > Stream
Information explains the source formats. The viewer requests the largest
selectable video format; some iPads expose an automatic screen stream
whose resolution is negotiated by macOS. Enlarging the window adds no
detail. View > Fit Window to iPad (Command-0) restores a fitted window.

WIRELESS MIRRORING
1. Put the Mac and iPad on the same trusted Wi-Fi network.
2. Select Wi-Fi at the top. Wireless Setup appears as a side panel in
   this same window. Command-2 opens the sidebar.
3. Click Start Wireless. Allow Local Network access if macOS asks.
   The default receiver name is iPad to Mac Mirroring.
4. On the iPad, open Control Center > Screen Mirroring and select that
   receiver. Enter the connection code displayed in the sidebar.
5. The iPad screen appears in the main viewer. Hide Sidebar gives the
   video more space; Command-Shift-H hides all controls and the title bar.
   In Loom, select iPad to Mac Mirroring and enable your Mac camera/microphone.
6. Click Stop Wireless when finished. Switching to USB, closing the main
   window, or quitting also stops the receiver. Hiding the sidebar keeps
   wireless mirroring running.

USB and Wi-Fi share one video canvas and one Dock icon. Clean View,
Fit Window to iPad, and Always on Top work with either source. Select
one mode at a time; switching modes stops the previous source. The
wireless receiver stays in a bundled helper process and sends compressed
H.264 video through an inherited private channel. macOS displays it
inside the main window. No extra video window or Screen Recording
permission is needed by this app.

Both modes are video only. iPad app/game audio is muted; Loom handles
your webcam/narration. Use the iPad itself to interact with its apps.

Wireless requests 1920 x 1440 at 60 frames per second. The iPad negotiates
the actual resolution and frame rate. This can provide more detail than
the automatic USB stream on some iPads.

PRIVACY
The app has no account, analytics, cloud relay, or media recording.
It does not open the Mac webcam or microphone. Wireless listening starts
only when you start the receiver. The receiver display name is generic,
and its receiver identity changes on each Start. Local Bonjour discovery
still exposes network endpoints. A fresh connection code is required.

The password flow is a legacy AirPlay compatibility mechanism, suitable
for a trusted local network rather than a hostile network. See
SECURITY.txt and SECURITY-REVIEW.txt for the review, fixes, and limits.
No media or credentials are intentionally saved. Temporary per-run plugin
caches are deleted on normal stop; a crash may leave cache files in the
system temporary directory. macOS may save window position/permissions.
Your recording application's privacy behavior is separate.

TROUBLESHOOTING
USB: Unlock/trust the iPad, click Refresh, try a direct data cable, and
close other apps already using its USB feed. Check System Settings >
Privacy & Security > Camera if access was denied.

Wireless: Keep both devices on the same network with local discovery
available. Guest networks, VPN routing, and network isolation can prevent
Bonjour discovery. This receiver uses the local Wi-Fi network; Apple's
built-in Mac receiver can also appear through direct peer-to-peer discovery.
Select iPad to Mac Mirroring rather than the Mac's built-in receiver name.
Confirm Local Network access for this app. Stop and
restart the receiver after a network change. Close other receivers if
there is a conflict. Select the main iPad to Mac Mirroring in Loom.
Protected video apps can prevent screen mirroring.

BUILDING
The Swift app uses Apple's system frameworks. Wireless dependencies are
version-pinned and bundled with the built app; no Homebrew runtime is
required to run it. The native build requires Xcode/Command Line Tools,
CMake, Python 3, and Internet access to verified upstream downloads.
Use the native build instructions under scripts/, then run:
  ./build.sh "/path/to/output" "/path/to/Wireless"

The source build is ad-hoc signed for local use. A public binary release
should use Developer ID signing/notarization and include the applicable
third-party source/license materials. See THIRD-PARTY-NOTICES.txt.

PUBLIC SOURCE
Use the prepared source archive for GitHub. Do not upload the surrounding
chat workspace, personal screenshots, caches, or raw diagnostics. Source
retains the intended public author/project attribution, but excludes local
Git author configuration, Git history, private captures, and account paths.
Choose your intended public Git author email before the first commit. See SECURITY.txt.

LICENSE
Original app code, docs, and artwork: MIT. The UxPlay receiver and native
integration retain GPL-3.0-or-later; other dependencies retain their licenses.
The bundled application is not MIT-only. See LICENSES.md, COPYING.GPL-3.0,
and THIRD-PARTY-NOTICES.txt before distributing binaries.

REFERENCES
UxPlay: https://github.com/FDH2/UxPlay
GStreamer: https://gstreamer.freedesktop.org/
Loom window capture:
https://support.atlassian.com/loom/docs/get-started-with-the-loom-desktop-app/
Apple connected-iPad capture:
https://support.apple.com/guide/quicktime-player/record-a-movie-qtp356b55534/mac
