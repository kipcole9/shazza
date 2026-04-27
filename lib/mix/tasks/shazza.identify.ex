defmodule Mix.Tasks.Shazza.Identify do
  @shortdoc "Identify an audio clip against the Shazza index."

  @moduledoc """
  Identify an audio clip against the persistent Shazza index.

  ## Usage

      mix shazza.identify <path> [--db PATH] [--ets] [--min-score N]

  `<path>` is a single audio file. Anything FFmpeg can decode is
  accepted: `.mp3 .m4a .aac .flac .wav .ogg .opus`, plus phone-mic field
  recordings in any of the same formats.

  ## Options

    * `--db PATH` — SQLite database path. Defaults to
      `priv/index.sqlite`. Must point at a database previously populated
      via `mix shazza.ingest`.

    * `--ets` — use the in-memory `Shazza.Index.EtsStore` instead of
      SQLite. Only useful when chained with an ingest in the same BEAM
      session; a fresh `mix shazza.identify --ets` would have an empty
      index.

    * `--min-score N` — minimum histogram peak score required to call
      something a match. Defaults to `5`. Raise it for low-noise studio
      audio; lower it for short or very noisy clips.

  ## Exit codes

    * `0` — match found and printed to stdout.
    * `1` — no match exceeded the score threshold.
    * `2` — decode or pipeline error (e.g. unreadable file).

  ## Examples

      mix shazza.identify ~/Recordings/clip.m4a
      mix shazza.identify clip.wav --db /var/lib/shazza/music.db
      mix shazza.identify quiet.wav --min-score 3
  """

  use Mix.Task

  alias Shazza.CLI.{Format, Stores}

  @switches [db: :string, ets: :boolean, min_score: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _invalid} = OptionParser.parse(argv, switches: @switches)

    path =
      case args do
        [p] ->
          p

        _ ->
          Mix.raise("Usage: mix shazza.identify <path> [--db PATH] [--ets] [--min-score N]")
      end

    unless File.regular?(path) do
      Mix.raise("File not found or not a regular file: #{path}")
    end

    _store = Stores.configure(opts)
    {:ok, _} = Application.ensure_all_started(:shazza)

    case Shazza.identify(path, min_score: Keyword.get(opts, :min_score, 5)) do
      {:ok, result} ->
        Mix.shell().info(Format.match(result, path))
        :ok

      {:error, :no_match} ->
        Mix.shell().info("No match. Try lowering --min-score or re-ingesting the catalog.")
        System.halt(1)

      {:error, reason} ->
        Mix.shell().error("Error identifying #{path}: #{inspect(reason)}")
        System.halt(2)
    end
  end
end
