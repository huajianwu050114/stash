# Stable and Dev profiles

Stash has two explicit application profiles. They use different databases,
attachment directories, and preference namespaces and are designed to run at
the same time.

## Daily use

Always run or install the **Stable** bundle. Build it with:

```powershell
.\tool\build_stable.ps1
```

The complete portable bundle is written to `dist/stable/`.

## Feature development

Always use the **Dev** entrypoint:

```powershell
.\tool\run_dev.ps1
```

Equivalently, use `flutter run -d windows -t lib/main_dev.dart`. Package a Dev
release with `tool/build_dev.ps1`; the complete bundle is written to
`dist/dev/`.

Dev global shortcuts are disabled by default so they cannot conflict with the
daily-use Stable process. Enable them explicitly in Dev settings only when
testing shortcut behavior.

## Automated tests

Tests must use temporary directories, in-memory databases, and fake or
in-memory preferences. Tests must never resolve either production profile's
storage paths.

Never point a development build at Stable storage. Never run destructive
migration experiments against Stable data. Never use Stable as a sync test
peer.

For future Backup and Sync work, test entirely with Dev first. Release to
Stable only after migrations, backups, restore, and recovery behavior have
been validated.
