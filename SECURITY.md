# Security

Please report vulnerabilities privately through GitHub's **Security → Report a vulnerability** when available. Do not put credentials, exploitable details, private diffs, or customer data into public issues. If private reporting is unavailable, contact the maintainer through the public profile for a private reporting channel without publishing the sensitive details.

Update archives are signed using a dedicated Sparkle Ed25519 key. Only the public key is embedded in the app and repository. Private keys must remain in the maintainer's Keychain or an explicitly configured, access-controlled CI secret; they must never appear in source, artifacts, logs, or issues.

App updates use HTTPS. Installation requires an authentic archive and user confirmation. Developer ID signing and Apple notarization are not yet enabled; the first installation may need explicit approval in macOS Privacy & Security. Do not disable Gatekeeper globally.

Git operations use the user's local Git and credentials. AI calls go only to the endpoint the user configures after they review the proposed send scope. Automatic redaction is a precaution, not a guarantee that every secret can be recognized.
