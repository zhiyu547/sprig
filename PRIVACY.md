# Privacy

- Repositories, commit drafts, recent repository paths, and preferences are processed or stored locally. Sprig does not operate a repository upload or telemetry service.
- Git fetch/pull/push contact the remotes you select and use your existing Git/SSH credentials.
- AI features send the reviewed, filtered change context to the AI endpoint you configure. API keys are stored in macOS Keychain. Check the preview before sending; redaction is not a complete secret detector. Your provider's retention and privacy terms apply.
- If you enable automatic updates, Sparkle periodically requests public release metadata and downloads updates from GitHub. Manual checks make the same requests. GitHub receives ordinary connection information such as IP address and HTTP metadata. Sprig does not attach repository paths, code, AI settings, or API keys to these requests. Sparkle system-profile reporting is disabled.
- Update installation is confirmed by the user; Git operations and open application dialogs delay restart. Disabling automatic checks does not disable manual checks.
- GitHub issues, pull requests, and any files you choose to upload there are handled under GitHub's terms. Do not include private project data in bug reports.
