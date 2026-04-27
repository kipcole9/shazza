defmodule Shazza.Match.Scorer do
  @moduledoc """
  Score query/index fingerprint matches via a per-track time-offset
  histogram (Wang 2003).

  For every query fingerprint `{hash, query_t}` and every matching posting
  `{track_id, db_t}`:

    * compute `delta = db_t - query_t`,

    * bucket `(track_id, delta)` and tally.

  The track with the tallest bucket wins; the count in that bucket is the
  match score, and `delta` translated back to seconds is where in the
  original track the query clip starts.

  We also surface the runner-up track's best-bucket score so callers can
  apply a confidence floor — a winning score that barely beats the next
  best track is unreliable.
  """

  alias Shazza.Config
  alias Shazza.Index.Store
  alias Shazza.Match.Result

  @spec best_match([Store.fingerprint()], %{Store.hash() => [Store.posting()]}, module(), keyword()) ::
          {:ok, Result.t()} | {:error, :no_match}
  def best_match(query_fingerprints, postings, store, options) do
    sample_rate = Keyword.fetch!(options, :sample_rate)
    min_score = Keyword.get(options, :min_score, 5)

    histogram = build_histogram(query_fingerprints, postings)

    case top_two(histogram) do
      [] ->
        {:error, :no_match}

      [{{track_id, delta}, score} | rest] when score >= min_score ->
        {:ok, track} = store.get_track(track_id)
        seconds_per_frame = Config.get(:hop_size) / sample_rate

        {:ok,
         %Result{
           track: track,
           score: score,
           offset_seconds: delta * seconds_per_frame,
           second_best_score: runner_up_score(rest, track_id)
         }}

      _ ->
        {:error, :no_match}
    end
  end

  defp build_histogram(query_fingerprints, postings) do
    Enum.reduce(query_fingerprints, %{}, fn {hash, query_t}, acc ->
      case Map.get(postings, hash, []) do
        [] ->
          acc

        matches ->
          Enum.reduce(matches, acc, fn {track_id, db_t}, acc2 ->
            Map.update(acc2, {track_id, db_t - query_t}, 1, &(&1 + 1))
          end)
      end
    end)
  end

  defp top_two(histogram) do
    histogram
    |> Enum.sort_by(fn {_key, count} -> -count end)
    |> Enum.take(20)
  end

  defp runner_up_score(rest, winning_track_id) do
    rest
    |> Enum.find(fn {{track_id, _delta}, _score} -> track_id != winning_track_id end)
    |> case do
      nil -> 0
      {{_id, _delta}, score} -> score
    end
  end
end
