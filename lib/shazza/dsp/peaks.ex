defmodule Shazza.DSP.Peaks do
  @moduledoc """
  Pick local-maxima peaks from a log-magnitude spectrogram.

  Two filters in sequence:

    1. **Local-maximum filter.** A point `(t, f)` is a candidate if it is
       the maximum value within a `(T_neigh × F_neigh)` rectangular
       neighborhood centred on it. Implemented with `Nx.window_max/2`.

    2. **Adaptive density threshold.** Among candidates, keep the top
       `peak_density_per_second × duration_seconds` by magnitude. This
       normalises peak count across loud/quiet recordings, which is what
       keeps the inverted index balanced.

  Returns a list of `{time_frame, freq_bin}` tuples, sorted by `time_frame`
  ascending, then `freq_bin` ascending. The constellation hasher relies on
  time order to walk forward through anchor peaks efficiently.
  """

  alias Shazza.Config

  @type peak :: {time_frame :: non_neg_integer(), freq_bin :: non_neg_integer()}

  @spec pick(Nx.Tensor.t()) :: [peak()]
  def pick(spectrogram) do
    {neigh_t, neigh_f} = Config.get(:peak_neighborhood)
    density = Config.get(:peak_density_per_second)
    sample_rate = Config.get(:sample_rate)
    hop_size = Config.get(:hop_size)

    {n_frames, _n_bins} = Nx.shape(spectrogram)

    duration_seconds = n_frames * hop_size / sample_rate
    target_count = max(1, round(density * duration_seconds))

    is_local_max = local_max_mask(spectrogram, neigh_t, neigh_f)
    masked = Nx.select(is_local_max, spectrogram, Nx.Constants.neg_infinity({:f, 32}))

    flat = Nx.flatten(masked)
    n_total = Nx.size(flat)
    take = min(target_count, n_total)

    {top_values, top_indices} = Nx.top_k(flat, k: take)

    finite_count =
      top_values
      |> Nx.is_infinity()
      |> Nx.logical_not()
      |> Nx.sum()
      |> Nx.to_number()

    {_n_frames, n_bins} = Nx.shape(spectrogram)

    top_indices
    |> Nx.to_flat_list()
    |> Enum.take(finite_count)
    |> Enum.map(fn idx -> {div(idx, n_bins), rem(idx, n_bins)} end)
    |> Enum.sort()
  end

  defp local_max_mask(spectrogram, neigh_t, neigh_f) do
    # Pad with -inf so window_max at the borders compares against -inf,
    # not zeros, which would falsely mask out real peaks near the edge.
    pad_t = div(neigh_t, 2)
    pad_f = div(neigh_f, 2)
    neg_inf = Nx.Constants.neg_infinity({:f, 32})

    padded =
      Nx.pad(spectrogram, neg_inf, [{pad_t, pad_t, 0}, {pad_f, pad_f, 0}])

    local_max = Nx.window_max(padded, {neigh_t, neigh_f}, strides: [1, 1])

    Nx.equal(spectrogram, local_max)
  end
end
