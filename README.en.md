<p align="center"><img src="native/Resources/Sprig.png" width="96" alt="Sprig app icon"></p>
<h1 align="center">Sprig</h1>
<p align="center"><strong>Make every commit clear.</strong></p>
<p align="center">A lightweight, native macOS Git client. Review changes, draft with AI, and sync before pushing.</p>

<p align="center">
  <a href="https://github.com/zhiyu547/sprig/releases/latest"><img src="https://img.shields.io/github/v/release/zhiyu547/sprig?style=flat-square&amp;color=65b68d" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-273443?style=flat-square" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-Universal-273443?style=flat-square" alt="Universal app for Apple Silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Source--available-Sprig%20NC--SA-64769c?style=flat-square" alt="Source-available under the Sprig NC-SA license"></a>
</p>

<p align="center"><strong><a href="https://github.com/zhiyu547/sprig/releases/latest">Download for macOS</a></strong> · <a href="README.md">简体中文</a> · <a href="native/README.md">User guide (中文)</a> · <a href="https://github.com/zhiyu547/sprig/issues">Report an issue</a></p>

![Sprig workspace with file staging, a commit composer, and a unified code diff](docs/media/workspace.jpg)

<p align="center"><sub>Actual application screenshots using an isolated demo repository. Code and commit text are examples. <a href="docs/media/README.md">Screenshot notes</a></sub></p>

## One workspace, from review to push

**Review changes → stage files → write a commit → sync and push.** Keep using your preferred editor and open Sprig whenever you want to prepare a commit.

| Small, native app | AI assistance with your review | Sync before pushing |
| --- | --- | --- |
| SwiftUI + AppKit, using system Git. The v0.4.0 universal ZIP is about **4.4 MiB**; the DMG is about **4.8 MiB**. | Generate a title and focused change list from the staged diff. Preview before sending; edit before committing. | Fetch remote updates and merge or rebase before pushing. Pause on conflicts, then continue after resolution. |

### See what changed—and what will be committed

- Separate tracked changes and untracked files; select files to stage them.
- Switch between staged and working-tree changes, with split or unified diffs and basic syntax highlighting.
- Resize the file list, code pane, and commit composer; keep your preferred layout.
- Commit, amend, commit and push, or reuse an earlier commit message.

### Give your commit a useful message

Use the AI icon above the composer, review the outgoing file list and diff, then generate a message or request a code review. Connect a Chat Completions-compatible service or local Ollama. API keys stay in macOS Keychain.

Example message format:

```text
feat(tasks): add a focused task view

- Hide completed tasks when focus mode is enabled
- Order visible tasks by priority
- Add a focus toggle to the toolbar
- Cover completed-task filtering with a test
```

<p align="center"><img src="docs/media/ai-preview.jpg" width="620" alt="AI confirmation dialog showing the model, included files, and staged diff before sending"></p>

**You control what is sent and what is committed.** File exclusions and sensitive-value masking are available. Review the preview: automated masking cannot identify every secret. AI output does not mean compilation or tests have run. See [privacy](PRIVACY.md).

### Sync remote changes before pushing

Enable automatic synchronization before pushing and choose merge or rebase. Uncommitted changes are stashed and restored. Conflicts pause the operation so you can resolve them and continue, or abort. Sprig does not force-push over remote history.

<p align="center"><img src="docs/media/sync-push.jpg" width="620" alt="Push confirmation with automatic synchronization enabled and merge or rebase options"></p>

### Browse the context behind a change

View local and remote branches and tags. Search commit messages, hashes, or authors, then inspect a commit's changed files. Stash, cherry-pick, and revert are also available.

![Commit history with a selected commit and its file diff](docs/media/history.jpg)

## Get started

1. Download the **DMG** from [Releases](https://github.com/zhiyu547/sprig/releases/latest) and drag Sprig into Applications. A ZIP is also available.
2. Open a local Git repository, review its changes, and select the files to stage.
3. Write a message yourself, or configure an AI service and generate one. Review, then commit.

**Requirements:** macOS 13+, Apple Silicon or Intel, and working system Git. Run `git --version` and install Apple Command Line Tools if prompted. Bring your own AI endpoint; service charges depend on your provider. The application UI is primarily Chinese; AI output supports Chinese or English.

> **First launch:** Release builds are currently ad-hoc signed, **without Apple Developer ID signing or notarization**. macOS may show a developer-verification prompt. Verify the download source, then follow [Apple's guidance](https://support.apple.com/102445).

**Updates:** Use **Sprig → Check for Updates** (检查更新…). About Sprig contains the daily-check toggle. Update metadata and archives are signed; installation requires confirmation and waits for active operations to finish. Users of 0.3.x need to install 0.4.0 manually once.

## Feature overview

| Workflow | Available |
| --- | --- |
| Review | File groups, search, split / unified diffs, basic syntax highlighting |
| Commit | File staging / unstaging, partial-stage status, drafts, amend, sign-off |
| AI | Commit messages, code review, outgoing preview, exclusions, editable results |
| Sync | Fetch, fast-forward pull, merge / rebase before push, conflict pause / resume / abort |
| Browse | Branches, tags, commit history and diffs, stash, cherry-pick, revert |
| Desktop | Resizable panes, shortcuts, saved layout, Keychain, in-app updates |

Selecting a file stages its current changes. Commits include only staged content; Git hooks run normally. Authentication uses your existing system Git / SSH setup; there is no terminal password-entry UI.

<details>
<summary><strong>Current limitations and compatibility</strong></summary>

Line-level staging, a three-way conflict editor, interactive rebase, a full history graph, and clone / remote-configuration UI are not yet implemented. Binary and non-UTF-8 files have no text diff; large previews are bounded.

Desktop validation is on Apple Silicon / macOS 27; CI builds and tests run on macOS 15. Intel and older macOS versions still need more real-device testing. Download sizes above refer to the public v0.4.0 assets.

</details>

<details>
<summary><strong>Build from source</strong></summary>

Requires macOS, Xcode / Command Line Tools, and Swift 5.9+:

```sh
swift test --package-path native
python3 -m unittest discover -s native/scripts/tests -v
swift build --package-path native -c release --product GitTool --arch arm64 --arch x86_64
python3 native/scripts/package_app.py --arch universal
open native/build/Sprig.app
```

Sparkle is pinned in Swift Package Manager. Forks must configure their own repository, bundle identifier, and update-signing keys. See [release maintenance](docs/releasing.md).

</details>

## License and copyright

**Copyright © 2026 zhiyu.** Sprig uses the custom [Sprig Non-Commercial Share-Alike License 1.0](LICENSE). It is **source-available**, not OSI-approved open source.

- Personal non-commercial use, learning, modification, and sharing are permitted.
- **Internal business use is permitted**, including work on commercial repositories. Your independent business code does not become covered by this license merely because you use Sprig.
- Commercial redistribution, product integration, external commercial services, and paid Sprig-specific services require separate written permission.
- External distributions and services must provide complete corresponding source under the same license and preserve attribution.

The full [LICENSE](LICENSE) controls. Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).

## Help improve Sprig

[Report an issue](https://github.com/zhiyu547/sprig/issues) with your macOS version, steps to reproduce, and a minimal example without private code. If Sprig is useful to you, a **Star** makes it easy to find again.

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Release notes](https://github.com/zhiyu547/sprig/releases) · [Icon provenance](docs/brand/README.md)

Sprig is an independent project, without affiliation or endorsement from JetBrains, Qoder, GitHub, or their products.
