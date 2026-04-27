defmodule Shazza.DSP.STFT do
  @moduledoc """
  Short-time Fourier transform of a 1-D PCM tensor.

  Returns a 2-D **log-magnitude** spectrogram of shape `{n_frames, n_bins}`
  where `n_bins = window_size / 2` (the real-FFT bins, excluding both the
  redundant negative-frequency mirror and the Nyquist bin so that all bin
  indices fit in the 9-bit hash field). Phase is discarded.

  Window: Hann, periodic.
  Window/hop: read from `Shazza.Config` (`:window_size`, `:hop_size`).
  Underlying transform: `NxSignal.stft/3`.

  Log-magnitude is `log10(|X| + eps)` with a small `eps` to keep silence
  finite. Peak picking later operates on this log-scaled grid.
  """

  alias Shazza.Config

  @log_eps 1.0e-10

  @doc """
  Compute the log-magnitude spectrogram for `samples`.

  ### Arguments

  * `samples` is a 1-D `Nx.Tensor` of float PCM samples.

  ### Returns

  * `Nx.Tensor` of shape `{n_frames, n_bins}`, dtype `{:f, 32}`.
  """
  @spec spectrogram(Nx.Tensor.t()) :: Nx.Tensor.t()
  def spectrogram(samples) do
    window_size = Config.get(:window_size)
    hop_size = Config.get(:hop_size)
    sample_rate = Config.get(:sample_rate)

    overlap_length = window_size - hop_size
    window = NxSignal.Windows.hann(window_size, is_periodic: true)

    {complex, _times, _freqs} =
      NxSignal.stft(samples, window,
        overlap_length: overlap_length,
        fft_length: window_size,
        sampling_rate: sample_rate,
        window_padding: :valid
      )

    n_bins = div(window_size, 2)

    complex
    |> Nx.slice_along_axis(0, n_bins, axis: 1)
    |> Nx.abs()
    |> Nx.add(@log_eps)
    |> Nx.log()
    |> Nx.divide(:math.log(10.0))
  end
end
