<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
<!-- Copyright (C) 2026 Sergiu Popov <sg.popov@pm.me> -->

# OpenOCD binaries with CMSIS-DAP TCP

This fork builds OpenOCD with CMSIS-DAP TCP, USB HID (v1), and USB bulk (v2)
support. Tcl, libusb, and hidapi are linked statically; no MSYS2 or Homebrew
runtime installation is required. Other adapters that only need libusb are
also enabled automatically. Optional drivers requiring libftdi, libjaylink,
or proprietary SDKs are not included.

## Downloads and installation

Download an archive from [GitHub Releases](https://github.com/we-devices/openocd/releases)
or the artifacts of a successful [OpenOCD binaries workflow](https://github.com/we-devices/openocd/actions/workflows/binaries.yml).
Workflow artifacts expire after 30 days; tagged release assets are permanent.
Unzip the workflow artifact first to obtain the installable archive and its
SHA-256 checksum.

| Archive suffix | System |
| --- | --- |
| `windows-x86_64.zip` | 64-bit Windows |
| `linux-x86_64.tar.gz` | x86-64 Linux with glibc 2.35 or newer (Ubuntu 22.04+) |
| `macos-x86_64.tar.gz` | Intel Mac, macOS 13+ |
| `macos-arm64.tar.gz` | Apple Silicon Mac, macOS 13+ |

Extract the archive into a directory of your choice. Keep `bin` and `share`
together: OpenOCD locates its bundled target/interface scripts relative to
the executable. Add the extracted `bin` directory to `PATH`, or use the full
path to `bin/openocd` (`bin\openocd.exe` on Windows).

For example, on Linux or macOS:

```sh
tar -xzf openocd-<commit>-<platform>.tar.gz
./openocd-<commit>-<platform>/bin/openocd --version
```

On Windows, use **Extract All** on the ZIP, then in PowerShell:

```powershell
.\openocd-<commit>-windows-x86_64\bin\openocd.exe --version
```

The archives include configuration scripts, documentation, license notices,
and `BUILD.txt` recording the exact source revisions. Linux USB access may
require installing the bundled `share/openocd/contrib/60-openocd.rules` into
`/etc/udev/rules.d/` and reloading udev rules. TCP does not need USB drivers
or udev rules. macOS binaries are not notarized.

## Connect to a CMSIS-DAP TCP adapter

Use the supplied interface config and set your adapter's address before
loading the target config:

```sh
openocd -f interface/cmsis-dap-tcp.cfg \
  -c "cmsis-dap tcp host 192.168.1.4" \
  -c "cmsis-dap tcp port 4441" \
  -c "transport select swd" \
  -f target/stm32f4x.cfg
```

Replace the address and target with your device. Port 4441 is the default;
`cmsis-dap tcp min_timeout 300` raises the minimum response timeout for slower
networks. The endpoint must implement OpenOCD's framed CMSIS-DAP TCP protocol
(the `DAP` header), rather than a raw USB packet stream. UART and SWO are
currently unsupported by this backend.

## Build and release workflow

Every push, pull request, and manual workflow run builds all four archives.
Each job checks the installed binary's version, loads the packaged TCP config,
verifies the TCP commands without connecting to hardware, and checks for
unexpected shared library dependencies. Hardware communication still needs
to be verified against a real adapter.

To publish a release, push a version tag after committing the changes:

```sh
git tag v0.12.0-we.1
git push origin v0.12.0-we.1
```

Only tag pushes publish GitHub Releases, and only after all builds succeed.
Ordinary branch builds upload workflow artifacts. The release job uses the
repository's `GITHUB_TOKEN` with `contents: write`; no separate secret is needed.

For local builds, initialize `jimtcl`, install the build tools listed in the
workflow, and run `bash contrib/build-binaries.sh <platform>` in a native Bash
environment (MSYS2 MINGW64 on Windows). The script downloads pinned libusb
1.0.29 and hidapi 0.15.0 sources, uses the pinned Tcl submodule, and writes
archives and checksums to `dist/`.
