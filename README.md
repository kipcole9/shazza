<p align="center">
  <img src="https://raw.githubusercontent.com/kipcole9/shazza/main/logo.png" alt="Shazza logo — a constellation of peak fingerprints" width="160">
</p>

# Shazza

[![Hex.pm](https://img.shields.io/hexpm/v/shazza.svg)](https://hex.pm/packages/shazza) [![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/shazza) [![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](https://github.com/kipcole9/shazza/blob/main/LICENSE.md)

<!-- MDOC -->

Audio fingerprinting and recognition for Elixir — a Wang/Shazam-style pipeline built on Nx, NxSignal, Xav, and SQLite, with mix tasks for bulk ingest, file identification, and live mic capture.

Shazza turns any audio file into a few thousand 32-bit fingerprints, stores them in a persistent inverted index, and matches a noisy 5-second clip back to the original track in milliseconds. The algorithm is the one Avery Wang published in [*An Industrial-Strength Audio Search Algorithm* (2003)](https://www.ee.columbia.edu/~dpwe/papers/Wang03-shazam.pdf); the implementation runs on EXLA-jitted Nx ops with a chunked streaming pipeline that keeps memory bounded for hours-long inputs.

## What you get

* Three mix tasks covering the whole lifecycle — `mix shazza.ingest <dir>` walks a music library and indexes everything, `mix shazza.identify <clip>` matches a file, `mix shazza.listen` records from the system mic and matches the recording.

* A persistent SQLite index that survives restarts and resumes interrupted ingests cheaply — files whose `(path, size, mtime)` already match an indexed track are skipped without touching FFmpeg or the DSP pipeline.

* Container-tag enrichment via `ffprobe` — ID3, MP4, and Vorbis comments are read at ingest time so artist / album / track number end up in the index automatically.

* A bench harness that sweeps clip-length × signal-to-noise ratio against a real catalogue and prints a Markdown recall table.

* A [step-by-step Livebook walkthrough](https://github.com/kipcole9/shazza/blob/v0.1.0/notebooks/how_it_works.livemd) of the algorithm with executable cells, spectrogram / constellation / histogram plots, and references back to the paper.

## Installation

Shazza requires Elixir `~> 1.20` and FFmpeg 4.x – 7.x at compile and runtime (Xav links against `libavutil` for decode, and Shazza's noise-silencer NIF links against `libavutil` directly).

```elixir
def deps do
  [
    {:shazza, "~> 0.1"}
  ]
end
```

On macOS:

```
brew install ffmpeg
```

On Debian/Ubuntu:

```
apt-get install ffmpeg libavutil-dev libavcodec-dev libavformat-dev libavdevice-dev libswresample-dev libswscale-dev pkg-config
```

## Quick start

Index a music directory:

```
mix shazza.ingest ~/Music --db priv/music.db
```

Identify a file against the index:

```
mix shazza.identify ~/Recordings/clip.m4a --db priv/music.db
```

Capture from the default microphone for 8 seconds and identify what's playing in the room:

```
mix shazza.listen --db priv/music.db
```

A successful match prints something like:

```
Identified: ABBA — Dancing Queen
  album:    Gold
  score:    97  (runner-up: 10, high confidence)
  offset:   0:29.95 into the track
  duration: 3:51.55
  track id: #1
  query:    clip.mp3
```

The same operations are also available as a library API:

```elixir
{:ok, :ingested, _track} = Shazza.ingest("song.mp3", artist: "ABBA", album: "Gold")
{:ok, result} = Shazza.identify("clip.mp3")
result.track.title
#=> "Dancing Queen"
```

## How it works

The algorithm has six stages. Each is a small module under `lib/shazza/`, and every stage is reused for both ingest and identify so the fingerprints produced are byte-identical for the same audio.

* **Decode.** `Shazza.Audio.Decoder.stream/1` opens the file via Xav (an FFmpeg NIF), resamples to 8 kHz mono `:f32` PCM, and yields fixed-size chunks (`chunk_samples + overlap_samples` long, default 13.2 s) so memory stays bounded regardless of track length.

* **STFT.** `Shazza.DSP.STFT.spectrogram/1` runs `NxSignal.stft/3` with a Hann window, fft_length = 1024, hop = 256, takes magnitude, and returns log-scale dB. Each chunk has the same shape so EXLA only ever JIT-compiles one program per session.

* **Peak picking.** `Shazza.DSP.Peaks.pick/1` finds 2-D local maxima with `Nx.window_max`, then keeps only the top-K by magnitude where `K = peak_density_per_second × duration_seconds`. Adaptive density keeps the inverted index balanced across loud and quiet recordings.

* **Constellation hashing.** `Shazza.DSP.Constellation.hashes/2` pairs each anchor peak with up to `:fan_out` future peaks inside a target zone. Each pair is packed into a 32-bit hash via `Shazza.DSP.Hash.pack/3` (9 bits f1, 9 bits f2, 14 bits Δt). The anchor's absolute time travels alongside the hash but is not part of it — the hash itself is time-shift invariant.

* **Inverted index.** `Shazza.Index.SqliteStore` stores `hash → [{track_id, anchor_t}, …]` postings with a single SQL index on `hash`. `Shazza.Index.EtsStore` is the in-memory equivalent for tests. Both implement `Shazza.Index.Store`.

* **Time-offset histogram.** `Shazza.Match.Scorer.best_match/4` looks up every query hash, computes `Δ = db_t − query_t` for every match, and bins per track. The track with the tallest histogram bucket wins; the bucket count is the score; the bucket index converted back to seconds is where in the original the clip starts.

For an executable walkthrough with plots of every step, run [the Livebook](https://github.com/kipcole9/shazza/blob/v0.1.0/notebooks/how_it_works.livemd):

```
livebook server
# → Open notebook → notebooks/how_it_works.livemd
```

## Configuration

All knobs are application config and have sensible defaults at `Shazza.Config.all/0`. The most useful ones:

* `:sample_rate` — decode rate. Default `8_000` Hz. Wang's paper notes that narrowband is sufficient for music identification.

* `:window_size` / `:hop_size` — STFT window and hop. Defaults `1024` / `256` (75% overlap, 32 ms / frame).

* `:peak_density_per_second` — adaptive peak-picking target. Default `30`. Higher means denser fingerprints (better recall, larger index, slower ingest).

* `:fan_out` — how many target peaks to pair with each anchor. Default `5`. Wang's paper analyses fan-out's recall-vs-index-size tradeoff in §2.3.

* `:target_zone_max_dt` / `:target_zone_max_df` — target-zone shape. Defaults `100` frames / `200` Hz.

* `:chunk_seconds` — streaming chunk size. Default `10` s. Bound on per-track memory; rarely worth changing.

* `:index_store` — `Shazza.Index.SqliteStore` (default) or `Shazza.Index.EtsStore`.

* `:sqlite_path` — index location. Default `"priv/index.sqlite"`.

```elixir
config :shazza,
  peak_density_per_second: 50,
  fan_out: 8,
  sqlite_path: "/var/lib/shazza/music.db"
```

## Performance

The chunked pipeline gives constant per-track memory (one chunk's worth of PCM plus the running fingerprint list) and a single EXLA compile per BEAM session regardless of track count. Empirically on an Apple M-series Mac, a typical 4-minute MP3 ingests in ~1.5 s wall clock; a 19-track album in ~30 s; identify on a 5 s clip is sub-second. The bench harness at [`bench/recognition.exs`](https://github.com/kipcole9/shazza/blob/v0.1.0/bench/recognition.exs) sweeps clip-length × SNR against a real index for hard numbers.

## Status

Pre-1.0. The algorithm and on-disk schema are stable, the public API (`Shazza.ingest/2`, `Shazza.identify/2`, `Shazza.Index.Store` behaviour) is unlikely to change, and all 13 tests pass under Elixir 1.20.0-rc.4 / OTP 28.3.1 with `mix dialyzer` clean. No 1.0 commitment yet — there's still room for the bench harness to surface tunings that change defaults.

## License

[Apache License 2.0](https://github.com/kipcole9/shazza/blob/v0.1.0/LICENSE.md). Copyright © 2026 Kip Cole.
