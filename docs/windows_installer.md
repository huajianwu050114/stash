# Stash Windows installer

## For daily use

Run `StashSetup-x.x.x.exe`, choose the desired installation directory, and use the installed Stash application afterward. Do not launch the Stable application from worktree, `build`, or `dist/stable` directories; those are development and build locations.

The installer creates a Start Menu shortcut and can optionally create a desktop shortcut. The default per-user installation directory is `%LOCALAPPDATA%\Programs\Stash`, and the directory can be changed in the installer.

During an upgrade, Windows Restart Manager asks the running Stable app to close before program files are replaced. Because Stash can remain in the notification area, exit Stash from its tray icon if the installer reports that it is still running.

## For development

Run:

```powershell
.\tool\run_dev.ps1
```

Dev stays a source-only workflow. Do not use the installed Stable application for destructive testing, and do not create or distribute a Dev installer.

## For building a new installer

Install Inno Setup 6, then run:

```powershell
.\tool\build_installer.ps1
```

The default command performs a fresh Stable Windows release build, validates the complete `dist/stable` bundle, and creates the installer under `dist/installer`. To repackage an already validated Stable bundle, run:

```powershell
.\tool\build_installer.ps1 -SkipFlutterBuild
```

`ISCC.exe` may be on `PATH`, supplied through `ISCC_PATH`, or installed in a standard Inno Setup 6 location. The build does not download compiler binaries. Installer metadata and its SHA256 hash are written to `dist/installer/BUILD_INFO.txt`.

The committed AppId is the Stable installer's permanent upgrade identity:

> **DO NOT CHANGE APPID AFTER FIRST RELEASE.**

Every future Stable installer must reuse it so Windows and Inno Setup recognize an existing installation, remember its directory, and upgrade it rather than creating a side-by-side copy.

## User data

The program installation directory and user-data directory are independent. Stable data remains under `%APPDATA%\com.example\stash\Stash\`, including the database, attachments, and profile preferences.

Installing, upgrading, or uninstalling Stash does not delete that Stable profile data. The installer only owns program files, shortcuts, and uninstall metadata. It never places the database or attachments inside the program directory.

## Future release workflow

```text
Feature development
  -> Stash Dev
  -> tests
  -> release branch / Stable baseline
  -> version bump
  -> tool/build_installer.ps1
  -> StashSetup-x.y.z.exe
  -> human install/upgrade
  -> installed Stable for daily use
```

Automatic updates, GitHub Releases automation, code signing, and certificates are intentionally outside this phase.
