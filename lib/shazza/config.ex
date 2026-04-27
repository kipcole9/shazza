defmodule Shazza.Config do
  @moduledoc """
  Read-only access to Shazza's tunable parameters.

  Every knob has a sensible default; override any of them via
  `config :shazza, key: value` in your application config. The full
  list with current values:

      Shazza.Config.all()

  Most users won't need anything beyond `:sqlite_path` and
  `:index_store`. The DSP knobs (`:window_size`, `:hop_size`,
  `:peak_density_per_second`, `:fan_out`, …) trade off recall against
  index size and ingest speed; see the README's Configuration section
  for guidance.
  """

  @defaults %{
    sample_rate: 8_000,
    channels: 1,
    window_size: 1024,
    hop_size: 256,
    peak_neighborhood: {21, 21},
    peak_density_per_second: 30,
    fan_out: 5,
    target_zone_min_dt: 1,
    target_zone_max_dt: 100,
    target_zone_max_df: 200,
    # Chunked pipeline: process audio in fixed-size blocks so memory and
    # the EXLA shape cache stay bounded regardless of track length.
    chunk_seconds: 10,
    index_store: Shazza.Index.EtsStore,
    sqlite_path: "priv/index.sqlite"
  }

  @spec get(atom()) :: term()
  def get(key) when is_map_key(@defaults, key) do
    Application.get_env(:shazza, key, Map.fetch!(@defaults, key))
  end

  @spec all() :: %{atom() => term()}
  def all do
    Map.new(@defaults, fn {key, _default} -> {key, get(key)} end)
  end

  @doc """
  Number of PCM samples in one chunk of the streaming pipeline. Equal to
  `:chunk_seconds * :sample_rate`.
  """
  @spec chunk_samples() :: pos_integer()
  def chunk_samples, do: get(:chunk_seconds) * get(:sample_rate)

  @doc """
  Number of PCM samples kept as overlap at the end of each chunk so that
  constellation pairs spanning a chunk boundary are still emitted.
  Computed from `:target_zone_max_dt` (frames) × `:hop_size` (samples per
  frame), rounded up to an integer multiple of `:hop_size`.
  """
  @spec overlap_samples() :: non_neg_integer()
  def overlap_samples, do: get(:target_zone_max_dt) * get(:hop_size)

  @doc """
  Number of STFT frames emitted per chunk's non-overlap region. Used by
  `Shazza.Catalog.Ingest` to translate per-chunk frame indices into a
  global anchor-time index.
  """
  @spec chunk_emit_frames() :: pos_integer()
  def chunk_emit_frames, do: div(chunk_samples(), get(:hop_size))
end
