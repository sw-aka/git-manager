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

Add a local repository or a parent folder; Git Manager discovers repositories up to two directory levels down, skipping hidden folders and node_modules. Unreadable folders show a warning beside their source; accessible repositories still appear. Add remote repositories with an SSH host (including aliases or user@host), optional port, and an absolute or home-relative path (`~` or `~/project`). Remote paths are normalized, and duplicate entries are refused. Host spelling is preserved exactly because SSH aliases can be case-sensitive. Existing SSH configuration and credential helpers apply; background Git and SSH commands cannot open password dialogs.

Select a repository to see the last 20 commits. Sync runs a fast-forward-only pull with autostash disabled, checks for unresolved conflicts, then pushes; without an upstream it can publish the branch to origin. If status output exceeds the capture limit, changed files show a lower bound such as `46603+`, with an error and Sync disabled. Errors appear beside the repository and in its detail view. Each list row is a single line showing the repository, branch, changed files and ↓behind ↑ahead; Sync, Open in Zed and Refresh are in the detail view, the row's context menu and the menu bar. Remove a source from its context menu, the detail view or a folder header, or select several rows (Cmd or Shift click) and press Delete. Every removal asks for confirmation, listing each source and how many repositories it removes; files on disk are never touched. Removing a folder stops tracking its repositories unless another source also provides them. Overlapping folders and symlink aliases share one repository row and operation lock.

Create a named group with New Group in the toolbar, or right-click a repository and choose Move to Group. Groups can mix local and remote repositories, including individual repositories discovered in the same folder. Hover a group heading and click + to create a subgroup, or choose New Subgroup from its context menu. Use the chevron or click a heading to collapse or expand it; each group and Ungrouped remember their expanded state across restarts. A group's count includes repositories in all its subgroups.

Drag a group heading onto the middle of another heading to nest it. Drop at the top or bottom edge of a heading to reorder it at that level; the insertion line shows where it will go. Its entire subtree moves with it. Drop a group on Ungrouped to return it to the top level. A group cannot be placed inside itself or any of its descendants. Names must be unique among sibling groups. Right-click a heading to rename or dissolve a group; dissolving keeps its repositories and promotes its subgroups to the parent level (or the top level), adding a numeric suffix if a promoted name already exists there.

Cmd or Shift select several repositories to move them together. Drag a repository onto another row to insert it before that row, or onto a group heading to append it to that group; empty and collapsed groups accept drops too. The row context menu also offers Move Up and Move Down, and Move to Group lists the full paths of nested groups. Groups, membership and ordering survive refreshes and restarts. Source Folders at the bottom of the sidebar retain folder warnings and the Change Folder and Remove Source menus.

Closing the main window keeps Git Manager running. Use Open Window in the menu bar to reopen it. After `make test`, `make window-smoke` verifies that lifecycle in the Debug app.

The menu bar shows repositories needing synchronization and offers Sync, Open in Zed, Refresh All, and Open Window. Refresh All rescans local folders and fetches every repository. Status refreshes, fetches, and Sync share a limit of four repository operations; process execution also has a six-command cap and runs off Swift's cooperative thread pool. Settings controls the background fetch interval (default five minutes).

Sources, settings, repository groups and ordering are saved in `~/Library/Application Support/GitManager/state.json`. For isolated tests or development, `GIT_MANAGER_DATA_DIR` overrides this directory.

If saved state cannot be decoded, Git Manager preserves it as `state.corrupt-<timestamp>.json` and shows a notice before starting with an empty list. Missing or unknown settings use defaults. If state cannot be read or preserved, saving is disabled for that session.

The app icon and menu bar icon are drawn in `Design/AppIcon.svg` and `Design/MenuBarIcon.svg`; run `make icons` after editing them.
