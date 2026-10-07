# Git Manager

A native macOS app for watching local and SSH-hosted Git repositories. See changes, ahead/behind counts and recent commits, sync branches, and open repositories in Zed.

Requires macOS 15+, Xcode, and XcodeGen. No third-party dependencies.

```sh
make gen
make build
make test
make smoke
make run
```

The app embeds the GitManagerCore framework for models, Git/services, and Foundation/Observation app state. Tests run unhosted via `xcrun xctest`; `make smoke` checks that the Release app stays alive for five seconds. When `NONO_CAP_FILE` is set, make disables the Swift macro plugin sandbox for xcodebuild.

Add a local repository or a parent folder; Git Manager discovers repositories up to two directory levels down, skipping hidden folders and node_modules. Unreadable folders show a warning beside their source; accessible repositories still appear. Add remote repositories with an SSH host (including aliases or user@host), optional port, and an absolute or home-relative path (`~` or `~/project`). Remote paths and hostname casing are normalized, and duplicate entries are refused. Existing SSH configuration and credential helpers apply; background Git and SSH commands cannot open password dialogs.

Select a repository to see the last 20 commits. Sync runs a fast-forward-only pull with autostash disabled, checks for unresolved conflicts, then pushes; without an upstream it can publish the branch to origin. Errors appear beside the repository and in its detail view. Remove a source from its context menu or the detail view; removing a folder stops tracking its repositories unless another source also provides them. Overlapping folders and symlink aliases share one repository row and operation lock.

Closing the main window keeps Git Manager running. Use Open Window in the menu bar to reopen it. After `make test`, `make window-smoke` verifies that lifecycle in the Debug app.

The menu bar shows repositories needing synchronization and offers Sync, Open in Zed, Refresh All, and Open Window. Refresh All rescans local folders and fetches every repository. Status refreshes, fetches, and Sync share a limit of four repository operations; process execution also has a six-command cap and runs off Swift's cooperative thread pool. Settings controls the background fetch interval (default five minutes).

Sources and settings are saved in `~/Library/Application Support/GitManager/state.json`. For isolated tests or development, `GIT_MANAGER_DATA_DIR` overrides this directory.

If saved state cannot be decoded, Git Manager preserves it as `state.corrupt-<timestamp>.json` and shows a notice before starting with an empty list. Missing or unknown settings use defaults. If state cannot be read or preserved, saving is disabled for that session.
