defmodule Shazza.DSP.Constellation do
  @moduledoc """
  Convert peaks into fingerprint hashes via combinatorial pairing.

  For each anchor peak at `(t_a, f_a)`, look forward in time and pair with
  up to `:fan_out` target peaks `(t_b, f_b)` lying inside the target zone:

    * `dt = t_b - t_a` ∈ `[:target_zone_min_dt, :target_zone_max_dt]`
      (frames)

    * `|f_b - f_a|` ≤ `:target_zone_max_df` Hz, converted to bins given the
      configured sample rate and window size.

  Each pair becomes one fingerprint `{hash, t_a + frame_offset}` where
  `hash` packs `(f_a, f_b, dt)` via `Shazza.DSP.Hash`. Pairs are emitted in
  anchor-time order; within an anchor, target order follows whatever
  `Shazza.DSP.Peaks` produced (time-sorted, then bin-sorted).

  Peaks must be sorted by `time_frame` ascending. `Shazza.DSP.Peaks.pick/1`
  guarantees this.

  ### Chunked pipeline

  When `Shazza.Audio.Decoder.stream/1` feeds the spectrogram in chunks,
  each chunk's peaks live in a per-chunk frame coordinate system. To stitch
  per-chunk peaks back into a track-global frame index, callers pass:

    * `:frame_offset` — added to each anchor's `t_a` before emission, so
      the stored anchor time is global.

    * `:anchor_max_t` — exclusive upper bound on per-chunk anchor frame
      indices. Anchors at `t_a >= anchor_max_t` are skipped because they
      belong to the chunk's overlap region and will reappear (with full
      forward target visibility) as anchors of the next chunk.

  Targets are not bounded by `:anchor_max_t`; an anchor in the
  non-overlap region pairs with targets that may sit in the overlap.
  """

  alias Shazza.Config
  alias Shazza.DSP.Hash
  alias Shazza.Index.Store

  @type options :: [frame_offset: non_neg_integer(), anchor_max_t: non_neg_integer() | :infinity]

  @doc """
  Build fingerprints from a time-sorted list of peaks.

  ### Arguments

  * `peaks` is a list of `{time_frame, freq_bin}` tuples, sorted by
    `time_frame` ascending. `Shazza.DSP.Peaks.pick/1` produces lists in
    this shape.

  ### Options

  * `:frame_offset` is added to each emitted anchor time. Defaults to `0`.

  * `:anchor_max_t` skips any anchor whose per-chunk frame index is `>=`
    this value. Defaults to `:infinity`.

  ### Returns

  * A list of `{hash, anchor_t}` fingerprints. `anchor_t` is in
    track-global coordinates (per-chunk index plus `:frame_offset`).
  """
  @spec hashes([Shazza.DSP.Peaks.peak()], options()) :: [Store.fingerprint()]
  def hashes(peaks, options \\ []) do
    frame_offset = Keyword.get(options, :frame_offset, 0)
    anchor_max_t = Keyword.get(options, :anchor_max_t, :infinity)

    fan_out = Config.get(:fan_out)
    min_dt = Config.get(:target_zone_min_dt)
    max_dt = Config.get(:target_zone_max_dt)
    max_df_hz = Config.get(:target_zone_max_df)
    sample_rate = Config.get(:sample_rate)
    window_size = Config.get(:window_size)

    max_df_bins = max(1, round(max_df_hz * window_size / sample_rate))

    peaks_arr = List.to_tuple(peaks)
    n = tuple_size(peaks_arr)

    Enum.flat_map(0..(n - 1)//1, fn i ->
      {t_a, f_a} = elem(peaks_arr, i)

      if anchor_in_range?(t_a, anchor_max_t) do
        collect_targets(
          peaks_arr,
          i + 1,
          n,
          t_a,
          f_a,
          frame_offset,
          fan_out,
          min_dt,
          max_dt,
          max_df_bins,
          []
        )
      else
        []
      end
    end)
  end

  defp anchor_in_range?(_t_a, :infinity), do: true
  defp anchor_in_range?(t_a, max_t) when is_integer(max_t), do: t_a < max_t

  defp collect_targets(_peaks, _j, _n, _t_a, _f_a, _offset, 0, _min_dt, _max_dt, _max_df, acc),
    do: acc

  defp collect_targets(peaks, j, n, t_a, f_a, offset, remaining, min_dt, max_dt, max_df, acc)
       when j < n do
    {t_b, f_b} = elem(peaks, j)
    dt = t_b - t_a

    cond do
      dt > max_dt ->
        # Beyond the target zone — no later peak can be closer.
        acc

      dt < min_dt ->
        collect_targets(peaks, j + 1, n, t_a, f_a, offset, remaining, min_dt, max_dt, max_df, acc)

      abs(f_b - f_a) > max_df ->
        collect_targets(peaks, j + 1, n, t_a, f_a, offset, remaining, min_dt, max_dt, max_df, acc)

      true ->
        hash = Hash.pack(f_a, f_b, dt)
        acc = [{hash, t_a + offset} | acc]
        collect_targets(peaks, j + 1, n, t_a, f_a, offset, remaining - 1, min_dt, max_dt, max_df, acc)
    end
  end

  defp collect_targets(_peaks, _j, _n, _t_a, _f_a, _offset, _remaining, _min_dt, _max_dt, _max_df, acc),
    do: acc
end
