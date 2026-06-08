English | [中文](README.zh-CN.md)

# Codex Quota Viewer

> Stable release: `1.3.5`
>
> 1.3.4 hotfix:
> - Restarts remote Codex app-server processes after remote account sync so they reload the switched account.
> - Preserves legacy custom account display names that were saved before the rename flag existed.
>
> 1.3.3 update:
> - Adds an account-switch confirmation option to terminate Codex processes on selected remote SSH hosts.
> - Expands remote termination to cover Codex native processes, Node wrappers, and app-server proxy shell wrappers for the SSH login user.
> - Preserves user-renamed account display names across runtime refreshes and vault normalization.
>
> 1.3.2 hotfix:
> - Fixes the Settings Accounts pane blank-content regression after account switching by keeping the page and account list scroll area sized to the visible content region.
> - Keeps saved account actions visible with a deterministic account-list layout and adds coverage for the zero-height scroll area regression.
>
> 1.3.1 hotfix:
> - Fixes Settings account rows so switch, rename, and remove actions stay visible after account-list layout refreshes.
>
> 1.3.0 fork update:
> - Adds **Remote sync** for account switches. When enabled, a local switch can also update selected remote Codex homes over SSH.
> - Adds a new **Remote** settings pane that reads selectable `Host` entries from `~/.ssh/config`, supports search, select all, reload, custom SSH targets, and a configurable remote Codex home path.
> - Extends safe switching with multi-host remote sync, remote `auth.json` writes, remote `config.toml` merge, remote rollout `model_provider` updates, and rollback support tied to the same restore point.
> - Adds **Direct Switch (No Backup)** for cases where you explicitly want to skip local and remote restore-point creation.
> - Makes ChatGPT account login cancellable, adds a login timeout, and shows a cancel action in Settings while login is running.
> - Refreshes saved account quota on scheduled refresh, updates quota labels from `1w` to `7d`, redesigns account rows with compact quota indicators, and adds menu icons.
> - Hardens app packaging by signing a clean copy without extended attributes and bundling required Node runtime libraries for the Session Manager.
>
> 1.2.0 update:
> - Adds **third-party Provider mode** for ChatGPT logins, so Codex can stay signed in with the normal ChatGPT account while requests use a saved API account.
> - Adds a menu action that changes between **Switch to Third-party Provider...** and **Switch Back to Normal Account** based on the current mode.
> - Lets you choose the third-party Provider from saved API accounts, then writes the required `base_url` and API key into `config.toml` safely.
> - Protects Provider-mode entry and exit with restore points, rollout provider synchronization, local thread repair, and rollback-safe session history handling.
>

Codex Quota Viewer is a native macOS menu bar app for people who use Codex and
want everything in one place: current quota, saved accounts, safe account
switching, and local session management.

You click one menu bar icon and get the jobs that usually require digging
through `~/.codex`, editing config files, or opening a terminal. The packaged
app also includes the Session Manager, so end users do not need a separate
CodexMM checkout or a manual Node setup.

## What This Version Gives You

- Check the current Codex account and see remaining `5h` and `7d` quota at a
  glance.
- Save multiple ChatGPT and API accounts in a local vault owned by the app.
- Add ChatGPT accounts with the bundled sign-in flow.
- Add OpenAI-compatible API accounts with API key, base URL, and automatic
  model detection when available.
- Switch between accounts safely with backup, rollback, and local thread repair.
- Optionally sync the same account switch to remote machines through SSH.
- Open a built-in local Session Manager from the menu bar and manage sessions in
  the browser.
- Browse active, archived, and trashed sessions, search them, restore them, and
  batch-operate on them.
- Keep the whole app and the Session Manager in sync with one language setting:
  `Follow System`, `English`, or `中文`.
- Choose menu bar display style, refresh cadence, and launch-at-login behavior
  in Settings.

## Who This App Is For

This app is for you if any of these sound familiar:

- You want to know whether your current Codex account still has quota left.
- You switch between multiple Codex identities and do not want to hand-edit
  `auth.json` and `config.toml`.
- You want to rescue, browse, archive, or repair local Codex sessions without
  using terminal commands.
- You want a packaged `.app`, not a pile of scripts.

## Quick Start

### Install the app

1. Download the latest DMG from the
   [Releases](https://github.com/karl1179090/Codex-Quota-Viewer-Remote/releases) page.
2. Drag `CodexQuotaViewer.app` into `/Applications`.
3. Open it. If macOS warns you the app came from the internet, allow it
   manually.
4. Click the new menu bar icon.

### First-time use

1. Let the app read your current Codex login from `~/.codex/auth.json`.
2. Open **Settings... -> Accounts** if you want to add more accounts.
3. Use **Maintenance -> Open Session Manager** if you want to manage old or
   current sessions.
4. Use **Switch Safely** when you want to activate another saved account.

## Main Features

### 1. Quota in the menu bar

The menu bar stays focused on the thing you usually want first: "How much quota
do I have left right now?"

- Standard Codex logins show `5h` and `7d` windows.
- Weekly-only plans are shown correctly as weekly-only.
- You can switch the menu bar between a compact meter and a text summary.
- You can refresh manually or let the app refresh on a schedule.
- Stale data is marked, so you can tell when the numbers may be out of date.

### 2. Local account vault

Codex Quota Viewer has its own local vault for saved accounts.

- Save multiple ChatGPT accounts.
- Save multiple API accounts.
- Rename, activate, forget, and review saved accounts from **Settings... -> Accounts**.
- Open the vault folder directly from Settings if you need to inspect local
  files.
- Keep the top menu compact while still showing all saved accounts under
  **All Accounts**.
- Older compatible local account data can be imported one time when available.
- The menu can still prioritize the most useful accounts first, while the full
  grouped list remains available under **All Accounts**.

### 3. Safe account switching

This is one of the core features of the app.

When you use **Switch Safely**, the app can:

- close Codex first
- create a restore point
- apply the target `auth.json`
- merge and write the target `config.toml`
- rewrite rollout `model_provider` metadata when needed
- repair local official thread state
- reopen Codex after the switch

If **Remote sync** is enabled in Settings, the same switch also runs on the
selected remote SSH targets. Remote sync writes the target `auth.json`, merges
the target `config.toml` with the remote machine's existing config, updates
remote rollout `model_provider` metadata, and reports remote warnings and
updated rollout counts. The switch confirmation can also terminate all `codex`
processes owned by the SSH login user on each selected remote host.

If something looks wrong, you can use **Maintenance -> Rollback Last Change** to
restore the most recent switch backup.

Restore points live here:

```text
~/Library/Application Support/CodexQuotaViewer/SwitchBackups/
```

Remote restore-point data is stored under the remote Codex home:

```text
~/.codex/.codex-quota-viewer/remote-switch-backups/
```

You can also choose **Direct Switch (No Backup)** in the confirmation dialog.
That path skips local and remote restore-point creation, so it is intended only
for cases where you do not need rollback protection.

### 4. Remote sync settings

Open **Settings... -> Remote** to configure remote switch synchronization.

- Enable or disable remote sync for account switches.
- Pick one or more SSH hosts discovered from `~/.ssh/config`.
- Search, select all, deselect all, and reload SSH host entries.
- Add custom SSH targets that are not present in the SSH config.
- Set the remote Codex home path, defaulting to `~/.codex`.

Remote sync uses the system `ssh` command and expects normal SSH access to the
selected machines.

### 5. Built-in Session Manager

Open **Maintenance -> Open Session Manager** and the app launches a local web
console on `127.0.0.1:4318`.

You can use it to:

- browse sessions grouped by project folder
- filter by `Active`, `Archived`, and `Trash`
- search by title, path, and excerpts
- inspect summary cards, timestamps, line counts, event counts, and tool calls
- read the full session timeline
- restore a session to a Codex-visible place
- choose `Resume only` or `Rebind cwd` when restoring
- archive, trash, restore, and purge sessions
- batch-select multiple sessions and operate on them together
- repair official local thread metadata when the local state drifts

The Session Manager is bundled inside the app. End users do not need to install
CodexMM or Node separately.

### 6. Maintenance tools in one place

The **Maintenance** section gives you the actions you are most likely to need
when things drift:

- **Refresh All**
- **Open Session Manager**
- **Repair Now**
- **Rollback Last Change**

### 7. One language setting for everything

The native app UI and the bundled Session Manager share the same language
setting.

- `Follow System`
- `English`
- `中文`

You only change it once in **Settings... -> General -> Language**.

### 8. Settings that matter

The current version includes these practical controls:

- refresh interval
- launch at login
- menu bar display style
- language
- remote sync
- account management

## Typical Workflows

### I only want to check quota

1. Open the app.
2. Look at the menu bar summary or open the menu.
3. If the data looks stale, click **Refresh All**.

### I want to add another account

1. Open **Settings... -> Accounts**.
2. Choose **Sign in with ChatGPT** or **Add API Account**.
3. Save the account.
4. Select it from the menu when you want to use it.

### I want to switch accounts without breaking my local setup

1. Pick the target account from the top account rows or **All Accounts**.
2. Click **Switch Safely**.
3. Let the app finish backup, config update, repair, and relaunch.
4. Use **Rollback Last Change** if you want to undo the switch.

### I want to sync a switch to remote machines

1. Open **Settings... -> Remote**.
2. Enable remote sync and select SSH hosts or add custom targets.
3. Confirm the remote Codex home path.
4. Run **Switch Safely** from the menu.
5. Review the success message for remote rollout updates and warnings.

### I want to find or restore an old session

1. Open **Maintenance -> Open Session Manager**.
2. Find the project and session.
3. Choose `Resume only` if you just want Codex to recognize the session again.
4. Choose `Rebind cwd` if you want the session to point to a different project
   folder.

## Privacy And Local Data

This app is designed for local desktop use.

- The app reads local Codex files that already exist on your machine.
- If you add an API account, the API credential is stored locally in the app's
  own account vault.
- The Session Manager serves only on `127.0.0.1`.
- Session files stay on your machine.

Common local paths used by the app:

- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`
- `~/Library/Application Support/CodexQuotaViewer/Accounts/**/*`
- `~/Library/Application Support/CodexQuotaViewer/SwitchBackups/**/*`

The screenshots in this repository are privacy-safe examples.

## Requirements

- macOS 13 or later
- A local Codex installation:
  `Codex.app` in `/Applications`, or a `codex` executable available in `PATH`
- A signed-in Codex profile in `~/.codex/auth.json`

## Build From Source

If you want the full packaged app:

```bash
./scripts/build-app.sh
```

Output:

```text
dist/CodexQuotaViewer.app
```

If you only want the native executable:

```bash
swift build -c release --product CodexQuotaViewer
```

If you want the project verification suite:

```bash
./scripts/verify-all.sh
```

## Troubleshooting

### "Could not find the codex executable."

Make sure either `Codex.app` exists in `/Applications` or `codex` is available
in your shell `PATH`.

### "Sign in required."

Your local Codex login is missing, expired, or invalid. Sign in again and make
sure `~/.codex/auth.json` is present.

### "Timed out while reading quota."

The local Codex runtime did not return quota data in time. Try **Refresh All**
again. If it keeps failing, confirm Codex itself is working on this machine.

### "Bundled session manager is missing. Rebuild CodexQuotaViewer.app."

Rebuild the packaged app:

```bash
./scripts/build-app.sh
```

Then open the packaged app under `dist/`, not only the raw Swift executable.

### "Session manager could not start because port 4318 is already in use."

Another process is already using port `4318`. If it is an existing session
manager instance, the app can reuse it. If it is unrelated, stop that process
and try again.

## Distribution Notes

The app bundle contains:

- the native Swift menu bar app
- the bundled Session Manager app files
- a private Node runtime used by the bundled Session Manager

That means the packaged `.app` is the product you distribute. End users do not
need a second checkout of the web session manager.

## Thanks

Thank you to the [LinuxDo](https://linux.do/) community for your support.
