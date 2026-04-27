defmodule Shazza.Index.EtsStore do
  @moduledoc """
  In-memory `Shazza.Index.Store` backed by ETS.

  Three tables:

    * `:shazza_tracks` — `{track_id, %Track{}}`.

    * `:shazza_tracks_by_sha` — `{sha256, track_id}`.

    * `:shazza_fingerprints` — `{hash, track_id, anchor_t}` with `:bag`
      semantics so the same hash from many tracks coexists.

  An incrementing counter for track ids lives in a fourth tiny table.
  """

  use GenServer
  @behaviour Shazza.Index.Store

  alias Shazza.Catalog.Track

  @tracks :shazza_tracks
  @tracks_by_sha :shazza_tracks_by_sha
  @tracks_by_source :shazza_tracks_by_source
  @fingerprints :shazza_fingerprints
  @meta :shazza_meta

  # ------------------------------------------------------------------
  # GenServer lifecycle
  # ------------------------------------------------------------------

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@tracks, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@tracks_by_sha, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@tracks_by_source, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@fingerprints, [:bag, :public, :named_table, read_concurrency: true])
    :ets.new(@meta, [:set, :public, :named_table])
    :ets.insert(@meta, {:next_id, 1})
    {:ok, %{}}
  end

  # ------------------------------------------------------------------
  # Shazza.Index.Store callbacks
  # ------------------------------------------------------------------

  @impl Shazza.Index.Store
  def put_track(%Track{} = track, fingerprints) do
    case get_track_by_sha256(track.sha256) do
      {:ok, _existing} ->
        {:error, :already_indexed}

      :error ->
        id = next_id()
        track = %{track | id: id, ingested_at: track.ingested_at || DateTime.utc_now()}
        :ets.insert(@tracks, {id, track})
        :ets.insert(@tracks_by_sha, {track.sha256, id})

        if track.source_path do
          :ets.insert(
            @tracks_by_source,
            {{track.source_path, track.source_size, track.source_mtime}, id}
          )
        end

        rows = Enum.map(fingerprints, fn {hash, t} -> {hash, id, t} end)
        :ets.insert(@fingerprints, rows)
        :ok
    end
  end

  @impl Shazza.Index.Store
  def lookup(hash) do
    @fingerprints
    |> :ets.lookup(hash)
    |> Enum.map(fn {_hash, track_id, t} -> {track_id, t} end)
  end

  @impl Shazza.Index.Store
  def lookup_many(hashes) do
    Map.new(hashes, fn hash -> {hash, lookup(hash)} end)
  end

  @impl Shazza.Index.Store
  def get_track(id) do
    case :ets.lookup(@tracks, id) do
      [{^id, track}] -> {:ok, track}
      [] -> :error
    end
  end

  @impl Shazza.Index.Store
  def get_track_by_sha256(sha256) do
    case :ets.lookup(@tracks_by_sha, sha256) do
      [{^sha256, id}] -> get_track(id)
      [] -> :error
    end
  end

  @impl Shazza.Index.Store
  def get_track_by_source(path, size, mtime) do
    case :ets.lookup(@tracks_by_source, {path, size, mtime}) do
      [{_key, id}] -> get_track(id)
      [] -> :error
    end
  end

  @impl Shazza.Index.Store
  def reset do
    :ets.delete_all_objects(@tracks)
    :ets.delete_all_objects(@tracks_by_sha)
    :ets.delete_all_objects(@tracks_by_source)
    :ets.delete_all_objects(@fingerprints)
    :ets.insert(@meta, {:next_id, 1})
    :ok
  end

  defp next_id do
    :ets.update_counter(@meta, :next_id, 1) - 1
  end
end
