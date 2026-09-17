# Third-party notices

The Sprig license applies only to original project materials. It does not replace or restrict the following components' licenses. This file and the complete license texts are included inside distributed apps under `Contents/Resources/Licenses`.

## Sparkle 2.10.0

- Project: https://github.com/sparkle-project/Sparkle
- Documentation: https://sparkle-project.org/
- Purpose: native macOS update checks, download verification, installation, and relaunch.
- License: MIT, plus the separately identified licenses of bundled components (including bsdiff, sais-lite, Ed25519, and signature verification code).
- Complete upstream notices: [licenses/Sparkle-LICENSE.txt](licenses/Sparkle-LICENSE.txt), copied unchanged from the pinned Sparkle distribution.
- The packaged Sparkle framework also retains its upstream resources and licenses. No claim of authorship of Sparkle is made.

## System software

Sprig invokes the user's installed `/usr/bin/git`; Git is not bundled in the app or source release. Git remains subject to its own license. AppKit, SwiftUI, Security, CryptoKit and other macOS system frameworks are provided by Apple and are not redistributed as part of Sprig.

SF Symbols are used through the system's native symbol APIs for the macOS interface. No standalone SF Symbols font or extracted icon collection is distributed.

## Project icon and design references

The Sprig icon was generated for this project with ImageGen, without a reference image, as documented in [docs/brand/README.md](docs/brand/README.md). Its inclusion does not guarantee exclusive copyright or trademark rights in machine-generated elements. Original project assets are made available only to the extent rights can be granted and subject to the project's license and brand terms.

IntelliJ IDEA and Qoder were interaction references. Cockpit Tools was a distribution reference. Their code, logos, icons, and screenshots are not included in this source release. These product names belong to their respective owners; no affiliation is claimed.

## Release scope

The published repository contains the native application. The earlier local web prototype, its npm dependencies, private screenshots, test repositories, caches, and generated build outputs are excluded. Adding a dependency or redistributing a new asset requires updating these notices and preserving its license.
