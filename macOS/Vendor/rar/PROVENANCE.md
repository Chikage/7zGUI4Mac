# RAR for macOS ARM 7.23

The binaries `rar`, `unrar`, `default.sfx` and `rarfiles.lst` were supplied by
the user in `/Volumes/Files/rar/` and copied without changing their contents.
`rar` reports version 7.23 (27 June 2026).

SHA-256 of the supplied `rar`:
`fd6c7db73c659a28b50408354f4a4845c53a67f929f37fd99df92aa77b9f5153`

Documentation and license were obtained from the official matching package:
https://www.rarlab.com/rar/rarmacos-arm-723.tar.gz

RAR is proprietary trial software, separate from the GUI's LGPL license.
No registration key is included in the repository or generated application.
The engine uses the user's own registration file in its standard locations.

The local application bundle is built for the user's requested local use.
The bundled RAR license restricts redistribution/bundling (section 3).
Obtain the vendor's required permission before distributing an application
that embeds these binaries; a purchased end-user key is not redistribution permission.

The packaging script applies the selected application code-signing identity
to the copies in the local build artifact. The vendor originals remain unchanged.
