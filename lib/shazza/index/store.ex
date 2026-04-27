defmodule Shazza.Index.Store do
  @moduledoc """
  Behaviour for the inverted-index backend that maps `hash → [{track_id,
  anchor_t}]`.

  Two implementations ship with Shazza:

    * `Shazza.Index.EtsStore` — in-memory, used for tests and experiments.

    * `Shazza.Index.SqliteStore` — persistent, single-file, used in
      production.

  Both implementations must be symmetric: a hash inserted via `put_track/3`
  must be returned by `lookup/2` for the same hash value.
  """

  alias Shazza.Catalog.Track

  @type hash :: non_neg_integer()
  @type anchor_t :: non_neg_integer()
  @type fingerprint :: {hash(), anchor_t()}
  @type posting :: {Track.id(), anchor_t()}

  @doc "Insert a track and its fingerprints atomically."
  @callback put_track(Track.t(), [fingerprint()]) :: :ok | {:error, term()}

  @doc "Look up postings for a single hash."
  @callback lookup(hash()) :: [posting()]

  @doc "Look up postings for a batch of hashes. Returns `%{hash => postings}`."
  @callback lookup_many([hash()]) :: %{hash() => [posting()]}

  @doc "Fetch a track by id."
  @callback get_track(Track.id()) :: {:ok, Track.t()} | :error

  @doc "Look up a track by content hash. Used to dedupe ingest."
  @callback get_track_by_sha256(String.t()) :: {:ok, Track.t()} | :error

  @doc """
  Look up a track by `(source_path, source_size, source_mtime)`. Used by
  ingest to skip files that were already fingerprinted on a previous run
  without redecoding them — `(path, size, mtime)` is the cheap-to-compute
  cache key, falling back to PCM SHA-256 if it misses.
  """
  @callback get_track_by_source(
              path :: String.t(),
              size :: non_neg_integer(),
              mtime :: integer()
            ) :: {:ok, Track.t()} | :error

  @doc "Reset all data. Intended for tests."
  @callback reset() :: :ok
end
