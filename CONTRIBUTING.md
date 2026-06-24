# Contributing

Thanks for your interest in improving Open Design for Linux.

## Reporting issues

Open an issue with:

- Your distro and version (`/etc/os-release`)
- The Open Design Linux package version
- The output of `open-design --doctor`
- The smoke log path it prints

## Local development

```bash
npm install --include=dev
bash scripts/setup.sh ./open-design.dmg     # extract + rebuild + launcher
npm run build:deb                             # build only the .deb
bash scripts/smoke-verify.sh open-design      # headless crash check
```

When changing packaging logic, rebuild from a clean payload:

```bash
rm -rf app_asar build_native dist
bash scripts/setup.sh ./open-design.dmg
npm run build:linux
```

## Conventions

- Keep the bash wrapper in `build/after-pack.js` and the local launcher in `scripts/setup.sh` in sync for flags (sandbox, Wayland, GL backend, password store).
- Never commit the extracted payload (`app_asar/`, `build_native/`, `dist/`, `*.dmg`). The `.gitignore` already excludes them.
- The Electron version in `package.json` must match the upstream Open Design Electron version. Bump it in the same PR that bumps `upstream-version.txt`.

## Releases

Tags are pushed automatically by the `check-upstream` workflow when upstream Open Design publishes a new version (requires the `RELEASE_PAT` secret). You can also trigger a build manually from the Actions tab with `workflow_dispatch`.
