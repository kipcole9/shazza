# Changelog

All notable changes to Shazza are documented here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.1.0 — 2026-04-28

Initial release.

### Highlights

* **Audio fingerprinting per Wang 2003.** Decode → STFT (Hann, 1024/256) → 2-D peak picking with adaptive density target → combinatorial constellation hashing with a 32-bit packed key → inverted index → time-offset histogram scorer. The same pipeline is shared between ingest and identify so query and database fingerprints are byte-identical.

* **Bounded-memory chunked pipeline.** Audio streams through fixed-shape blocks (default 10 s of PCM plus a 3.2 s overlap for cross-boundary hash pairs). Memory is constant regardless of track length, and EXLA only ever JIT-compiles one tensor shape per BEAM session.

* **Persistent SQLite-backed index.** `Shazza.Index.SqliteStore` (WAL, prepared statements, batched fingerprint inserts) and an in-memory `Shazza.Index.EtsStore` for tests. Both behind a single `Shazza.Index.Store` behaviour.

* **Resume-on-restart.** Re-ingesting a directory short-circuits files whose `(path, size, mtime)` already match an indexed track — no decode, no FFmpeg, no DSP. Falls back to PCM SHA-256 dedupe when the file moved or was re-encoded.

* **Container-tag enrichment.** ID3v2, MP4 atoms, and Vorbis comments are read via `ffprobe` at ingest, surfacing artist / album / track number into the index automatically. User options on `Shazza.ingest/2` always win.

* **Mix tasks for the full lifecycle.**

    * `mix shazza.ingest <path> [--db PATH]` — recursive directory ingest.

    * `mix shazza.identify <clip> [--db PATH] [--min-score N]` — file-based query with confidence labels.

    * `mix shazza.listen [--seconds N] [--db PATH]` — capture from the system mic via FFmpeg (avfoundation on macOS, Pulse on Linux) and identify.

* **Bench harness.** `bench/recognition.exs` sweeps clip-length × SNR against a real index and prints a Markdown recall table.

* **Livebook walkthrough.** `notebooks/how_it_works.livemd` steps through every stage of the algorithm with executable cells, VegaLite spectrogram / constellation / histogram plots, and references back to the original paper.

* **FFmpeg log silencer.** A small NIF (`c_src/av_silence.c`) wraps `av_log_set_level(AV_LOG_QUIET)` so libav INFO chatter doesn't bleed into Shazza output.

### Toolchain

* Built and tested against Elixir 1.20.0-rc.4 on Erlang/OTP 28.3.1.

* FFmpeg 4.x – 7.x is required at compile and runtime (the `Makefile` resolves headers via `pkg-config libavutil` on macOS).
