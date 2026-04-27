# bt-video-merge.sh

> Turn a folder of images + an audio file into a vertical video. Zero config, fully interactive.

## Install

```bash
git clone https://github.com/emyassine/bt-video-merge.sh
cd bt-video-merge.sh
chmod +x bt-video-merge.sh
sudo mv bt-video-merge.sh /usr/local/bin/   # optional
```

**Requires:** ffmpeg — `brew install ffmpeg` / `sudo apt install ffmpeg`

## Quickstart

```
my-project/
├── 01.jpg
├── 02.png
├── input-audio.mp3   ← name it exactly this
├── intro.mp4         ← optional
└── outro.mp4         ← optional
```

```bash
cd my-project
bt-video-merge.sh
```

Produces: `bt-video-merge.sh-20240315_143022.mp4`

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--audio=FILE` | `input-audio.*` | Audio file |
| `--output=FILE` | `bt-video-merge.sh-{timestamp}.mp4` | Output name |
| `--intro=FILE` | `intro.*` auto-detected | Intro video or image |
| `--outro=FILE` | `outro.*` auto-detected | Outro video or image |
| `--by=SORT` | `alpha` | `alpha` / `datetime` / `order` |
| `--bgmode=MODE` | `black` | `black` / `blur` / `crop` |
| `--width=N` | `1080` | Output width px |
| `--height=N` | `1920` | Output height px |
| `--duration=N` | audio length | Force duration in seconds |
| `--keep-tmp` | off | Keep temp files |
| `--dry-run` | off | Preview without running |
| `--verbose` | off | Show full ffmpeg output |

## Examples

```bash
bt-video-merge.sh                                          # interactive
bt-video-merge.sh --bgmode=blur --by=datetime
bt-video-merge.sh --intro=intro.mp4 --output=reel.mp4
bt-video-merge.sh --dry-run --verbose
bt-video-merge.sh --keep-tmp                               # keep .bt-tmp-*/
```

## Temp files

Stored in `.bt-tmp-{timestamp}/`, versioned per run — parallel runs never collide. Deleted automatically unless `--keep-tmp` is set.

## License

MIT
