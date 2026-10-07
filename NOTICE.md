# Third-party notices

Aster Desktop is distributed under GPL-3.0, reproduced in `LICENSE`.

- Aster Core and `common/convert`: Miku0139oao/aster-core, commit `a9a33503b39a03681bc52d9758907316a22df199`, GPL-3.0. Source: https://github.com/Miku0139oao/aster-core/tree/a9a33503b39a03681bc52d9758907316a22df199 . Core builds use `with_gvisor`.
- The Aster orbital-A icon is original artwork in this desktop repository, distributed under GPL-3.0. Reproducible vector source: `assets/aster.svg`; native asset generator: `scripts/generate-icons.py`.
- Flutter / Dart: Flutter contributors, BSD-style licenses. `toolchain.json` pins their versions/source. Flutter-generated `NOTICES.Z` in application assets includes Dart/plugin notices.
- YAML editor: Re-Editor 0.10.0 (Reqable), MIT; https://github.com/reqable/re-editor . Its dependency licenses are included in Flutter's generated notices.
- Noto Sans Traditional Chinese: Google/Noto contributors, SIL Open Font License 1.1. Complete license: `assets/OFL-NotoSansTC.txt`. Source: https://github.com/google/fonts/tree/main/ofl/notosanstc .
- Windows resource build tool: akavel/rsrc v0.10.2, MIT; https://github.com/akavel/rsrc . Used only when packaging the installer.
- Go dependencies: go-winio, coder/websocket, logrus, yaml.v3, x/sys, and the pinned core's dependency graph. Built packages contain `third-party/` with downloaded modules' license texts and `modules.json` recording exact versions/source import paths.

Distribute corresponding desktop sources, pinned core sources and build scripts with binaries. Local scripts do not publish releases. A newer core's notices and source must also be provided if that binary is redistributed.
