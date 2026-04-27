defmodule Mix.Tasks.Shazza.Ingest do
  @shortdoc "Ingest one or more audio files into the Shazza index."

  @moduledoc """
  Ingest audio into the persistent Shazza index.

  ## Usage

      mix shazza.ingest <path> [--db PATH] [--ets]

  `<path>` is either an audio file or a directory. Directories are walked
  recursively and any file whose extension matches one of the recognised
  audio types is ingested.

  Recognised extensions: `.mp3 .m4a .aac .flac .wav .ogg .opus`.

  ## Options

    * `--db PATH` — SQLite database path. Defaults to `priv/index.sqlite`.

    * `--ets` — use the in-memory `Shazza.Index.EtsStore` instead of
      SQLite. Only useful for benchmarking, since the index is lost when
      the BEAM exits.

  ## Examples

      mix shazza.ingest ~/Music
      mix shazza.ingest song.mp3 --db /var/lib/shazza/music.db
  """

  use Mix.Task

  @audio_extensions ~w(.mp3 .m4a .aac .flac .wav .ogg .opus)

  @switches [db: :string, ets: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    path =
      case args do
        [p] ->
          p

        _ ->
          Mix.raise("Usage: mix shazza.ingest <path> [--db PATH] [--ets]")
      end

    store = configure_store(opts)
    {:ok, _} = Application.ensure_all_started(:shazza)

    files = collect_files(path)

    if files == [] do
      Mix.shell().info("No audio files found under #{path}.")
    else
      Mix.shell().info("Ingesting #{length(files)} file(s) into #{inspect(store)}...")

      summary =
        Enum.reduce(files, %{ingested: 0, resumed: 0, dup: 0, error: 0}, &ingest_one(&1, store, &2))

      Mix.shell().info("""

      Done.
        ingested:   #{summary.ingested}
        resumed:    #{summary.resumed}
        duplicates: #{summary.dup}
        errors:     #{summary.error}
      """)
    end
  end

  defp configure_store(opts) do
    cond do
      opts[:ets] ->
        Application.put_env(:shazza, :index_store, Shazza.Index.EtsStore)
        Shazza.Index.EtsStore

      true ->
        db = Keyword.get(opts, :db, "priv/index.sqlite")
        Application.put_env(:shazza, :index_store, Shazza.Index.SqliteStore)
        Application.put_env(:shazza, :sqlite_path, db)
        Shazza.Index.SqliteStore
    end
  end

  defp collect_files(path) do
    cond do
      File.dir?(path) ->
        path
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&audio_file?/1)
        |> Enum.sort()

      File.regular?(path) ->
        if audio_file?(path), do: [path], else: []

      true ->
        Mix.raise("Path not found: #{path}")
    end
  end

  defp audio_file?(path) do
    File.regular?(path) and String.downcase(Path.extname(path)) in @audio_extensions
  end

  defp ingest_one(file, store, summary) do
    label = Path.relative_to_cwd(file)

    case Shazza.ingest(file, store: store) do
      {:ok, :ingested, track} ->
        Mix.shell().info("  ok      #{format_track(track)}  ←  #{label}")
        Map.update!(summary, :ingested, &(&1 + 1))

      {:ok, :resumed, track} ->
        Mix.shell().info("  resume  #{format_track(track)}  ←  #{label}")
        Map.update!(summary, :resumed, &(&1 + 1))

      {:error, :already_indexed} ->
        Mix.shell().info("  dup     #{label}  (PCM already in index)")
        Map.update!(summary, :dup, &(&1 + 1))

      {:error, reason} ->
        Mix.shell().error("  error   #{label}  →  #{inspect(reason)}")
        Map.update!(summary, :error, &(&1 + 1))
    end
  end

  defp format_track(track) do
    label =
      case track.artist do
        nil -> track.title
        "" -> track.title
        artist -> "#{artist} — #{track.title}"
      end

    "##{track.id}  #{label}"
  end
end
