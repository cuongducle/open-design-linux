# Open Design for Linux

Unofficial native Linux packaging for [Open Design](https://github.com/nexu-io/open-design) — built from the upstream macOS DMG and rebuilt to run on Ubuntu, Debian, and any modern Linux distribution.

Ships as **`.deb`**, **`AppImage`**, and a flat **APT repository** so you can install with one command and stay up to date automatically.

> **Unofficial.** This project is not affiliated with the Open Design maintainers. It repackages the publicly released macOS build for Linux convenience. All Open Design trademarks and assets belong to their respective owners.

---

## Install

### One-line install (APT)

```bash
curl -fsSL https://cuongducle.github.io/open-design-linux/install.sh | sudo bash
```

### Or add the repository manually

```bash
echo "deb [trusted=yes] https://github.com/cuongducle/open-design-linux/releases/latest/download/ ./" \
  | sudo tee /etc/apt/sources.list.d/open-design.list
sudo apt update
sudo apt install open-design
```

Then launch **Open Design** from your app menu, or run `open-design` from a terminal.

### AppImage

Download the latest `open-design-<version>-linux-amd64.AppImage` from the [releases page](https://github.com/cuongducle/open-design-linux/releases/latest), make it executable, and run it:

```bash
chmod +x open-design-*-linux-amd64.AppImage
./open-design-*-linux-amd64.AppImage
```

On distros without `libfuse2` preinstalled (older Ubuntu LTS), install it first: `sudo apt install libfuse2`.

---

## How it works

Open Design ships a macOS DMG. That DMG contains a Mach-O Electron app with a Mach-O `better_sqlite3.node` and a Next.js standalone web bundle. None of that runs on Linux as-is. This repo performs the conversion:

1. **Extract** the DMG with 7-Zip (≥23; the older p7zip 16.02 cannot read modern `UDZO` DMG layout). We pull out the `app/` payload, the `open-design/` resource root, and the `open-design-web-standalone/` Next.js server.
2. **Recreate pnpm symlinks** that 7-Zip drops (`@opentelemetry/api`, `@next/env`, `@swc/helpers`, …). Without these the standalone web server crashes on `require()` resolution.
3. **Rebuild `better-sqlite3` from source** for the target Electron ABI via `@electron/rebuild`. The macOS Mach-O `.node` is replaced with a Linux ELF.
4. **Package** with electron-builder into `.deb` and `AppImage`, using an `afterPack` hook that installs a bash wrapper (`open-design`) in front of the Electron binary to handle Wayland/X11 detection, sandbox, GPU, and password-store flags.

The version of Electron is pinned in `package.json` and matches the upstream Open Design Electron release (41.3.0 for Open Design 0.11.0).

---

## Build from source

### Prerequisites

- Node.js 20+
- 7-Zip (≥23), `dmg2img` (fallback), `dpkg-dev` (APT repo)
- Build essentials for the native rebuild (python3, make, g++)

```bash
# Debian/Ubuntu
sudo apt install 7zip dmg2img dpkg-dev build-essential python3
```

### Build locally

```bash
git clone https://github.com/cuongducle/open-design-linux.git
cd open-design-linux
npm install --include=dev

# Download the upstream DMG (or place your own at ./open-design.dmg)
curl -fL "https://github.com/nexu-io/open-design/releases/latest/download/$( \
  curl -fsSL https://api.github.com/repos/nexu-io/open-design/releases \
  | jq -r '[.[]|select(.tag_name|startswith("open-design-v"))]|sort_by(.tag_name)|reverse|.[0].assets[]|select(.name|test("mac-x64\\.dmg$"))|.name')" \
  -o open-design.dmg

# Extract + rebuild native + build .deb and AppImage
npm run build:linux

ls dist/
```

### Run the extracted app without packaging

```bash
bash scripts/setup.sh ./open-design.dmg
~/.local/bin/open-design
```

---

## Diagnostics

```bash
open-design --doctor
```

Prints the detected display server, sandbox state, GL backend, Electron version, and whether all resource directories resolved. Useful when filing issues.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `OD_USE_WAYLAND` | auto | Force Wayland (`1`) or X11 (`OD_USE_X11=1`) |
| `OD_DISABLE_GPU` | unset | Disable GPU acceleration |
| `OD_GL_BACKEND` | unset | e.g. `egl`, `swiftshader` |
| `OD_DISABLE_SANDBOX` | `0` | Run without the Electron sandbox |
| `OD_PASSWORD_STORE` | `basic` | `gnome-libsecret`, `kwallet`, `basic`, … |

---

## CI / Auto-updates

- **`check-upstream.yml`** runs daily. It queries the upstream GitHub releases API, and when a new `open-design-vX.Y.Z` tag appears it commits the new asset URL, bumps `upstream-version.txt`, and pushes a `vX.Y.Z` tag.
- **`release.yml`** triggers on that tag. It downloads the DMG, rebuilds for Linux, builds `.deb` + `AppImage`, generates a flat APT index (`Packages`, `Packages.gz`, `Release`), publishes them as release assets, and deploys an install landing page to GitHub Pages.

To enable auto-tagging you must add a `RELEASE_PAT` secret (a personal access token with `repo` + `workflow` scopes) — the default `GITHUB_TOKEN` cannot trigger the downstream release workflow.

---

## Project layout

```
.
├── electron-builder.yml          # Package config (deb + AppImage)
├── build/after-pack.js           # bash wrapper + .desktop patch + Mach-O strip
├── scripts/
│   ├── setup.sh                  # Extract + rebuild + local launcher
│   ├── build-packages.sh         # electron-builder entry
│   ├── smoke-verify.sh           # Headless launch crash check
│   ├── build-apt-repo.sh         # Flat / classic APT index generator
│   ├── generate-apt-install-script.sh
│   ├── get-open-design-version.sh
│   ├── debian/{postinst,postrm,changelog}
│   └── internal/
│       ├── extract-dmg.sh        # DMG -> app_asar/ (+ pnpm symlink repair)
│       └── build-native.sh       # better-sqlite3 rebuild for Electron ABI
├── assets/icons/linux/           # 16..512 px icons
├── .github/workflows/            # release.yml + check-upstream.yml
└── upstream-{version,asset-url}.txt
```

---

## Known limitations

- **x86-64 only.** The upstream DMG is `mac-x64`; no arm64 build is produced. Apple-Silicon Open Design releases would need an arm64 macOS DMG source.
- **Auto-update is not wired.** The `.deb` does not self-update; the APT repository is the update channel.
- **`vela` CLI is macOS-only.** The bundled `open-design/bin/vela` Mach-O binary is stripped during packaging; any feature that shells out to it will not work on Linux until upstream ships a Linux build.

---

## License

The packaging glue in this repository is MIT-licensed (see `LICENSE`). Open Design itself is licensed by its upstream maintainers; this project only redistributes the rebuilt runtime and does not claim ownership of the Open Design name, brand, or assets.
