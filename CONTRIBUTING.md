# Contributing to Sprig

Thank you for improving Sprig. Read [LICENSE](LICENSE) first: this project is source-available with commercial restrictions and an internal-business-use exception.

- Open an issue for a bug or proposed change; include macOS version, CPU architecture, Sprig version, and a small synthetic reproduction.
- Do not attach private repository contents, credentials, AI keys, private endpoints, or customer data.
- Keep changes focused and preserve Git safety checks. Use temporary test repositories, never production repositories, for tests.
- Run `swift test --package-path native` and `python3 -m unittest discover -s native/scripts/tests` before submitting changes that affect their respective areas.
- Preserve copyright notices and record third-party licenses. New source files should use `SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0`.

By intentionally submitting a contribution for inclusion, you represent that you may submit it and license your contribution under this repository's license. You retain ownership of your contribution. This is not a copyright assignment or a grant to commercially relicense your contribution without additional permission. Identify any third-party material and its license explicitly.

Forks must use their own update feed and signing keys. Do not ship a modified app pointing to the official update feed or representing itself as an official release.
