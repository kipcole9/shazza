defmodule Shazza.CLI.Format do
  @moduledoc false

  # Pretty-printing helpers shared between the `mix shazza.identify` and
  # `mix shazza.listen` tasks. Pure formatting only — no I/O.

  alias Shazza.Match.Result

  @doc false
  @spec match(Result.t(), Path.t()) :: String.t()
  def match(%Result{} = result, query_path) do
    track = result.track
    confidence = confidence_label(result.score, result.second_best_score)

    """

    Identified: #{header(track)}
      album:    #{track.album || "—"}
      score:    #{result.score}  (runner-up: #{result.second_best_score || 0}, #{confidence})
      offset:   #{format_seconds(result.offset_seconds)} into the track
      duration: #{format_ms(track.duration_ms)}
      track id: ##{track.id}
      query:    #{relative(query_path)}
    """
  end

  defp header(track) do
    case track.artist do
      nil -> track.title
      "" -> track.title
      artist -> "#{artist} — #{track.title}"
    end
  end

  defp confidence_label(score, runner_up) do
    runner_up = runner_up || 0

    cond do
      runner_up == 0 and score >= 5 -> "high confidence"
      runner_up > 0 and score >= runner_up * 5 -> "high confidence"
      runner_up > 0 and score >= runner_up * 2 -> "moderate confidence"
      true -> "low confidence"
    end
  end

  defp format_seconds(seconds) when is_number(seconds) do
    seconds |> Kernel.*(1000) |> round() |> format_ms()
  end

  @doc false
  @spec format_ms(non_neg_integer() | nil) :: String.t()
  def format_ms(nil), do: "—"

  def format_ms(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    seconds = ms |> rem(60_000) |> div(1000)
    centis = ms |> rem(1000) |> div(10)

    [minutes, seconds, centis]
    |> then(&:io_lib.format("~B:~2..0B.~2..0B", &1))
    |> IO.iodata_to_binary()
  end

  defp relative(path) do
    try do
      Path.relative_to_cwd(path)
    rescue
      _ -> path
    end
  end
end
