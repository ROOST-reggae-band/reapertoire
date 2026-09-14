# Screenshots the README expects

Reapertoire's panels only exist inside REAPER, so these have to be captured
by hand. The README already links all three; until the files land, GitHub
renders a broken image in their place.

Capture on macOS with `⌘⇧4`, then `Space`, then click the panel — that grabs
the window alone, with no desktop behind it. Drop the result in this
directory under the exact filename below.

| File | What to capture |
|---|---|
| `detect.png` | The take detection panel over a real rehearsal, mid-tune: thresholds visible, detected takes listed, with REAPER's timeline and a few tracks of waveform showing behind or above it. This is the top-of-README shot and does most of the selling. |
| `name.png` | The naming panel part-way through a session. Ideally showing a confident recogniser guess with its `*` and its `NN% clear` margin, some takes already named and some not, and a letter or two typed in the filter box. |
| `launcher.png` | The launcher menu, so the reader sees every tool sits behind one REAPER action. Small; a tight crop is fine. |

Three things worth checking before you shoot:

- **Nothing private in frame.** Your real repertoire, file paths, the ingest
  token, and any window behind REAPER.
- **Dark theme, consistently.** All three should look like the same session.
- **Readable at GitHub's width.** A README image renders around 900px wide.
  A Retina grab downsampled to ~1600px wide is about right; anything
  narrower than the panel's own size will blur the text.

Run them through `magick <in>.png -strip +dither -colors 128 -define
png:compression-level=9 <out>.png` afterwards if they come out over ~300 KB.
