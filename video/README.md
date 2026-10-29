# Go Remote teaser

A product teaser for go-remote, built with [Remotion](https://www.remotion.dev). Every frame is React: the laptop, the
Claude Code session, the container, the QR code, the phone and herdr-web-ui are components, and all text is rendered
rather than baked into images.

## Commands

Run these from `video/`; `make` on its own lists them. They install the dependencies the first time.

| Command              | What it does                                                                         |
| -------------------- | ------------------------------------------------------------------------------------ |
| `make studio`        | Open Remotion Studio, with each scene also registered alone                          |
| `make still FRAME=n` | Render frame `n` of the teaser to `out/still-n.png`                                  |
| `make render`        | Render `out/go-remote-teaser.mp4`, 1920 by 1080 at 30 fps                            |
| `make poster`        | Render the thumbnail, `out/go-remote-poster.jpg`                                     |
| `make gif`           | Make `../docs/go-remote-teaser.gif` for the README, rendering first when it is stale |
| `make lint`          | ESLint and `tsc`                                                                     |

They wrap the npm scripts, which still work on their own: `npm run dev`, `render`, `poster`, `audio` and `lint`. `dev`,
`build`, `render` and `poster` run `audio` first, which synthesizes the music and foley into `public/audio`. Its output
is the same every time, so it stays out of git.

The poster is frame 1000, where the laptop's conversation has just landed on the phone. The video's own first frame is a
dim terminal, so upload the poster as the thumbnail wherever a site lets you, and move its frame if the timeline
changes.

## Making changes

1. `make studio` opens Remotion Studio in the browser. Pick `GoRemoteTeaser`, or one scene under Scenes, and scrub to
   the moment you want to change. It reloads each time you save a file in `src/`.
2. Timing is in `src/timeline.ts`, the words in `src/data/`, and where things sit in each scene's file; see Layout.
3. `make still FRAME=n` checks a single frame at full size in a few seconds. The frame number is the one Studio shows.
4. `make render` writes the MP4 in about a minute. QuickTime keeps playing a copy it already has open, so close its
   window before opening the new render.
5. `make gif` when the README should show the change.

## The README GIF

`make gif` uses cursor-approve's recipe: one ffmpeg pass makes a palette, and a second encodes the GIF with it, bayer
dithered, at 12 fps. Two additions nearly halve the file, because the camera never stops moving and almost every pixel
changes on every frame: a light denoise, and 128 colours. The whole teaser comes to about 18 MB at 800 px wide, and is
silent.

| Setting      | Default    | What it changes                                                        |
| ------------ | ---------- | ---------------------------------------------------------------------- |
| `GIF_WIDTH`  | 800        | Width in pixels; the README's column shows about 830                   |
| `GIF_FPS`    | 12         | Frames per second                                                      |
| `GIF_COLORS` | 128        | 256 smooths the banding in the dark backdrop, for about a quarter more |
| `GIF_START`  | The start  | Where a cut begins, in seconds                                         |
| `GIF_LENGTH` | To the end | How long a cut runs, in seconds; `GIF_START=7 GIF_LENGTH=20` is ~9 MB  |

Every version of the GIF that is committed stays in the repository's history, so commit it when the video settles rather
than after each change.

## Layout

| Path                     | What it holds                                                                      |
| ------------------------ | ---------------------------------------------------------------------------------- |
| `src/GoRemoteTeaser.tsx` | The timeline: eight scenes in a `Series`, the captions, grain and sound            |
| `src/timeline.ts`        | Scene lengths and caption timings; the sound cues count from these                 |
| `src/layout.ts`          | Framing shared across cuts. A 9:16 version replaces this file and keeps the scenes |
| `src/scenes/`            | One file per scene                                                                 |
| `src/components/`        | Laptop, terminal, Claude Code, container, connection, phone, herdr-web-ui, QR code |
| `src/data/`              | The scripted session, shared by the laptop's terminal and the phone's chat         |
| `src/Sound.tsx`          | The soundtrack and every sound effect, on the frames the picture cues them         |
| `scripts/make-audio.mjs` | The synthesizer behind `public/audio`                                              |

## Sound

`scripts/make-audio.mjs` synthesizes the soundtrack, the typing, the swooshes, the phone buzz, the ping of the
`/go-remote` pulse and the pop of each message landing on the phone, so the video carries no third-party music. The
soundtrack's beats fall on frames 15 + 20n: beat 12 is Enter on `/go-remote`, 24 to 27 the four hardening chips, 44 the
conversation landing on the phone, 69 "Your files never leave your machine." and 79 the brand. The clicks, dings,
switches and whips in `public/audio/sfx` are Remotion's sound effects from `remotion.media`. The story reads with the
sound off.

## Notes

- The QR code is real and scannable. It encodes `https://github.com/drluckyspin/go-remote`, not a pairing link.
- The phone screens recreate herdr-web-ui from the screenshots in `../docs`, with this video's own conversation. The
  approval card follows herdr-web-ui's own prompt card, with Claude Code's three answers.
- The closing scene uses the Go Remote icon from `public/brand`, and is the only scene in its petrol teal.
- Remotion needs a [company license](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md) for some entities.
