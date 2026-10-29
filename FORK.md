# macOS 27 fix: notes for this fork

Fork of [dwarvesf/hidden](https://github.com/dwarvesf/hidden) v1.11.1 (MIT). It makes the **direct build** usable on macOS 27 and adds a Focus stand-in. Not affiliated with Dwarves Foundation.

## What changed

- **Startup race.** The first collapse ran before the arrow had a position (`x=16`), so every icon counted as hidden and only Hidden Bar stayed visible. The engine now waits until the arrow sits in the trailing half of the screen (`NativeVisibilityEngine.withLayout`).
- **Focus item.** macOS 27 native hiding always hides the Focus indicator; no system item id or bundle keeps it (measured on 27.0.1). While the bar is collapsed, a Hidden Bar item shows the active Focus mode (with its own symbol, e.g. Apple Intelligence for Reduce Interruptions) and lets you switch (`FocusItemController`).

- **Focus and the Clock timer stay real (v1.11.1-macos27.2).** Collapsing no longer uses the restriction that hides them. Hidden Bar switches the apps in the hidden section off with macOS's own per-app "Allow in the Menu Bar" switch (System Settings > Menu Bar), the same one you can flip by hand. Apple's own items are never in that list, so Focus, the timer, Wi-Fi and the clock stay. Details in `PerAppSwitchEngine.swift`.
  - The switch lives in a protected Control Center file, so the first collapse asks you once to pick `group.com.apple.controlcenter.plist` in an open panel (Hidden Bar only gets that one file). Until you do, and if the file can't be read, it falls back to the old restriction with the Focus and timer stand-ins (`FocusItemController`, `TimerItemController`).
  - The switch is saved by macOS, so a crash would leave apps hidden. Hidden Bar keeps a list of what it switched off and restores it at launch and on quit. The context menu also has **Restore Hidden Apps** and **Grant Access to Control Center App List...**.
- **Timer item.** In the fallback path only: a Hidden Bar item shows the running Clock timer while the real one is hidden (`TimerItemController`).

## Build (macOS 27, Xcode 27)

```sh
xcodebuild -project "Hidden Bar.xcodeproj" -scheme "Hidden Bar" \
  -configuration Release-Direct -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO PROVISIONING_PROFILE_SPECIFIER= build
cp -R "build/Build/Products/Release-Direct/Hidden Bar.app" /Applications/
```

Use `Release-Direct`: the plain `Debug`/`Release` configurations are the sandboxed App Store build, which still cannot hide anything on macOS 27 (#360).

## Permissions

- **Accessibility** (required): Hidden Bar reads which app owns which icon. An ad-hoc signed app loses this permission on every rebuild; toggle it off and on again in System Settings > Privacy & Security > Accessibility.
- **Control Center app list** (recommended): pick `group.com.apple.controlcenter.plist` once when asked (see above). Without it Focus and the timer are hidden when collapsed and stand-ins are shown.
- **Full Disk Access** (Focus item only): the active mode is read from `~/Library/DoNotDisturb/DB`. Without it the Focus menu only offers a shortcut to the setting.
- **Shortcuts** (Focus item only): macOS has no public API to change Focus. For each mode create a shortcut named `HB Focus <mode name>` with the "Set Focus" action, plus `HB Focus Off`.

## Caveats

- Uses the private `MenuBarClientCore` framework (assessment mode) and an undocumented Focus database format; any macOS update can break either. Not App Store safe.
- Hiding is per app, and macOS's own items always stay visible. Apps macOS has no entry for in its menu bar list can't be hidden.
- The per-app switch writes an undocumented Control Center preference through CFPreferences; a macOS update can change it. Hidden Bar then falls back to the restriction instead of writing.
- A Focus turned on by a schedule or automation may read as off in the stand-in.
