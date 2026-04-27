defmodule Shazza.Index.SqliteStoreTest do
  use ExUnit.Case, async: false

  alias Shazza.Index.SqliteStore
  alias Shazza.TestFixtures

  setup do
    # Each test gets its own DB file under tmp/.
    tmp_dir = Path.join(System.tmp_dir!(), "shazza-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    db = Path.join(tmp_dir, "index.sqlite")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, db: db, tmp_dir: tmp_dir}
  end

  test "ingest + identify against SqliteStore", %{db: db} do
    {:ok, pid} = SqliteStore.start_link(path: db)

    sine = TestFixtures.ensure_sine("sine_440.wav", 440, 5)

    {:ok, :ingested, track} = Shazza.ingest(sine, title: "Sine 440", store: SqliteStore)
    assert track.id == 1
    assert track.title == "Sine 440"

    {:ok, result} = Shazza.identify(sine, store: SqliteStore)
    assert result.track.id == track.id
    assert result.score > 100

    stop_supervised_pid(pid)
  end

  test "different path with identical PCM is rejected via SHA-256 of decoded PCM", %{db: db} do
    {:ok, pid} = SqliteStore.start_link(path: db)

    sine = TestFixtures.ensure_sine("sine_440.wav", 440, 5)
    copied = Path.join(System.tmp_dir!(), "shazza_dup_#{System.unique_integer([:positive])}.wav")
    File.cp!(sine, copied)

    try do
      {:ok, :ingested, _track} = Shazza.ingest(sine, title: "First", store: SqliteStore)

      assert {:error, :already_indexed} =
               Shazza.ingest(copied, title: "Second", store: SqliteStore)
    after
      File.rm!(copied)
    end

    stop_supervised_pid(pid)
  end

  test "re-ingesting the same path is an idempotent no-op", %{db: db} do
    {:ok, pid} = SqliteStore.start_link(path: db)

    sine = TestFixtures.ensure_sine("sine_440.wav", 440, 5)
    {:ok, :ingested, first} = Shazza.ingest(sine, title: "First", store: SqliteStore)
    {:ok, :resumed, second} = Shazza.ingest(sine, title: "Second", store: SqliteStore)

    assert second.id == first.id

    stop_supervised_pid(pid)
  end

  test "index survives a GenServer restart on the same file", %{db: db} do
    sine = TestFixtures.ensure_sine("sine_440.wav", 440, 5)

    {:ok, pid1} = SqliteStore.start_link(path: db)
    {:ok, :ingested, t1} = Shazza.ingest(sine, title: "Sine 440", store: SqliteStore)
    stop_supervised_pid(pid1)

    # Fresh GenServer, same file — track and fingerprints must still be there.
    {:ok, pid2} = SqliteStore.start_link(path: db)

    {:ok, t2} = SqliteStore.get_track(t1.id)
    assert t2.sha256 == t1.sha256
    assert t2.title == "Sine 440"

    {:ok, result} = Shazza.identify(sine, store: SqliteStore)
    assert result.track.id == t1.id
    assert result.score > 100

    stop_supervised_pid(pid2)
  end

  defp stop_supervised_pid(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
  end
end
