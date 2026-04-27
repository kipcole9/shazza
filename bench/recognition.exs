# Recognition recall sweep: clip-length × SNR
#
# Cuts clips from a track that's already in the index, mixes white noise
# at varying signal-to-noise ratios, and runs each through
# `Shazza.identify`. Reports recall, offset error, and score per cell so
# you can see how the algorithm degrades under noise.
#
# Usage:
#
#     mix run bench/recognition.exs --db priv/music.db --track-id 1 --repeats 3
#
# `--track-id` selects which track in the database to query against. The
# track must have a usable `source_path` (post-resume-on-restart ingests
# do; legacy rows from before that schema migration may not — re-ingest).

defmodule Bench.Recognition do
  alias Shazza.Index.SqliteStore

  @clip_lengths [3, 5, 10]
  # SNR in dB → linear noise factor against a signal whose RMS we treat as 1.
  # ∞ dB is the no-noise control.
  @snr_db [{:clean, nil}, {30, 0.0316}, {20, 0.1}, {10, 0.316}, {5, 0.562}, {0, 1.0}]

  def main(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        switches: [db: :string, track_id: :integer, repeats: :integer]
      )

    db = Keyword.get(opts, :db, "priv/index.sqlite")
    track_id = Keyword.get(opts, :track_id, 1)
    repeats = Keyword.get(opts, :repeats, 3)

    unless File.exists?(db) do
      IO.puts("Database not found at #{db}.")
      System.halt(1)
    end

    Application.put_env(:shazza, :index_store, SqliteStore)
    Application.put_env(:shazza, :sqlite_path, db)
    {:ok, _} = Application.ensure_all_started(:shazza)

    # `mix run` boots :shazza with the default EtsStore from config/config.exs
    # before this script runs, so the SqliteStore GenServer isn't up yet.
    # Stop the default and bring up SqliteStore against the requested DB.
    if pid = Process.whereis(Shazza.Index.EtsStore) do
      Process.exit(pid, :normal)
      :ok = wait_for_exit(pid)
    end

    {:ok, _} = SqliteStore.start_link(path: db)

    track =
      case SqliteStore.get_track(track_id) do
        {:ok, t} ->
          t

        :error ->
          IO.puts("Track ##{track_id} not found in #{db}.")
          System.halt(1)
      end

    if is_nil(track.source_path) do
      IO.puts(
        "Track ##{track_id} has no source_path on file (legacy ingest). " <>
          "Re-ingest the track with the current schema."
      )

      System.halt(1)
    end

    unless File.regular?(track.source_path) do
      IO.puts("Source audio missing: #{track.source_path}")
      System.halt(1)
    end

    IO.puts("Bench: track ##{track.id} \"#{track.title}\" (#{format_ms(track.duration_ms)})")
    IO.puts("Source: #{track.source_path}")
    IO.puts("Repeats per cell: #{repeats}\n")

    rows =
      for length <- @clip_lengths,
          {snr_label, noise_factor} <- @snr_db do
        results =
          for _rep <- 1..repeats do
            run_one(track, length, noise_factor)
          end

        summarise(length, snr_label, results)
      end

    IO.puts(format_table(rows))
  end

  defp run_one(track, clip_length, noise_factor) do
    duration_seconds = max(clip_length + 1, div(track.duration_ms, 1000))
    max_offset = max(0, duration_seconds - clip_length - 1)
    offset = if max_offset > 0, do: :rand.uniform(max_offset) - 1, else: 0

    clean_path = tmp_wav("clean")
    final_path = tmp_wav("noisy")

    try do
      :ok = cut_clip(track.source_path, clean_path, offset, clip_length)

      :ok =
        case noise_factor do
          nil ->
            File.cp!(clean_path, final_path)
            :ok

          factor ->
            mix_white_noise(clean_path, final_path, clip_length, factor)
        end

      case Shazza.identify(final_path) do
        {:ok, %Shazza.Match.Result{} = result} ->
          %{
            matched?: result.track.id == track.id,
            requested_offset: offset,
            measured_offset: result.offset_seconds,
            score: result.score
          }

        {:error, _reason} ->
          %{matched?: false, requested_offset: offset, measured_offset: nil, score: 0}
      end
    after
      File.rm(clean_path)
      File.rm(final_path)
    end
  end

  defp summarise(length, snr_label, results) do
    n = length(results) |> max(1)
    matched = Enum.count(results, & &1.matched?)
    recall = matched / n

    score_avg =
      results
      |> Enum.map(& &1.score)
      |> avg()

    offset_err =
      results
      |> Enum.filter(& &1.matched?)
      |> Enum.map(fn r -> abs(r.measured_offset - r.requested_offset) end)
      |> avg()

    %{
      clip_seconds: length,
      snr: snr_label,
      recall: recall,
      score: score_avg,
      offset_err: offset_err,
      n: n
    }
  end

  defp avg([]), do: nil
  defp avg(list), do: Enum.sum(list) / length(list)

  defp format_table(rows) do
    header = """
    | clip (s) | SNR (dB) |  recall | avg score | avg offset err (s) |
    |---------:|---------:|--------:|----------:|-------------------:|
    """

    body =
      rows
      |> Enum.map(fn r ->
        snr_str =
          case r.snr do
            :clean -> "  ∞"
            n -> :io_lib.format("~3B", [n]) |> IO.iodata_to_binary()
          end

        recall_str = :io_lib.format("~5.1f%", [r.recall * 100]) |> IO.iodata_to_binary()
        score_str = number_or_dash(r.score, "~7.1f")
        err_str = number_or_dash(r.offset_err, "~7.3f")

        "| #{pad_left(Integer.to_string(r.clip_seconds), 8)} | #{pad_left(snr_str, 8)} | #{pad_left(recall_str, 7)} | #{pad_left(score_str, 9)} | #{pad_left(err_str, 18)} |"
      end)
      |> Enum.join("\n")

    header <> body <> "\n"
  end

  defp number_or_dash(nil, _fmt), do: "—"

  defp number_or_dash(num, fmt) do
    fmt |> :io_lib.format([num]) |> IO.iodata_to_binary() |> String.trim_leading()
  end

  defp pad_left(str, width) do
    deficit = width - String.length(str)
    if deficit > 0, do: String.duplicate(" ", deficit) <> str, else: str
  end

  defp cut_clip(source, dest, offset_seconds, length_seconds) do
    args = [
      "-y",
      "-loglevel",
      "error",
      "-ss",
      Integer.to_string(offset_seconds),
      "-t",
      Integer.to_string(length_seconds),
      "-i",
      source,
      "-ac",
      "1",
      "-ar",
      "44100",
      dest
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:ffmpeg_failed, status, output}}
    end
  end

  defp mix_white_noise(clean, dest, length_seconds, noise_factor) do
    filter =
      "[0:a]volume=1.0[s];" <>
        "[1:a]volume=#{Float.to_string(noise_factor)}[n];" <>
        "[s][n]amix=inputs=2:duration=first:dropout_transition=0:normalize=0"

    args = [
      "-y",
      "-loglevel",
      "error",
      "-i",
      clean,
      "-f",
      "lavfi",
      "-i",
      "anoisesrc=duration=#{length_seconds}:color=white:seed=#{:rand.uniform(1_000_000)}",
      "-filter_complex",
      filter,
      "-ac",
      "1",
      "-ar",
      "44100",
      dest
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:ffmpeg_failed, status, output}}
    end
  end

  defp tmp_wav(label) do
    Path.join(
      System.tmp_dir!(),
      "shazza-bench-#{label}-#{System.unique_integer([:positive])}.wav"
    )
  end

  defp format_ms(nil), do: "—"

  defp format_ms(ms) do
    minutes = div(ms, 60_000)
    seconds = ms |> rem(60_000) |> div(1000)
    :io_lib.format("~B:~2..0B", [minutes, seconds]) |> IO.iodata_to_binary()
  end

  defp wait_for_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end
end

Bench.Recognition.main(System.argv())
