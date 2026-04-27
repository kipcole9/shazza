defmodule Mix.Tasks.Shazza.Listen do
  @shortdoc "Capture audio from the system microphone and identify it."

  @moduledoc """
  Capture `--seconds` of audio from the default system microphone, then
  identify it against the persistent Shazza index.

  ## Usage

      mix shazza.listen [--seconds N] [--db PATH] [--ets] [--min-score N] \\
                        [--device DEV] [--keep]

  ## Options

    * `--seconds N` — capture window length in whole seconds. Defaults
      to `8`. Shorter clips run the pipeline faster but produce weaker
      matches; 5-10 seconds is the sweet spot for clean audio.

    * `--db PATH` — SQLite database path. Defaults to
      `priv/index.sqlite`. Must already have been populated via
      `mix shazza.ingest`.

    * `--ets` — use the in-memory `Shazza.Index.EtsStore` instead of
      SQLite. Empty unless ingest has been run in the same BEAM
      session.

    * `--min-score N` — minimum histogram peak score required to call
      something a match. Defaults to `5`.

    * `--device DEV` — override the platform input device. macOS:
      avfoundation device spec like `":0"` (default), `":1"`, etc.
      Linux: a Pulse source name (`default`, etc.). Run
      `ffmpeg -f avfoundation -list_devices true -i ""` on Mac to see
      available devices.

    * `--keep` — do not delete the temp `.wav` after identification.
      Useful for debugging — the printed path can be replayed via
      `mix shazza.identify`.

  ## Permissions

  On macOS the first call to this task will trigger the system
  microphone-access prompt. Grant permission to your terminal (or to
  the Elixir / Erlang process, depending on macOS version) via System
  Settings → Privacy & Security → Microphone.

  ## Exit codes

    * `0` — match identified.
    * `1` — no match exceeded the score threshold.
    * `2` — capture or pipeline error.

  ## Examples

      mix shazza.listen --db priv/music.db
      mix shazza.listen --seconds 5 --min-score 3
      mix shazza.listen --device ":1" --keep
  """

  use Mix.Task

  alias Shazza.Audio.Capture
  alias Shazza.CLI.{Format, Stores}

  @switches [
    seconds: :integer,
    db: :string,
    ets: :boolean,
    min_score: :integer,
    device: :string,
    keep: :boolean
  ]

  @default_seconds 8

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, switches: @switches)

    seconds = Keyword.get(opts, :seconds, @default_seconds)
    keep? = Keyword.get(opts, :keep, false)

    if seconds <= 0 or seconds > 60 do
      Mix.raise("`--seconds` must be between 1 and 60. Got #{seconds}.")
    end

    _store = Stores.configure(opts)
    {:ok, _} = Application.ensure_all_started(:shazza)

    Mix.shell().info("Listening on default mic for #{seconds}s...")

    case Capture.record(seconds, device: Keyword.get(opts, :device)) do
      {:ok, path} ->
        identify_and_cleanup(path, opts, keep?)

      {:error, :unsupported_platform} ->
        Mix.raise(
          "mix shazza.listen does not yet support this OS. " <>
            "Patches welcome — see Shazza.Audio.Capture."
        )

      {:error, {:ffmpeg_failed, status, log}} ->
        Mix.shell().error("FFmpeg capture failed (exit #{status}):\n#{log}")
        System.halt(2)
    end
  end

  defp identify_and_cleanup(path, opts, keep?) do
    Mix.shell().info("Captured #{Path.basename(path)}, fingerprinting...")

    result = Shazza.identify(path, min_score: Keyword.get(opts, :min_score, 5))

    cleanup(path, keep?)

    case result do
      {:ok, match} ->
        Mix.shell().info(Format.match(match, path))
        :ok

      {:error, :no_match} ->
        Mix.shell().info("No match. Try lowering --min-score or re-ingesting the catalog.")
        System.halt(1)

      {:error, reason} ->
        Mix.shell().error("Error identifying recording: #{inspect(reason)}")
        System.halt(2)
    end
  end

  defp cleanup(_path, true), do: :ok
  defp cleanup(path, false), do: File.rm(path)
end
