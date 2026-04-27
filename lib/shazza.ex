defmodule Shazza do
  @moduledoc """
  Shazza is an audio fingerprinting and recognition library — an Elixir
  implementation of the Wang/Shazam algorithm.

  The public surface is intentionally narrow:

    * `ingest/2` adds a track to the local index.
    * `identify/2` recognises an audio clip against the index.

  Both operations share the same audio decoding, STFT, peak picking, and
  constellation-hashing pipeline; query and ingest must be symmetric or
  recall collapses.

  See the module documentation for `Shazza.Catalog.Ingest` and
  `Shazza.Match.Query` for end-to-end pipeline details, and
  `Shazza.DSP.Constellation` for the hash construction.
  """

  alias Shazza.Catalog.Ingest
  alias Shazza.Match.Query

  @type ingest_options :: [
          title: String.t(),
          artist: String.t() | nil,
          album: String.t() | nil,
          store: module()
        ]

  @type identify_options :: [
          store: module(),
          min_score: pos_integer()
        ]

  @doc """
  Decodes the audio at `path`, computes its fingerprints, and stores them in
  the configured index store.

  ### Arguments

  * `path` is the absolute or relative path to an audio file. Any format
    FFmpeg understands (mp3, m4a, flac, wav, ogg, opus) is accepted.

  ### Options

  * `:title` is the track title. Defaults to the file basename without extension.

  * `:artist` is the artist name. Optional.

  * `:album` is the album name. Optional.

  * `:store` is the module implementing `Shazza.Index.Store`. Defaults to the
    application-configured store.

  ### Returns

  * `{:ok, %Shazza.Catalog.Track{}}` on success.

  * `{:error, reason}` on decode or storage failure.
  """
  @spec ingest(Path.t(), ingest_options()) ::
          {:ok, :ingested | :resumed, Shazza.Catalog.Track.t()} | {:error, term()}
  def ingest(path, options \\ []), do: Ingest.run(path, options)

  @doc """
  Decodes the audio at `path` and identifies the best-matching track in the
  index.

  ### Arguments

  * `path` is the absolute or relative path to an audio clip.

  ### Options

  * `:store` is the module implementing `Shazza.Index.Store`. Defaults to the
    application-configured store.

  * `:min_score` is the minimum histogram peak count required to return a
    match. Defaults to `5`.

  ### Returns

  * `{:ok, %Shazza.Match.Result{}}` when a match passes the score threshold.

  * `{:error, :no_match}` when nothing in the index reaches the threshold.

  * `{:error, reason}` on decode failure.
  """
  @spec identify(Path.t(), identify_options()) ::
          {:ok, Shazza.Match.Result.t()} | {:error, term()}
  def identify(path, options \\ []), do: Query.run(path, options)
end
