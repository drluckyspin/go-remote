# Third-party notices

go-remote downloads, builds or embeds the software below. Versions are pinned in the `Dockerfile`, `cli/Dockerfile` and
`package.json`. The image records them as `go-remote.version.*` labels, and `make test` checks the installed versions
against them.

| Component                                                              | License                    | How go-remote uses it                                                             | License text                              |
| ---------------------------------------------------------------------- | -------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------- |
| [BitBang CLI](https://github.com/richlegrand/bitbang-cli)              | MIT                        | Release binary in the image, checksum-verified                                    | `third_party/bitbang-cli/LICENSE`         |
| [Herdr](https://github.com/herdrdev/herdr)                             | Apache-2.0                 | Release binary in the image, checksum-verified                                    | `third_party/herdr/LICENSE`               |
| [herdr-web-ui](https://github.com/devswha/herdr-web-ui)                | MIT                        | Source at a pinned commit, run by Bun in the image                                | `third_party/herdr-web-ui/LICENSE`        |
| [Bun](https://bun.sh)                                                  | MIT; JavaScriptCore LGPL-2 | Runtime in the image, and embedded in each `go-remote` executable                 | [Bun's licensing page][bun-licensing]     |
| [lean-qr](https://github.com/davidje13/lean-qr)                        | MIT                        | QR codes in `go-remote`, compiled into it                                         | `third_party/lean-qr/LICENSE`             |
| [xterm.js](https://github.com/xtermjs/xterm.js) (`@xterm/headless`)    | MIT                        | Terminal emulator in `go-remote login`, compiled into it                          | `third_party/xterm/LICENSE`               |
| [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) | Anthropic's terms          | Installed from npm when the image is built                                        | Its npm package                           |
| [Codex CLI](https://github.com/openai/codex)                           | Apache-2.0                 | Installed from npm when the image is built                                        | Its npm package                           |
| [Cursor Agent CLI](https://cursor.com/cli)                             | Cursor's terms             | Release archive downloaded from Cursor when the image is built, checksum-verified | [Cursor's terms of service][cursor-terms] |
| [uv](https://github.com/astral-sh/uv)                                  | MIT or Apache-2.0          | Copied from its official image                                                    | Its repository                            |
| [dprint](https://github.com/dprint/dprint)                             | MIT                        | Release binary in the image, checksum-verified                                    | `third_party/dprint/LICENSE`              |
| [shfmt](https://github.com/mvdan/sh)                                   | BSD-3-Clause               | Release binary in the image, checksum-verified                                    | `third_party/shfmt/LICENSE`               |
| [ShellCheck](https://github.com/koalaman/shellcheck)                   | GPL-3.0                    | Release binary in the image, checksum-verified                                    | `third_party/shellcheck/LICENSE`          |
| [mbake](https://github.com/EbodShojaei/bake)                           | MIT                        | Installed from PyPI with its dependencies, hash-pinned                            | `third_party/mbake/LICENSE`               |

The image keeps the files under `third_party/` in `/usr/local/share/doc/go-remote/third_party/`. The base image
(`node:24-trixie-slim`) and the Debian packages installed on it carry their own notices in `/usr/share/doc`, and mbake's
Python dependencies carry theirs in `/opt/mbake`.

Claude Code and the Cursor Agent CLI are proprietary. The image downloads them when you build it, on your machine, and
go-remote does not redistribute them.

`go-remote` is built on your machine and is not distributed. Anyone who redistributes the compiled executables should
check [Bun's licensing page][bun-licensing] for what the statically linked JavaScriptCore requires.

[bun-licensing]: https://bun.sh/docs/project/licensing
[cursor-terms]: https://cursor.com/terms-of-service
