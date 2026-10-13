# Cirro Mail

A multi-instance Flutter client for [cloud-mail](https://github.com/maillab/cloud-mail) —
one codebase for Android, iOS, macOS, Windows and Linux.

**English** · [简体中文](README.zh-CN.md)

The display name is **Cirro Mail** on every platform and language. The transparent icon
master lives at `assets/branding/cirro-mail-master.png`; iOS icons are exported as opaque
white-background PNGs (a platform requirement), while Android, macOS, Windows and Linux use
transparent icons or a transparent foreground layer. Android ships five variants each of
legacy, round and adaptive icons; Linux provides nine sizes of desktop theme icons
(16–512 px). `mail_app` remains the Dart package name and the desktop executable name.

It **does not modify `mail-worker`** — it only talks to the existing HTTP API. The companion
push relay Worker (`mail-push`) lives in the same upstream repository; this project only
speaks to its HTTP interface.

## What it adds over the web client

- **Multiple instances**: keep your own self-hosted instance and one a friend gave you side
  by side, each with its own login (and its own token). **All instances receive mail
  simultaneously**, merged into a single aggregated timeline; you can also filter down to
  just one.
- **Native push**: incoming external mail can land in your phone's notification tray, and
  tapping the notification jumps straight to that message. It goes
  self-hosted relay Worker → FCM → Android / iOS (APNs). **No** ports need to be exposed on
  your instance.
- **Attachments**: download, open in a system app, share, **in-app preview** (images / PDF /
  text / Markdown / CSV / docx / xlsx / pptx / audio / video), save-as, plus cache usage
  inspection and cleanup. The three Office formats are parsed **locally in pure Dart** —
  the file never leaves your machine (see below).
- **Large attachment sending**: the request body is assembled as a stream, with attachments
  encoded from disk in chunks, so process memory is never blown up by base64 (see below).
- **Capability-based degradation**: against an older instance missing a feature, that piece
  hides or degrades gracefully instead of erroring out.
- **Local cache**: mail lists and bodies are stored in a local SQLite database (drift), so
  you can browse mail you have already seen while offline.

## Quick start

Requires Flutter **3.47.7** (Dart 3.13.5; the dependency versions in `pubspec.yaml` were
checked one by one against this version — see "Why these dependency versions" below).

```bash
flutter pub get
flutter run -d <device>
```

On first launch you will be asked for a **server address** (for self-hosting, your own
`https://<your-domain>/api`; the field starts empty with an `https://example.com/api`
placeholder) → connectivity test → login. Only after logging in can you add a second instance.

## Building

```bash
flutter build apk --debug        # Android
flutter build ios --no-codesign  # iOS (signing needs your own account)
flutter build macos --debug
flutter build windows            # must run on Windows
flutter build linux              # must run on Linux
```

`android/app/google-services.json` **is not in the repository**, and its absence does not
break the build — `android/app/build.gradle.kts` checks whether it exists and, if not, skips
the Google Services plugin and prints a notice. You get no push, but everything else works.

## Package name / Bundle ID

The package name is `com.zenkee.mailapp`. **The package name you enter in the Firebase
console must match it character for character**, otherwise dropping in
`google-services.json` still won't take effect (Android will **fail the build outright**
with `No matching client found for package name`; on the Apple side it fails at runtime with
no default app):

| Platform | Identifier | Where to change it |
|---|---|---|
| Android | `com.zenkee.mailapp` | `android/app/build.gradle.kts` `applicationId` / `namespace`; sources under `android/app/src/main/kotlin/com/zenkee/mailapp/` |
| iOS | `com.zenkee.mailapp` | `ios/Runner.xcodeproj/project.pbxproj` |
| macOS | `com.zenkee.mailapp` | `macos/Runner/Configs/AppInfo.xcconfig` |
| Linux | `com.zenkee.mailapp` | `linux/CMakeLists.txt` `APPLICATION_ID` |
| Windows | `com.zenkee.mailapp` | `windows/runner/Runner.rc` `CompanyName` (the copyright holder is the company name ZENKEE LLC) |

All five platforms use `com.zenkee.mailapp`. **Apple does not allow underscores in bundle
IDs** — registering an App ID / App Store Connect accepts only letters, digits, hyphens and
dots, so `ke.dong.mail_app` is rejected outright (a local Xcode build also prints
`invalid character in Bundle Identifier`); hence the concatenated form rather than `mail_app`.

The `-RunnerTests` occurrences (`com.zenkee.mailapp.RunnerTests`) are the test target's
bundle ID and were changed along with the rest.

⚠️ **`name: mail_app` at the top of `pubspec.yaml` is not the package name — leave it
alone.** That is the Dart package name; every `import 'package:mail_app/...'` depends on it,
and it is entirely unrelated to the app identifier.

Also, `cloudmail.periodicSync` / `cloudmail.sync` are **workmanager task identifiers**,
unrelated to the package name. Changing them requires four synchronized edits (the two
constants in `background_sync_task.dart`, `AppDelegate.swift`, and `BGTaskSchedulerPermittedIdentifiers`
in `Info.plist`); miss one and background tasks silently stop running, so **they were
deliberately left alone** — it is just an identifier, not something exposed externally.

## Firebase configuration files (already in place)

| Platform | File | Location | Who reads it |
|---|---|---|---|
| Android | `google-services.json` | `android/app/` | The Google Services Gradle plugin (compiles it into resource constants such as `google_app_id`) |
| iOS | `GoogleService-Info.plist` | `ios/Runner/`, **already registered in the Xcode project** | `firebase_core` looks it up in the bundle at startup |
| macOS | `GoogleService-Info.plist` | `macos/Runner/`, **already registered in the Xcode project** | Same as above — macOS uses **the same** plist as iOS (its `BUNDLE_ID` matches the macOS bundle ID, so no separate macOS app is needed) |

The `BUNDLE_ID` / `package_name` in all three files must be `com.zenkee.mailapp`, and that
is also what you must enter when creating the app in the Firebase console. All three are
committed to the repository — they are publicly embeddable client identifiers (this is by
FCM's design, with the same secrecy level as `google_app_id`), but when switching Firebase
projects you must swap all three platforms together.

⚠️ **After downloading the iOS plist from the Firebase console, check `BUNDLE_ID`.** This
project's copy downloaded as `con.zenkee.mailapp` (missing the m) and was corrected by hand.

**Dropping the plist into the directory is not enough** — it must appear in the target's
**Copy Bundle Resources** build phase to be packed into the `.app`, otherwise
`Firebase.initializeApp()` fails at runtime with `could not find default app`. This is
currently done by hand-editing `project.pbxproj` (four registrations: `PBXBuildFile`, `PBXFileReference`,
the containing group, and the Resources phase), not by clicking in Xcode.

## What you must configure yourself for push

**The step-by-step manual is [`docs/push-setup.md`](docs/push-setup.md)** (the app's
"Settings → Background push" is its in-app version — a **seven-page step-by-step wizard**:
① status / ② three values / ③ toggle / ④ register / ⑤ instance backend / ⑥ check / ⑦ notes
and limits). Below is the three-line summary of this section.

None of this can live in code; each is an external configuration:

1. ~~Create a Firebase project, drop in the config files~~ — **already done** (see the
   previous section; all three are in the repository).
2. **Deploy `mail-push` and configure the FCM service account** — see section 4 of
   [`docs/push-setup.md`](docs/push-setup.md). The relay address pre-filled in the app is
   <https://push.zenkee.com> (self-hosters can point it at their own); the service account
   private key is uploaded by the deployer themselves via
   `npx wrangler secret put FCM_SERVICE_ACCOUNT` (the whole JSON string — don't add a
   same-named variable to `[vars]` in `wrangler.toml`; a name collision makes `secret put`
   fail outright).
3. **In the app**, fill in the relay address (`https://push.zenkee.com` by default) + instance
   slot + pairing code (wizard page ②). The pairing code **is also** the webhook secret to
   enter in the instance backend; wizard page ⑤ displays it for copying.
4. **In the instance backend** (the "Webhook push" section), enter the webhook URL given on
   page ⑤ (with its `/<slot>/webhook` tail) and the secret, and flip that section's toggle
   on. This is the only thing that must be done on the instance side — **note that this
   toggle is stored in the database as `webhookStatus`, where `0` means "enabled"**, the
   opposite of intuition, so it is always the first suspect when "the URL and secret are
   both right but nothing arrives".

### Things that still must be done in Xcode / the Apple developer portal

- **iOS Push Notifications capability**: the `aps-environment` entitlement is already
  written into `ios/Runner/Runner.entitlements` and wired to all three build configurations,
  but for this entitlement to take effect you need a matching provisioning profile (**from
  your own Apple developer account — substitute your Team ID**). On the first device run,
  Xcode will request one carrying APS — this requires the account to be signed in and push
  to have been enabled on the App ID.
- **macOS Push Notifications capability**: it uses **a different key name** than iOS. macOS
  needs `com.apple.developer.aps-environment` (with the `com.apple.developer.` prefix,
  written in `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`, `development`
  for Debug and `production` for Release); the bare `aps-environment` in the iOS file is
  ignored by codesign on a native Mac app. You also need a **Mac** provisioning profile with
  push — once the App ID toggle is on, Xcode automatic signing requests a
  `Mac Team Provisioning Profile: com.zenkee.mailapp` itself (under
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`). Missing the profile fails the
  build outright: `Provisioning profile ... doesn't include the Push Notifications capability`;
  missing the entitlement lets the build pass, but `getToken()` throws `apns-token-not-set`
  — **unrelated to notification permission**, so don't go looking in System Settings.
- **Upload an APNs key/certificate for the iOS app in the Firebase console** (Project
  settings → Cloud Messaging → APNs Authentication Key). Uploading the Firebase service
  account solves "can the relay call FCM"; this one solves "can FCM deliver to APNs" — two
  different things.
- **Turn on the Push Notifications switch for the App ID in the Apple developer portal**
  (the `com.zenkee.mailapp` App ID — iOS and macOS share it).
- **A distributed macOS build also needs a Developer ID provisioning profile.** Right now
  `Release.entitlements` says `production`, but **this machine only has the development Mac
  profile, so the built artifact still embeds `development`** (visible via
  `codesign -d --entitlements -`) — it builds and registers, but that is the development
  APNs environment; running Release locally is fine, but shipping it to others won't deliver.
  Before distributing / publishing, create a Developer ID provisioning profile in the portal
  so the artifact actually becomes `production`.

### macOS signing: `CODE_SIGN_IDENTITY` must change along with the team

The **project-level** configuration in `macos/Runner.xcodeproj` has `CODE_SIGN_IDENTITY = "-"`
(adhoc signing). Setting `DEVELOPMENT_TEAM = <your Team ID>` only on the target is
**useless** — the artifact remains `Signature=adhoc`, `TeamIdentifier=not set`. You must also
override `CODE_SIGN_IDENTITY = "Apple Development"` in all three target configurations
(Debug / Release / Profile) for the artifact to carry the team (the three `DEVELOPMENT_TEAM`
entries in the repository are currently `""` and will be filled automatically once you pick
your Team in Xcode):

```
$ codesign -dv build/macos/Build/Products/Debug/mail_app.app | grep Team
TeamIdentifier=<your Team ID>      # was not set before
```

You can also run locally without this step (adhoc signing works on your own machine); the
difference only shows up when distributing or using a profile with the APS entitlement.

### macOS sandbox: `com.apple.security.network.client` is required

The macOS entitlements generated by `flutter create` contain **only `network.server`** (that
is for the Dart VM debug service); outbound `network.client` must be added by hand. Without
it, every HTTP request under the sandbox fails with `errno 1 (Operation not permitted)` — and
this client is entirely network-dependent.

This is not "just to be safe": it was measured on this machine with a minimal app doing a
single `connect()` — sandbox + no `network.client` → `CONNECT FAIL errno=1`; with it added →
`CONNECT OK`; without the sandbox → `CONNECT OK`. Both Debug and Release entitlement files
have it added.

There is a **self-check** button in Settings: it takes the pairing code and asks the relay
"how should the instance backend be configured", comparing it against the address you have
entered — a wrong address is a **silent failure** (the instance only calls the webhook when
external mail actually arrives, and a failed call leaves just one line in its own log), so
this step is worth clicking. In the wizard it is page ⑥, "check this link" (the former "test
connection" and "self-check" have been merged into this one).

⚠️ The webhook covers **external incoming mail only**. Mail sent within the instance, or by
another client, does not trigger it — only polling catches those. If the instance has
`ruleType=RULE`, the webhook does not fire at all.

### macOS: the app stays alive in the menu bar after closing the window

Clicking the red close button on macOS **does not quit**. `applicationShouldTerminateAfterLastWindowClosed`
returns `false`, so the process keeps running after the window closes: an envelope icon stays
in the menu bar, its menu has "Open main window / Quit Cirro Mail", and clicking the Dock
icon or Cmd-Tabbing back brings the window back. To quit, quit explicitly (menu bar menu,
`Cmd+Q`, right-click the Dock icon).

This is a **prerequisite for continuous mail retrieval**, not a decorative addition. The
desktop process was always alive, but "quit on close" meant polling stopped the moment you
closed the window, and that gap was covered only by FCM — and FCM covers **external mail
only** (mail sent within the instance or by another client triggers no webhook). So the most
ordinary usage, "close the window and wait for a colleague to send a message from another
client", went completely silent. The fix: after closing the window, mail keeps arriving at
the interval set in Settings, with notifications as usual.

Three implementation pitfalls, documented in `macos/Runner/AppDelegate.swift`:

- **Do not call `super` in `applicationDidFinishLaunching`.** In this version of the project,
  that `FlutterAppDelegate` method does not return (measured: call it first and not a single
  line of the code that builds the menu bar icon executes; the UI symptom is "stuck at
  launch"). The startup work the engine needs is already done in `applicationWillFinishLaunching`.
- **The window needs its own strong reference.** `FlutterAppDelegate.mainFlutterWindow` is a
  **weak** IBOutlet and can go nil when the window closes. The window in the nib has
  `releasedWhenClosed="NO"`, so holding your own reference is enough.
- **After closing the window, you must explicitly hold off App Nap.** A process with no
  window and nobody watching is exactly what App Nap wants to throttle, and the symptom is
  "after closing the window, mail only arrives every ten-odd minutes". When the window is not
  visible, `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep)`, and
  `endActivity` when it comes back. This option rather than `.userInitiated` is used because
  the latter also blocks **system** idle sleep (the lid closing won't sleep either), which is
  not worth it just to fetch mail.

The corresponding item on the Dart side: `SyncController._onPause` **returns immediately** on
desktop, doing nothing. Without this, closing the window produces
`AppLifecycleState.hidden`, and the next successful sync necessarily writes `lastSyncAt` in
the `profiles` table → triggers a `build()` recompute → takes the branch that stops the
scheduler. **Close the window and mail retrieval dies silently**, while the menu bar icon
stays lit and the user simply assumes it is running in the background. This regression is
pinned by `test/desktop_sync_keepalive_test.dart` (which also pins the Android branch so it
isn't broken by accident).

One more path that can only be verified by hand: when you tap a system notification, the
system activates the app but **does not carry iOS's "which message" semantics**, so nothing
happens on screen. The native `applicationShouldHandleReopen` (Dock click) and
`applicationDidBecomeActive` (app activated) cannot cover this because navigation lives in
Dart. So a `com.zenkee.mailapp/window` channel was added
(`lib/core/storage/window_channel.dart` ↔ `AppDelegate.setUpWindowChannel`), and Dart wakes
the window before navigating.

**Only one process runs.** The reason is exactly the same as the Windows item below (after
closing the window the app can't be found on screen, so launching it again is perfectly
reasonable), but macOS has more entry points than Windows and they are better hidden — it
takes a **two-part** mechanism here, and missing one lets a second process leak through from
some entry point (the trade-offs are spelled out in the header of
`macos/Runner/SingleInstance.swift`):

- **The LaunchServices half relies on `Info.plist`'s `LSMultipleInstancesProhibited`.** Dock
  clicks, double-clicks in the Library / Finder, `open`, and `open -n` are all handled by it:
  a second launch does not start a process, it forwards "open again" to the running copy
  (landing in `applicationShouldHandleReopen`). `LSUIElement` is deliberately **not** added —
  that would take away the Dock icon too, and clicking the Dock is the existing path that
  brings the window back.
- **The half for running the executable directly from a terminal is written by hand.**
  `flutter run` starts this way (flutter_tools uses `open`, but running the binary by hand
  while debugging, and `open -n`, both bypass LaunchServices), which the plist cannot govern;
  this half uses `flock(2)`: the lock file is under
  `~/Library/Application Support/cirro-mail/` (inside the container under the sandbox,
  naturally per-user isolated), and if the lock cannot be acquired it asks the other instance
  to raise its window and then exits. The lock follows the file descriptor and is released by
  the kernel the moment the process dies, so there are no stale locks to clean up — and
  `NSDistributedLock` is not used either (Apple itself advises against using it as a
  singleton lock, and it leaves a dirty file behind after a crash).
- **Waking the other instance needs two paths.** The primary path is
  `NSRunningApplication.activate(options: [.activateAllWindows])`; but **after the window is
  closed the app is still "the frontmost one"**, and in that state `activate` returns true
  yet not a single callback arrives on the other side, so a distributed notification is added
  as backup. It must be delivered with
  `CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), …)` —
  posting to the same center via `NSDistributedNotificationCenter.postNotificationName` is
  **silently** blocked by the sandbox (one line of `thwarted by sandboxing` on stderr, and
  `try?` hides everything); merely **observing** this notification needs no entitlement.
- **The window is changed to `visibleAtLaunch="NO"`, and the first frame is released
  explicitly after the guard passes.** This is because `MainMenu.xib` is loaded during the
  top-level code phase of `NSApplicationMain`, about 100 ms before the guard in
  `applicationDidFinishLaunching`; without turning it off, the second process flashes a
  window and then disappears. And the guard can only live there: it cannot move up (the nib
  and engine are already built), and moving it down means "show the window first, then exit".

A few trade-offs that differ from Windows: `Local\` ↔ in-container paths (both are per-user
isolated, so no machine-wide `/tmp` / `Global\`); and "treat a failed lock acquisition as the
first instance and let it through" is consistent on both sides — making the app completely
fail to open because of this is far worse than occasionally having one extra process.

### Windows: the app stays alive in the notification area after closing the window

This is the same thing as the macOS item above, implemented for a second platform (Linux is
the third, see the next section), except that Windows has no "Dock icon" fallback — clicking
once more from the Start menu **opens a new process**, so a single-instance step is added here.

- **Closing is not quitting.** The window's close button goes through `WM_CLOSE`, which is
  intercepted in `windows/runner/flutter_window.cpp` and turned into `ShowWindow(SW_HIDE)`:
  the window is hidden but **not destroyed**, and the `FlutterViewController` (i.e. the
  engine) keeps living, so polling and push registration continue as usual.
- **The icon is created at the moment of closing the window.** It is not in the notification
  area while the window is open — a visible app doesn't need to take up a slot. Next to the
  icon is a right-click menu: "Open main window / Quit Cirro Mail"; left-clicking opens the
  window directly (a convention that is hard to get wrong on the desktop).
- **"Quit" takes a different path**: the tray menu item removes the icon and calls
  `DestroyWindow`, and only when the window is truly gone does it trigger `PostQuitMessage`
  to exit the process. This is the user's only way to quit (there is no window left to
  right-click in the taskbar).
- **Only one process runs.** After closing the window the app is invisible in the taskbar,
  so clicking it again from the Start menu is perfectly reasonable — so at startup it grabs a
  named mutex (`Local\com.zenkee.mailapp.single-instance`), and on failure broadcasts a
  `RegisterWindowMessage` message asking the already-running instance to bring its window to
  the front, then exits. Without this, two processes would fight over the same SQLite
  database, each register its own FCM token, and pop up the same message twice.

A few less-obvious implementation points (all in code comments):

- **`WM_CLOSE`'s default handling is `DestroyWindow`**, and without interception the window
  really is destroyed — `OnDestroy` releases `flutter_controller_` along with it, the engine
  stops, and the user thinks they "just closed a window" when they actually shut down mail
  retrieval.
- **Shutdown must be let through.** The shutdown flow sends `WM_CLOSE` to every top-level
  window at the end, and hiding them the same way makes the progress bar hang until the
  system force-kills it (the user sees "nothing happens for ages after I click shutdown"). So
  after `WM_QUERYENDSESSION` it goes through normal destruction, and when `WM_ENDSESSION`
  comes with `wParam == FALSE` (logout canceled) it must go back — otherwise "close to the
  notification area" silently stops working after a canceled logout and only a reboot
  restores it.
- **The tray callback message has two argument layouts.** With `NOTIFYICON_VERSION_4` set,
  the event code is in the low bits of `lParam`; without it, in the low bits of `wParam`. The
  return value of `NIM_SETVERSION` must be recorded and used to pick one — **you cannot try
  both**: under v4, `LOWORD(wParam)` is the screen x-coordinate, and x=514 happens to equal
  the value of `WM_LBUTTONUP`, so mixed interpretation triggers randomly.
- **`SetForegroundWindow` is required before `TrackPopupMenu`**, otherwise the menu appears
  but doesn't close when you click outside (a classic bug MSDN calls out specifically).
- **An Explorer restart silently clears notification-area icons**, with no notification to
  anyone. It merely broadcasts a `TaskbarCreated`, so that message must be caught and the
  icon re-added — using `NIM_ADD` rather than `NIM_MODIFY`, because re-adding an icon that
  already exists fails silently.
- **The broadcast path needs `AllowSetForegroundWindow(ASFW_ANY)`.** Windows' foreground lock
  rules do not by default allow a background process to steal focus; without authorization
  the other instance's `SetForegroundWindow` is ignored by the system, the window appears but
  stays behind others, and the user still sees "I clicked and nothing happened".
- **`LoadImage` rather than `LoadIcon`**: `LoadIcon` only gives you the largest size, which
  looks blurry scaled down to 16×16. The cost is that the handle must be `DestroyIcon`'d
  yourself.

Smoke self-check: launch with the environment variable `CIRRO_SMOKE_MINIMIZE_TO_TRAY=1` and,
after the first frame, it will run the "close window" path once (hide the window + create the
tray icon), to confirm in an environment where you cannot click a mouse that the engine was
not destroyed.

⚠️ **This section has not been verified on this machine** — this is macOS, and
`flutter build windows` cannot run here (CI doesn't verify it either). What has been done:
passing the four source files through the mingw-w64 cross compiler with
`-fsyntax-only -Wall -Wextra` (zero errors, zero warnings), plus a clean `flutter analyze` on
the Dart side. The three items "close to tray / two menu items / only one instance on
relaunch" need to be actually clicked through on Windows.

### Linux: the app stays alive in the top bar after closing the window

The third platform implementation, behaving like the Windows item (macOS mounts the icon at
launch, whereas Linux/Windows **create it on the first window close**): clicking the window's
close button only hides the window, a top-bar icon remains, the menu has "Open main window /
Quit Cirro Mail", and left-clicking the icon opens the window directly.

Compared with Windows there are two things that are particular to Linux:

- **Single instance does not have to be written by hand.** Windows grabs a named mutex,
  whereas on Linux you just **don't pass `G_APPLICATION_NON_UNIQUE`** — with a unique app id,
  a second launch is forwarded by `GApplication` over the session D-Bus to the already-running
  process, landing in its `::activate`. The branch at the top of `activate` in
  `linux/runner/my_application.cc` that says "if there is already a window, raise it and
  return" is what handles this, and it **must not be omitted**: without it, every click on
  the desktop icon opens another window. (The flags are written as the literal `0` rather
  than `G_APPLICATION_FLAGS_NONE`: the latter was deprecated and renamed to
  `G_APPLICATION_DEFAULT_FLAGS` in GLib 2.74, and the new name does not exist on GLib 2.72
  such as Ubuntu 22.04 — you trip over one or the other either way.)
- **"Hiding" is `delete-event` returning `TRUE`**, corresponding to intercepting `WM_CLOSE`
  on Windows. Returning `TRUE` holds down the default handling (destroying the window) —
  `GtkApplication` holds the main loop for its own windows, and the process dies with the
  window, taking mail retrieval with it.

The top-bar icon has **two backends, and CMake uses whichever it finds**
(`pkg_check_modules(APPINDICATOR QUIET IMPORTED_TARGET ...)` in
`linux/runner/CMakeLists.txt`, defining `CIRRO_HAVE_AYATANA_APPINDICATOR` if found). During
configure it prints a `Tray icon: ...` line saying which one was selected:

| Backend | When it is used | Cost |
|---|---|---|
| `libayatana-appindicator3` | The machine has this package (the proper path on modern desktops) | One **optional** system dependency |
| `GtkStatusIcon` | Fallback when not found | Deprecated; and it **does not show up on GNOME at all** |

GNOME 3.26 removed the built-in status bar icons entirely, and only the AppIndicator protocol
can display them (GNOME additionally requires installing the AppIndicator extension). So the
fallback branch shows **no icon** on GNOME — X11/XFCE/MATE desktops cover it, but this is why
the appindicator branch takes priority. **`QUIET` must not be changed to `REQUIRED`**: that
would make `flutter build linux` fail on machines without the `-dev` package.

A few other implementation points:

- **The menu must explicitly `gtk_widget_show_all`.** The appindicator branch does **not** go
  through `gtk_menu_popup`; it exports the menu structure to the Shell for rendering, and
  nothing on that path calls `show_all` for you — miss this step and the symptom is "the menu
  pops up blank".
- **`Hide()` and destruction are two different things.** `Hide` merely tells the Shell not to
  display it (`APP_INDICATOR_STATUS_PASSIVE` / `set_visible(FALSE)`); the object is still
  there, and the icon can be reattached when the window opens again. Only destruction calls
  `g_clear_object` to release it and destroys the menu. That `Hide` on exit is necessary —
  relying on process death alone means the Shell takes a while to notice the icon is gone,
  and during that time it sits in the top bar and only reveals itself as dead when clicked.
- **The icon name is looked up in the theme first with a fallback.** The name `cirro-mail`
  only enters the theme once installed on the system (`linux/CMakeLists.txt` installs nine
  sizes, 16–512), and running the bundle directly via `flutter run` does not go through
  install. So `ResolveIconName()` probes with `gtk_icon_theme_has_icon` and falls back to GTK's
  built-in `mail-unread`.
- **This project's Linux side is `-Wall -Werror`**, and the entire `GtkStatusIcon` family has
  been deprecated since GTK 3.14, as is the **entire** C API of `libayatana-appindicator`
  (`app_indicator_new_with_path` likewise — it is not fixed by switching constructors) — every
  call site must be suppressed with `G_GNUC_BEGIN/END_IGNORE_DEPRECATIONS` (this macro **must
  wrap the call site**; putting it in a header does nothing, since the warning is reported on
  that line; and it cannot appear in a class body).

⚠️ **This section likewise has not been verified on this machine** — this is macOS, and
`flutter build linux` cannot run here. What has been done: passing the three source files
through `clang++ -fsyntax-only -Wall -Werror` (the same switch set as the project's
`apply_standard_settings`) **once for each of the two backends** (all green), plus a clean
`flutter analyze` on the Dart side. What needs confirming on a real machine: "close to top
bar / two menu items / only one instance on relaunch", plus which backend the configure line
says was selected.

## Attachment preview

The **only** entry point for preview is `features/attachment/attachment_preview.dart`: one
predicate (`canPreview`) plus one `switch`. The predicate = type/size × platform capability ×
whether the viewer is implemented; the `switch` **has no default branch**, so forgetting to
update it when adding a type in the future is a **compile error** rather than pushing out an
empty page. (Before this, it was a pair of private members in `attachment_sheet.dart`, and the
default branch was "if it isn't a PDF, treat it as an image" — any newly missed type reported
"can't open image".)

| Type | How it previews | Fallback |
|---|---|---|
| Image / PDF | Existing implementation | No `pdfx` backend on Linux → no "preview" |
| Text / log / code | Monospace + lazily built per line + selectable; BOM → strict UTF-8 → **GBK/GB18030** → lenient UTF-8 (with a notice) | — |
| Markdown | Parsed to HTML and then **reusing the body's `HtmlBodyView`**, plus a separate "view source" toggle | — |
| CSV / TSV | Self-written RFC4180 parser (quote escaping, newlines in fields, CRLF), fixed header, bidirectional scrolling | 5000 rows × 100 columns |
| docx | `archive` + `xml` extracting `w:body`: heading levels, bold/italic/underline/strikethrough, list items, table colspan | Images/layout/footnotes/text boxes/formulas are all hidden; images get an `[image]` placeholder and a note at the bottom |
| xlsx | Shared strings / inlineStr / booleans / errors / formula results, **date serial numbers are converted to dates** (via `cellXfs → numFmtId`, built-in 14–22/27–36/45–47/50–58 plus a scan of custom format codes) | 5000 rows / 100 columns / 20 sheets |
| pptx | Plain-text cards slide by slide, order per `p:sldIdLst`, header "slide N of M" | Text only, no layout/images/animation; 100 slides |
| Audio | `audioplayers`: play/pause, seek, speed; the player is hidden behind an `AudioPlayback` interface (the plugin only has `MissingPluginException` in `flutter_tester`, and without the layer the widget layer couldn't be tested) | On Linux without gstreamer, an in-page notice plus "open in another app" |
| Video | `video_player`, controls drawn by hand (tap to toggle) | **No implementation on Windows / Linux**, so that "preview" row does not appear on those platforms |

Four hard rules:

1. **Office files never leave the machine.** Parsed locally in pure Dart, never handed to
   Google Docs Viewer / Office Online. Going through a third party means sending the user's
   contract out.
2. **Attachments are untrusted input**, on a par with HTML mail bodies. `archive` 4.5's
   decompression-bomb protection (`maxSize` / `maxOutputSize`) is mandatory; `xml` 7.x does
   not expand internal entities (no billion laughs), does not fetch external entities (no
   XXE), and its parser is iterative (no stack overflow).
3. **A uniform size limit of 20 MiB** (the same number as sending's
   `attachmentTotalSoftLimit`). Anything over the limit gets no "preview", just open/save-as,
   reusing the `previewUnsupported` message.
4. **Type determination lives in exactly one place**: `core/util/attachment_mime.dart` (pure
   Dart, no flutter import). The server always returns `application/octet-stream` on
   S3/KV backends, so **the extension fallback is mandatory**: declared mime (if not
   octet-stream) → `mime` package lookup → a patch table (`mime` lacks `docx` / `pptx` /
   `yaml`) → magic sniffing of the first 8 KB.

The parsers are always **pure functions**: they take a `List<int>`, return a neutral model,
import neither `dart:io` nor widgets, and return a displayable error rather than throwing
through for a bad zip / missing file / over-limit.

## Why large attachments are done this way

`/email/send` accepts only JSON + base64, and the server has no general upload endpoint, so
without modifying the backend there is no way around it. All the client can do is "not blow it
up in memory":

- The request body is assembled chunk by chunk as a `Stream<List<int>>`
  (`features/compose/stream_body_builder.dart`), with attachments streamed from disk via
  `openRead()` through the base64 encoder, **never expanded wholesale into a String**. Peak
  memory drops from "file + 1.33× base64 (Dart Strings are UTF-16, so actually worse) +
  serialization buffer" to roughly one chunk.
- The base64 length can be computed exactly, so `Content-Length` is set explicitly.
- When picking attachments only the path is kept (`file_picker` with `withData: false`),
  never read into memory.
- Before sending, validation happens **locally**: at most 10 attachments, at most 10 inline
  images, non-empty recipients, non-empty body, and the total-size soft limit. This is not an
  optimization — the server's over-limit check happens **after** the row is inserted, so going
  over leaves a dirty `SAVING` row behind.

The real ceiling is on the server: the Worker's 128 MB must base64-decode all attachments and
compute SHA-256 twice, and sending providers usually have a per-message limit of around 25 MB.
The default soft limit is set to 20 MB. To truly exceed it you must change the backend (add a
multipart `sendStream` + a general `POST /upload`), which is a separate matter.

## Directory structure

```
lib/
├── core/          networking (dio + interceptors + envelope unwrapping), storage, drift database, theme, utilities
├── data/          models (hand-written fromJson, tolerant of every field), api, repositories
├── instance/      one instance's runtime (dio + token + capabilities + sync), plus the multi-instance serial scheduler
├── features/      by screen: onboarding / timeline / mail_list / mail_detail / attachment / compose / …
├── providers/     Riverpod
└── l10n/          Chinese and English ARB
test/             unit tests: envelope unwrapping, cursors, URL parsing, time parsing, streaming body, notification gating, route recomputation
```

`dart:io` is allowed only in `core/storage/`,
`data/repositories/attachment_repository.dart`, and
`features/notifications/background_sync_task.dart`. Everything else stays platform-agnostic —
there is no Web target now, but this line keeps a future PWA from requiring a full rewrite.

## Some less-than-obvious pitfalls (all in code comments; outline here)

- **The HTTP status code is always 200.** `401/403/501/502` all live in the body's `{code}`,
  so dio must use `validateStatus: (_) => true`, otherwise authentication and error handling
  all break.
- `unread` is **0 unread / 1 read**, the opposite of what the field name suggests.
- Inline images in the body are the literal `{{domain}}` and must be replaced **at render
  time**; the replaced result must not be written back into the cached `content` (so that an
  instance configuring `r2Domain` later automatically switches to the CDN).
- Attachment downloads uniformly go through `/api/oss/<key>`, **not** `/attachments/*` (which
  only reads KV and breaks when storage is R2/S3). Also, `/api/oss/*` returns **200 + a JSON
  blob** when the object is missing — the downloader must sniff, otherwise it writes a 72-byte
  JSON as the file.
- `createTime` is a UTC time with no timezone marker; `DateTime.parse` treats it as local, so
  it must be parsed explicitly as UTC.
- The login JWT **has no `exp`**; the server validates against a list of at most 10 tokens in
  KV — **the 11th login evicts the oldest session**. So do not silently re-login on 401, as
  that keeps evicting. The app explains this in Settings.
- The server **has no unread-count endpoint** and no single-message detail endpoint. The unread
  badge is computed from the local database (showing "syncing" rather than a wrong 0 before the
  first sync completes); a notification deep link must page back to find that message (at most
  5 pages).
- The send endpoint **does not support cc/bcc** (the server only uses `receiveEmail` to
  assemble `recipient`); the UI says so honestly.

## Why these dependency versions

This machine / CI uses Flutter 3.47.7 + Dart 3.13.5. When upgrading Flutter, the following
must be re-checked (CI `.github/workflows/ci.yml` pins the same version too, precisely to
avoid "passes locally, fails on CI"):

| Package | Constraint | Why this version |
|---|---|---|
| `flutter_riverpod` `^3.4.3` | 3.4.x requires Dart ≥3.12, Flutter ≥3.44; `go_router` before 18.x also requires Flutter ≥3.38 | Already the latest, see "that riverpod patch" below |
| `go_router` `^18.0.2` | 18.x requires Flutter ≥3.44 | 18.0.2 is the latest |
| `drift` / `drift_dev` `^2.35.1` | From 2.34.x, `drift_dev`'s analyzer requires meta ^1.18, while old `flutter_test` pinned meta at 1.17 | 3.47's `flutter_test` has relaxed meta |
| `connectivity_plus` `>=7.3.1 <7.3.2` | **A conflict unrelated to Flutter**: from 7.3.2, via nm ^0.6.0 it wants dbus ^0.8.0, while `flutter_local_notifications_linux` 8.0.1 wants dbus ^0.7.8 | Can be relaxed once `flutter_local_notifications` moves to dbus ^0.8 |
| `cached_network_image` `^4.0.4` | 4.x requires Flutter ≥3.44 | — |
| `pdfx` rather than `pdfrx` | `pdfrx` requires Flutter ≥3.47 (that is satisfied now, see below) | Not yet migrated |
| `archive` `^4.5.1` | Pure Dart, identical on all five platforms | **Only 4.5 onward has decompression-bomb protection** (`maxSize` / `maxOutputSize`). The API also differs from the common 3.x usage found online (`ZipDecoder().decodeBytes()`, no `decodeBuffer`) |
| `xml` `^7.0.1` | The lock already had 7.0.1 (transitive from `flutter_local_notifications_windows`); declaring it explicitly just puts it on the table | **Don't pull in the `excel` package** — it pins `xml >=5.0.0 <7.0.0` and would downgrade xml |
| `charset` `^2.0.1` | Pure Dart, GBK / GB18030 / BIG5 | An obscure package (27 likes), but pure functions and unit-testable |
| `audioplayers` `^6.7.1` | **Implemented on all five platforms** (`just_audio` lacks windows/linux) | Linux forwards to the system gstreamer; a missing library makes constructing the player throw → the playback page catches it and degrades |
| `video_player` `^2.14.1` | Already in the lock (via `flutter_quill_extensions` → `video_player`); promoting it to a direct dependency **does not change any plugin registration** | **No Windows / Linux implementation** → those two platforms offer no video preview (completing it would require switching to `fvp`, out of scope) |

After `build_runner` moved to `^2.16.2`, the `--delete-conflicting-outputs` argument was
removed (writing it only prints a warning), and both CI and local commands dropped it.

### That riverpod patch

`flutter_riverpod` 3.4.3 still has a bug the app reliably hits: **when a consumer paused by
`TickerMode` becomes visible again, it throws
`setState() or markNeedsBuild() called during build`** (triggered when branching between the
wide-screen sidebar and the narrow-screen bottom navigation, always reproducible with a
diamond-shaped dependency graph, see `test/ticker_resume_build_test.dart`). Upstream fixed it
on `main` (PR #4884), but it **has not made it into any release yet**.

So `pubspec.yaml` has this `dependency_overrides` section pointing at a **source copy of
upstream 3.4.3 plus one backported fix** under `third_party/`:

```yaml
dependency_overrides:
  riverpod:
    path: third_party/riverpod
```

What the patch is, why it is needed, and when it can be deleted are all in
`third_party/PATCHES.md`.

## Tests

```bash
flutter analyze
flutter test
```

`test/` has 166 test files and 2228 cases. What they cover are the places that are "extremely
hard to reproduce on a real device, but very costly if wrong": envelope unwrapping,
bidirectional cursors, `{{domain}}` replacement with and without `r2Domain`, tolerance for
malformed `recipient`, UTC time parsing, the four key shapes of `resolveKey`, **the streaming
body's byte stream being byte-for-byte equal to the `jsonEncode` result**, multi-instance hole
detection, the notification baseline gate, route recomputation, and the geometry of the split
layout (the bounds of `clampListWidth`), address composition/decomposition for the selected
state, and the visibility predicate of the shell's floating compose button (hidden on the
detail screen and the wide-screen settings screen, `compose_fab_routes_test.dart`), plus the
regression that "a TickerMode becoming visible again must not mark dirty during build" (four
dependency-graph shapes, see the `third_party/` section above). The inbox round added two
**guards**: `mailbox_scope_test.dart` pins the predicate for "is this screen pinned to some
mailbox" (whether the `account` parameter is present, `0` counting too), and the one in
`home_entries_test.dart` pins "a first-level entry's URL must never contain `account`" — break
it and the inbox itself gets judged a submenu and has its filter button hidden (see
`pinnedMailboxOf`). For push, one regression is pinned on its own: **the device id in outbound
requests must carry the `<slot>-` prefix** — this once produced blanket 401s on the real link
(see `docs/push-setup.md`); additionally `push_pages_test.dart` pins the one branch in the
seven-page wizard's "is this page done?", and `poll_interval_prefs_test.dart` pins the
"check-mail interval" default of 5 minutes, the 1-minute–1-hour range, and the fact that the
old version's two-tier keys no longer count. The only case in the entire suite that "pumps a
whole screen wrapped in `ProviderScope`" is `mailbox_filter_overlay_test.dart`: it pins the
inbox button's overlay **being dismissed along with the route** (pushing a detail page on top
must dismiss it, and returning must not revive it) — this can only be seen by running the
whole UI, not by pure functions.

The attachment-preview round made the OOXML / CSV parsers **pure functions**, so they can be
unit-tested wholesale (`docx_codec_test.dart` / `xlsx_codec_test.dart` / `pptx_codec_test.dart`
/ `csv_codec_test.dart` / `text_decode_test.dart`, each including its own "bad zip / missing
file / over-limit" tolerance cases). Folder samples **do not commit binaries to the
repository**: `test/support/ooxml_fixture.dart` builds a minimal package on the fly in the
test using `archive`'s `ZipEncoder`, which incidentally also verifies "a zip I wrote can be
read back by me". `xlsx_codec_test.dart` pins one date serial number on its own: the epoch is
1899-12-30 (Lotus 1-2-3 compatibility), and the historically-off-by-one serial number 60 is
pinned too. On the audio side, a fake `AudioPlayback` is injected to test the widget layer
(seeking must not drag the slider away during playback, and after finishing a tap must seek
back to 0 first); on the video side only the two paths that **run before the plugin** ("file
gone" / "over limit") are tested — playback itself has no implementation in `flutter_tester`
and can't be tested, which is stated honestly in the file header.

The detail-screen round (selectable body + context menu) covers three: in
`mail_detail_selection_test.dart`, after dragging a selection over the body
`RenderParagraph.selections` is non-empty (**`PointerDeviceKind.mouse` must be supplied**;
touch goes through a different recognizer); the text emitted by `Ctrl+A` + `Ctrl+C` contains
**both** the body and the subject (pinning that `SelectionArea` wraps the `ListView`, not just
the body); and after clicking "delete" in the context menu the row really is gone from the
database and the embedded form's `onClose` was called. `mail_shortcuts_system_test.dart`
mounts the native `com.zenkee.mailapp/window` channel and verifies that `Cmd+W` really hits
`hideMainWindow` and `Cmd+,` really lands on `/settings`.

## Known unfinished work

- **The selected row does not scroll itself into view.** If the message `?sel=` points to is
  not among the rows already loaded in the list, the right pane has content but the left pane
  shows no highlighted row (needs `Scrollable.ensureVisible`). Also, selection is "replaces the
  URL" rather than pushing onto a stack, so **the system back gesture cannot close the right
  preview**; you must use the right pane's own close button.
- **UI text is only partially translated.** The Chinese and English ARBs have 567 keys each
  (the two sides are fully aligned), but roughly 540 UI strings are still hardcoded Chinese
  (scattered across 80 files; the criterion is "after removing comments, Chinese characters
  appearing in string literals", including the `[image]` placeholders in the Office parsers).
  Chinese users see a complete UI; only the **English UI** leaks these untranslated fragments.
  The biggest offenders are error messages and the diagnostics page (which even deliberately
  preserves the server's original Chinese).
- **Shortcuts are only a small set**: `Cmd/Ctrl+N` new, `Cmd/Ctrl+R` reply,
  `Cmd/Ctrl+Shift+F` forward, `Cmd/Ctrl+D` delete, `Cmd/Ctrl+Enter` send, `Cmd/Ctrl+,` open
  settings, `Cmd/Ctrl+W` hide window; on the compose screen `Esc` exits and auto-saves the
  draft. The detail screen's body is selectable and copyable, with a right-click menu for
  "copy / select all + reply / forward / delete". The planned `j`/`k` up-down movement and the
  shortcut help panel are still not done.
- Windows / Linux builds are not verified on CI (the native dependency differences are large
  and each needs its own machine). Android (`flutter build apk --debug`), macOS
  (`flutter build macos --debug`) and iOS (`flutter build ios --no-codesign`) have all been run
  successfully locally. **Windows and Linux have no FCM push** (`firebase_messaging` declares
  only android/ios/macos/web), so those two platforms rely on polling alone.
- **Neither the Windows nor the Linux tray has been verified on a real machine.** macOS (menu
  bar `NSStatusItem`), Windows (taskbar notification area `Shell_NotifyIcon`) and Linux
  (top-bar icon, appindicator or `GtkStatusIcon` fallback) all now "stay alive on close + keep
  a small icon", but the latter two were written on macOS with only cross-compilation / syntax
  checks, see the ⚠️ at the end of their respective sections above.
- **The macOS Release build gets the development environment** (this machine only has the
  development profile, see "Things that still must be done in Xcode / the Apple developer
  portal" above). Shipping it still requires adding a Developer ID profile.
- iOS background fetch is opportunistically scheduled and does not run after the user
  force-quits the app.
- The web client's drafts live in the browser's IndexedDB and cannot be read by the app — the
  two sides' drafts do not interoperate.
- Body rendering uses the pure-Dart `flutter_widget_from_html_core`, so complex marketing mail
  (media queries / flex / grid / `@font-face`) looks somewhat worse than the web client.
- **The attachment-preview round has not been walked through item by item on a real device.**
  The pure functions (three OOXML parsers, CSV, encoding sniffing) and the widget layer (fake
  audio player, which page the dispatcher lands on) all have test cases, but the end-to-end
  checklist in §8 — actually opening a mail with `report.docx` / `sheet.xlsx` / `deck.pptx` /
  a GBK CSV / `voice.m4a` and clicking each one open — has only gone as far as
  `flutter build macos --debug` on macOS, without clicking through item by item. **What most
  needs verifying first is the xlsx date column** (compiling doesn't mean the `cellXfs` path is
  right on a real file) and audio seeking.
- **The three Office formats are "content viewable", not "layout viewable"**: docx images are
  `[image]` placeholders and layout/pagination/footnotes/text boxes/formulas are all hidden;
  pptx extracts text only (no images, charts, animation, notes); xlsx does no formula
  evaluation and recognizes neither conditional formatting nor charts. All three say a line at
  the bottom of the page so users don't think the file is broken.
- **Video has no preview on Windows / Linux** and falls back to "open in another app"
  (`video_player` has no implementation for those two platforms, see the dependency table
  above). Linux audio additionally depends on the system gstreamer and shows an in-page notice
  rather than failing silently when it is missing.
