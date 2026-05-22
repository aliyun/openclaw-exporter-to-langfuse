# Changelog

All notable changes to this project are documented in this file.

## [0.1.5] - 2026-05-22

### Added
- Support `userId` plugin config option to apply a static user ID to traces. Defaults to the OS username; when configured, overrides the OS default. Priority chain: config > OS account > `"unknown"`. ([#6](https://github.com/aliyun/openclaw-exporter-to-langfuse/pull/6), 592765c)
- Document `userId` in `openclaw.plugin.json` configSchema, root `index.ts` configSchema, `PLUGIN_README.md`, `TUTORIAL.md`, `TUTORIAL.zh.md`, and `scripts/VERSIONED_INSTALLATION.md`.
- Add `--user-id` CLI flag to `scripts/install.sh`, with preserve-existing, override, normalize, and clean-empty handling that mirrors the existing `tags` pattern.
- Document Authorization header creation steps for Langfuse in `PLUGIN_README.md` (acfbbee).
- Update version compatibility metadata (`version-compat.json`) (5de3b85).

### Changed
- Default Langfuse OTLP endpoint scheme switched from HTTPS to HTTP to avoid SSL EPROTO errors when the collector terminates plain HTTP (1a0ace1).

## [0.1.4] - 2026-05-09

### Changed
- Installer performance and robustness improvements in `scripts/install.sh` (3acc799).

## [0.1.3] - 2026-05-09

### Added
- Add `PLUGIN_README.md` as the plugin-level documentation; integrated into `pack.sh` so it is bundled with the plugin tarball (793bfc5).

## [0.1.2] - 2026-05-09

### Added
- Introduce versioned installation flow: split installation docs into `INSTALLATION.md` (version-resolution guide) and `VERSIONED_INSTALLATION.md` (version-specific instructions), packaged into `release/` and `release/vX.Y.Z/` respectively (a8834ad).
- Plugin version management: `VERSION` file, `version-compat.json`, baked-in `PLUGIN_VERSION` in install/uninstall scripts (f6471d3).

### Changed
- Set explicit `pluginApi` field in plugin manifest (b893e99).

## [0.1.1] - 2026-05-03

### Fixed
- Fix LLM info not accessible from conversation hooks (80db6c6).

### Changed
- Update version metadata (cf50a4b).

## [0.1.0] - 2026-04-28

### Added
- Initial open-source release of the OpenClaw → Langfuse OpenTelemetry trace exporter plugin (2092e01).
- Initial version baseline (194e059).

[0.1.5]: https://github.com/aliyun/openclaw-exporter-to-langfuse/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/aliyun/openclaw-exporter-to-langfuse/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/aliyun/openclaw-exporter-to-langfuse/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/aliyun/openclaw-exporter-to-langfuse/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/aliyun/openclaw-exporter-to-langfuse/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/aliyun/openclaw-exporter-to-langfuse/releases/tag/v0.1.0
