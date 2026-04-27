defmodule Shazza.Index.SqliteStore do
  @moduledoc """
  Persistent `Shazza.Index.Store` backed by SQLite via Exqlite.

  Schema:

      tracks(id, title, artist, album, duration_ms, sha256 UNIQUE, ingested_at)
      fingerprints(hash, track_id, anchor_t)
      INDEX fingerprints_hash ON fingerprints(hash)

  Pragmas: WAL journal, `synchronous=NORMAL`, `temp_store=MEMORY`. Writes
  are batched in a single transaction per `put_track/2`.

  The store is a single GenServer that owns the connection — SQLite is a
  single-writer database and serialising through one process keeps the API
  surface simple. Reads are also serialised; if read latency becomes a
  bottleneck on very large catalogs we can introduce a read-only connection
  pool.

  ### Configuration

      config :shazza,
        index_store: Shazza.Index.SqliteStore,
        sqlite_path: "priv/index.sqlite"
  """

  use GenServer
  @behaviour Shazza.Index.Store

  alias Exqlite.Sqlite3
  alias Shazza.Catalog.Track

  @insert_chunk 1_000

  # ------------------------------------------------------------------
  # Lifecycle
  # ------------------------------------------------------------------

  @doc """
  Start the store. The SQLite file path comes from `:shazza, :sqlite_path`
  application config; pass `:path` here to override (used by tests).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    path =
      Keyword.get_lazy(opts, :path, fn ->
        Application.fetch_env!(:shazza, :sqlite_path)
      end)

    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Sqlite3.open(path)

    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")
    :ok = Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL;")
    :ok = Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY;")
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON;")
    :ok = create_schema(conn)
    :ok = migrate(conn)

    {:ok, %{conn: conn, path: path}}
  end

  @impl GenServer
  def terminate(_reason, %{conn: conn}) do
    _ = Sqlite3.close(conn)
    :ok
  end

  defp create_schema(conn) do
    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS tracks (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        title       TEXT NOT NULL,
        artist      TEXT,
        album       TEXT,
        duration_ms INTEGER,
        sha256      TEXT NOT NULL UNIQUE,
        ingested_at TEXT NOT NULL
      );
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS fingerprints (
        hash     INTEGER NOT NULL,
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        anchor_t INTEGER NOT NULL
      );
      """)

    :ok =
      Sqlite3.execute(
        conn,
        "CREATE INDEX IF NOT EXISTS fingerprints_hash ON fingerprints(hash);"
      )

    :ok
  end

  # Add columns introduced after the initial schema. SQLite's ALTER TABLE
  # ADD COLUMN doesn't have an IF NOT EXISTS form, so we introspect via
  # PRAGMA table_info and add only what's missing. This keeps the
  # migration idempotent and preserves existing indexes.
  defp migrate(conn) do
    additions = [
      {"track_number", "INTEGER"},
      {"source_path", "TEXT"},
      {"source_size", "INTEGER"},
      {"source_mtime", "INTEGER"}
    ]

    existing = column_names(conn, "tracks")

    Enum.each(additions, fn {name, type} ->
      unless name in existing do
        :ok = Sqlite3.execute(conn, "ALTER TABLE tracks ADD COLUMN #{name} #{type};")
      end
    end)

    :ok =
      Sqlite3.execute(conn, """
      CREATE INDEX IF NOT EXISTS tracks_source
        ON tracks(source_path, source_size, source_mtime);
      """)

    :ok
  end

  defp column_names(conn, table) do
    {:ok, stmt} = Sqlite3.prepare(conn, "PRAGMA table_info(#{table});")
    rows = drain(conn, stmt, [])
    :ok = Sqlite3.release(conn, stmt)
    # PRAGMA table_info returns rows shaped [cid, name, type, notnull, dflt_value, pk]
    Enum.map(rows, fn [_cid, name | _] -> name end)
  end

  # ------------------------------------------------------------------
  # Shazza.Index.Store callbacks
  # ------------------------------------------------------------------

  @impl Shazza.Index.Store
  def put_track(%Track{} = track, fingerprints) do
    GenServer.call(__MODULE__, {:put_track, track, fingerprints}, :infinity)
  end

  @impl Shazza.Index.Store
  def lookup(hash) do
    GenServer.call(__MODULE__, {:lookup, hash})
  end

  @impl Shazza.Index.Store
  def lookup_many(hashes) do
    GenServer.call(__MODULE__, {:lookup_many, hashes})
  end

  @impl Shazza.Index.Store
  def get_track(id) do
    GenServer.call(__MODULE__, {:get_track, id})
  end

  @impl Shazza.Index.Store
  def get_track_by_sha256(sha256) do
    GenServer.call(__MODULE__, {:get_track_by_sha256, sha256})
  end

  @impl Shazza.Index.Store
  def get_track_by_source(path, size, mtime) do
    GenServer.call(__MODULE__, {:get_track_by_source, path, size, mtime})
  end

  @impl Shazza.Index.Store
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ------------------------------------------------------------------
  # GenServer handlers
  # ------------------------------------------------------------------

  @impl GenServer
  def handle_call({:put_track, track, fingerprints}, _from, %{conn: conn} = state) do
    case do_put_track(conn, track, fingerprints) do
      {:ok, _id} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:lookup, hash}, _from, %{conn: conn} = state) do
    {:reply, do_lookup(conn, hash), state}
  end

  def handle_call({:lookup_many, hashes}, _from, %{conn: conn} = state) do
    {:reply, do_lookup_many(conn, hashes), state}
  end

  def handle_call({:get_track, id}, _from, %{conn: conn} = state) do
    {:reply, do_get_track(conn, id), state}
  end

  def handle_call({:get_track_by_sha256, sha256}, _from, %{conn: conn} = state) do
    {:reply, do_get_track_by_sha256(conn, sha256), state}
  end

  def handle_call({:get_track_by_source, path, size, mtime}, _from, %{conn: conn} = state) do
    {:reply, do_get_track_by_source(conn, path, size, mtime), state}
  end

  def handle_call(:reset, _from, %{conn: conn} = state) do
    :ok = Sqlite3.execute(conn, "DELETE FROM fingerprints;")
    :ok = Sqlite3.execute(conn, "DELETE FROM tracks;")
    :ok = Sqlite3.execute(conn, "DELETE FROM sqlite_sequence WHERE name='tracks';")
    {:reply, :ok, state}
  end

  # ------------------------------------------------------------------
  # SQL implementations
  # ------------------------------------------------------------------

  defp do_put_track(conn, %Track{} = track, fingerprints) do
    case do_get_track_by_sha256(conn, track.sha256) do
      {:ok, _existing} ->
        {:error, :already_indexed}

      :error ->
        :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE;")

        try do
          {:ok, id} = insert_track(conn, track)
          :ok = insert_fingerprints(conn, id, fingerprints)
          :ok = Sqlite3.execute(conn, "COMMIT;")
          {:ok, id}
        rescue
          e ->
            :ok = Sqlite3.execute(conn, "ROLLBACK;")
            {:error, e}
        end
    end
  end

  defp insert_track(conn, %Track{} = track) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, """
      INSERT INTO tracks
        (title, artist, album, track_number, duration_ms, sha256,
         source_path, source_size, source_mtime, ingested_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
      """)

    ingested_at =
      (track.ingested_at || DateTime.utc_now())
      |> DateTime.to_iso8601()

    :ok =
      Sqlite3.bind(stmt, [
        track.title,
        track.artist,
        track.album,
        track.track_number,
        track.duration_ms,
        track.sha256,
        track.source_path,
        track.source_size,
        track.source_mtime,
        ingested_at
      ])

    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)

    Sqlite3.last_insert_rowid(conn)
  end

  defp insert_fingerprints(conn, track_id, fingerprints) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "INSERT INTO fingerprints (hash, track_id, anchor_t) VALUES (?1, ?2, ?3);"
      )

    fingerprints
    |> Stream.chunk_every(@insert_chunk)
    |> Enum.each(fn chunk ->
      Enum.each(chunk, fn {hash, anchor_t} ->
        :ok = Sqlite3.bind(stmt, [hash, track_id, anchor_t])
        :done = Sqlite3.step(conn, stmt)
        :ok = Sqlite3.reset(stmt)
      end)
    end)

    :ok = Sqlite3.release(conn, stmt)
  end

  defp do_lookup(conn, hash) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, "SELECT track_id, anchor_t FROM fingerprints WHERE hash = ?1;")

    :ok = Sqlite3.bind(stmt, [hash])
    rows = drain(conn, stmt, [])
    :ok = Sqlite3.release(conn, stmt)
    Enum.map(rows, fn [track_id, anchor_t] -> {track_id, anchor_t} end)
  end

  defp do_lookup_many(conn, hashes) do
    # Build a single IN (?, ?, …) query per chunk so we don't pay
    # round-trip latency per hash. Postings are returned grouped by hash.
    initial = Map.new(hashes, fn h -> {h, []} end)

    hashes
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.reduce(initial, fn chunk, acc ->
      placeholders = chunk |> Enum.map(fn _ -> "?" end) |> Enum.join(",")

      {:ok, stmt} =
        Sqlite3.prepare(
          conn,
          "SELECT hash, track_id, anchor_t FROM fingerprints WHERE hash IN (#{placeholders});"
        )

      :ok = Sqlite3.bind(stmt, chunk)
      rows = drain(conn, stmt, [])
      :ok = Sqlite3.release(conn, stmt)

      Enum.reduce(rows, acc, fn [hash, track_id, anchor_t], inner ->
        Map.update!(inner, hash, fn list -> [{track_id, anchor_t} | list] end)
      end)
    end)
  end

  defp do_get_track(conn, id) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, """
      SELECT id, title, artist, album, track_number, duration_ms, sha256,
             source_path, source_size, source_mtime, ingested_at
      FROM tracks WHERE id = ?1;
      """)

    :ok = Sqlite3.bind(stmt, [id])

    case Sqlite3.step(conn, stmt) do
      {:row, row} ->
        :ok = Sqlite3.release(conn, stmt)
        {:ok, row_to_track(row)}

      :done ->
        :ok = Sqlite3.release(conn, stmt)
        :error
    end
  end

  defp do_get_track_by_sha256(conn, sha256) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, """
      SELECT id, title, artist, album, track_number, duration_ms, sha256,
             source_path, source_size, source_mtime, ingested_at
      FROM tracks WHERE sha256 = ?1;
      """)

    :ok = Sqlite3.bind(stmt, [sha256])

    case Sqlite3.step(conn, stmt) do
      {:row, row} ->
        :ok = Sqlite3.release(conn, stmt)
        {:ok, row_to_track(row)}

      :done ->
        :ok = Sqlite3.release(conn, stmt)
        :error
    end
  end

  defp do_get_track_by_source(conn, path, size, mtime) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, """
      SELECT id, title, artist, album, track_number, duration_ms, sha256,
             source_path, source_size, source_mtime, ingested_at
      FROM tracks
      WHERE source_path = ?1 AND source_size = ?2 AND source_mtime = ?3;
      """)

    :ok = Sqlite3.bind(stmt, [path, size, mtime])

    case Sqlite3.step(conn, stmt) do
      {:row, row} ->
        :ok = Sqlite3.release(conn, stmt)
        {:ok, row_to_track(row)}

      :done ->
        :ok = Sqlite3.release(conn, stmt)
        :error
    end
  end

  defp drain(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> drain(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp row_to_track([
         id,
         title,
         artist,
         album,
         track_number,
         duration_ms,
         sha256,
         source_path,
         source_size,
         source_mtime,
         ingested_at
       ]) do
    {:ok, dt, _offset} = DateTime.from_iso8601(ingested_at)

    %Track{
      id: id,
      title: title,
      artist: artist,
      album: album,
      track_number: track_number,
      duration_ms: duration_ms,
      sha256: sha256,
      source_path: source_path,
      source_size: source_size,
      source_mtime: source_mtime,
      ingested_at: dt
    }
  end
end
