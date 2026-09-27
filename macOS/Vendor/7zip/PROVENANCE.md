# 7-Zip 26.03 provenance

This community macOS GUI uses the unmodified 7-Zip engine by Igor Pavlov.
It is not an official 7-Zip GUI release.

- Release: **26.03**, 2026-09-03
- Official index: https://www.7-zip.org/download.html
- Source: https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.tar.xz
- Source SHA-256: `9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4`
- Original macOS distribution: `7z2603-mac.tar.xz`, supplied in the repository workspace
- Distribution SHA-256: `5ca87677072c59f5602e5c49baa27d4694bacd2259b4e507f0094249d4281480`
- Original universal `7zz` SHA-256: `74b0910e50ea44d9760a57fada2192cfd530ba8bffbe7b47c412a464b796cabf`
- Architectures: arm64 and x86_64

`Scripts/build_engine.sh` defaults to Apple Silicon (arm64), as requested for this
project, using the corresponding source archive included here. No engine source
changes are applied. The ARM build uses upstream assembly. Each build is locally
ad-hoc signed. The original supplied binary remains universal; it is retained
unchanged as an optional fallback, not the architecture target for delivery.

`Scripts/package_app.sh` accepts `SEVENZIP_ENGINE=/absolute/path/to/7zz` to select
the rebuilt binary. Its default is the original universal binary in this folder.
Packaging re-signs the copied executable, so its final hash will differ.

The engine license is LGPL 2.1 or later with additional BSD and unRAR conditions,
as specified in `License.txt`. The unRAR code may not be used to develop a
RAR-compatible compressor. This GUI does not create RAR archives.
The complete corresponding engine source and its notices accompany the `.app`.
The GUI is distributed under the repository's LGPL version 3 license.
