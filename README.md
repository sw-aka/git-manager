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

Add a local repository or a parent folder; Git Manager discovers repositories up to two directory levels down, skipping hidden folders and node_modules. Add remote repositories with an SSH host (including aliases or user@host), optional port, and absolute path. Existing SSH configuration and authentication apply.

Select a repository to see the last 20 commits. Sync runs a fast-forward-only pull followed by a push; without an upstream it can publish the branch to origin. Errors appear beside the repository and in its detail view. Remove a source from its context menu or the detail view; removing a folder removes every repository discovered under it.

The menu bar shows repositories needing synchronization and offers Sync, Open in Zed, Refresh All, and Open Window. Refresh All rescans local folders and fetches every repository, with at most four operations in flight. Settings controls the background fetch interval (default five minutes).

Sources and settings are saved in `~/Library/Application Support/GitManager/state.json`. For isolated tests or development, `GIT_MANAGER_DATA_DIR` overrides this directory.
