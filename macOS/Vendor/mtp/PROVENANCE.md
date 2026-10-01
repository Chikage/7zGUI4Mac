# MTP dependencies

Pinned upstream release source archives, downloaded 2026-10-01:

- [libmtp 1.1.23](https://github.com/libmtp/libmtp/releases/tag/v1.1.23):
  https://github.com/libmtp/libmtp/releases/download/v1.1.23/libmtp-1.1.23.tar.gz
- [libusb 1.0.29](https://github.com/libusb/libusb/releases/tag/v1.0.29):
  https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2

SHA-256 hashes are recorded in `SHA256SUMS` and checked before building.
Unmodified complete sources and their `COPYING` files are bundled with the app.
Both libraries use LGPL 2.1 or later. The helper source and build script are
included in `SevenZipMac-source.tar.gz`, allowing users to rebuild/relink it
against modified libraries and replace `Contents/MacOS/mtp-browser`.

The helper statically links these libraries, uses macOS system frameworks,
and exposes only device enumeration, directory listing and file download.
MTPZ (Zune authentication) and gettext are disabled. The helper does not expose
device writes. USB claiming and platform driver handling use upstream libmtp.
The build sets ac_cv_func_pipe2=no so that a newer SDK cannot enable the macOS 27
pipe2 function for a macOS 14 deployment. Upstream's pipe/fcntl fallback is used;
the source archives are unmodified.
