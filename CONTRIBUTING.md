# Contributing

Thank you for your interest in contributing to **DiuBangFileS** (NASServer).

## Getting started

1. Fork the repository and clone your fork.
2. Install Flutter (Dart ^3.10.7 per `pubspec.yaml`) on **Windows 10/11 x64** for desktop builds.
3. Run `flutter pub get`.
4. Bootstrap Windows build dependencies (required before build / installer):

   ```powershell
   .\tool\bootstrap_windows.ps1
   ```

   Prepares media_kit native libraries (libmpv + ANGLE, MD5 verified) and FFmpeg LGPL build (`assets/ffmpeg.exe` from BtbN win64-lgpl). Downloads retry up to 3 times; corrupt files are deleted and re-fetched. On failure, the script prints an explicit list of which dependency failed.

   Fix individually: `-Only media_kit` or `-Only ffmpeg`; force re-download: `-Force`.

   Legacy wrappers `bootstrap_media_kit_windows.ps1` / `bootstrap_ffmpeg_windows.ps1` still work.

   If you see `Integrity check failed`, see [Windows 构建故障排除](README.md#windows-构建故障排除) in README.md.

### Local HTTP proxy (one-line switch)

Bootstrap downloads media_kit / FFmpeg from GitHub. To route downloads through Clash / V2RayN (or similar) on this machine, flip one flag in [`tool/bootstrap/bootstrap.properties`](tool/bootstrap/bootstrap.properties):

```properties
localProxyEnabled=true
localProxyHost=127.0.0.1
localProxyPort=7890
```

Set `localProxyEnabled=false` to turn it off. Set `localProxyPort` to your client's **HTTP or mixed** port (not SOCKS). When enabled, bootstrap uses that proxy to reach `github.com` directly (mirror prefix is ignored). Look for `[localProxy] enabled …` in the script output. A TUN-mode VPN can make this switch unnecessary.

### GitHub mirror prefix (no local proxy)

If downloads are slow or blocked and you are not using `localProxyEnabled`, set a mirror prefix in the same properties file:

```properties
githubMirrorPrefix=https://ghproxy.net/
```

Other mirrors: `https://ghfast.top/` · `https://mirror.ghproxy.com/` · leave empty for direct GitHub.

5. Run the app: `flutter run -d windows`
6. Run tests: `flutter test`
7. Run the analyzer: `flutter analyze`

## Pull requests

- Keep changes focused; one logical change per PR when possible.
- Add or update tests for behavior changes.
- Ensure `flutter analyze` and `flutter test` pass locally before opening a PR.
- Do not include secrets, debug log dumps, or personal network identifiers in commits.

## Code style

- Follow existing patterns under `lib/core` and `lib/features`.
- Use the established feature layout: `data/`, `domain/`, `application/`, `presentation/` where applicable.
- Prefer meaningful names over comments that restate the code.

## Security

See [SECURITY.md](SECURITY.md) before reporting or fixing security-sensitive areas (owner credentials, TLS, Relay data scope).

## Questions

Open a GitHub issue for bugs or feature discussions. For security issues, follow SECURITY.md instead of filing a public issue with exploit details.
