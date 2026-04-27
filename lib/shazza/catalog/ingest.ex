defmodule Shazza.Catalog.Ingest do
  @moduledoc """
  Decode → STFT → peak pick → constellation hash → store, driven by
  `Shazza.Pipeline`.

  Uses the same chunked pipeline as `Shazza.Match.Query` so query and
  index fingerprints are byte-identical for the same audio.

  Ingest tries three things in order before deciding to fingerprint:

    1. **Source cache** — `(path, size, mtime)` matches an existing track
       row. Returns the existing track without touching FFmpeg or the
       DSP pipeline. Makes resuming a 45 k file run cheap.

    2. **Decoded-PCM SHA-256** — the file was modified or moved but the
       audio bytes are identical to a track already indexed. Returns
       `{:error, :already_indexed}`.

    3. **New track** — full pipeline runs and a new row is written.

  Title / artist / album come from explicit options if given, otherwise
  from container tags (ID3, MP4 atoms, Vorbis comments) read by
  `Shazza.Audio.Metadata`. Track number is metadata-only.
  """

  alias Shazza.Audio.Metadata
  alias Shazza.Catalog.Track
  alias Shazza.Config
  alias Shazza.Pipeline

  @type status :: :ingested | :resumed

  @spec run(Path.t(), keyword()) :: {:ok, status(), Track.t()} | {:error, term()}
  def run(path, options \\ []) do
    store = Keyword.get(options, :store, Config.get(:index_store))

    with {:ok, %File.Stat{size: size, mtime: mtime}} <- File.stat(path) do
      mtime_unix = mtime_to_unix(mtime)

      case store.get_track_by_source(path, size, mtime_unix) do
        {:ok, existing} ->
          {:ok, :resumed, existing}

        :error ->
          do_full_ingest(path, store, options, size, mtime_unix)
      end
    end
  end

  defp do_full_ingest(path, store, options, size, mtime_unix) do
    with {:ok, %{fingerprints: fingerprints, sha256: sha256, duration_ms: duration_ms}} <-
           Pipeline.fingerprint(path) do
      tags = read_metadata(path)

      track = %Track{
        id: 0,
        title: pick(options, :title, tags, :title) || default_title(path),
        artist: pick(options, :artist, tags, :artist),
        album: pick(options, :album, tags, :album),
        track_number: tags[:track_number],
        duration_ms: duration_ms,
        sha256: sha256,
        source_path: path,
        source_size: size,
        source_mtime: mtime_unix,
        ingested_at: DateTime.utc_now()
      }

      with :ok <- store.put_track(track, fingerprints),
           {:ok, stored} <- store.get_track_by_sha256(sha256) do
        {:ok, :ingested, stored}
      end
    end
  end

  defp read_metadata(path) do
    case Metadata.read(path) do
      {:ok, tags} -> tags
      :none -> %{title: nil, artist: nil, album: nil, track_number: nil}
    end
  end

  defp pick(options, opt_key, tags, tag_key) do
    Keyword.get(options, opt_key) || Map.get(tags, tag_key)
  end

  defp default_title(path) do
    path |> Path.basename() |> Path.rootname()
  end

  # Erlang's File.Stat mtime is `{{Y, M, D}, {h, m, s}}` in local time.
  # Convert to Unix seconds in UTC so the cache key is timezone-stable.
  defp mtime_to_unix({{_, _, _}, {_, _, _}} = local_datetime) do
    {:ok, naive} = NaiveDateTime.from_erl(local_datetime)
    {:ok, dt} = DateTime.from_naive(naive, "Etc/UTC")
    DateTime.to_unix(dt)
  end
end
