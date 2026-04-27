defmodule Shazza.Audio.Chunk do
  @moduledoc """
  One block of PCM produced by `Shazza.Audio.Decoder.stream/1`.

  All chunks have a fixed `:samples` shape so the downstream STFT and peak
  picker compile to a single EXLA program for the whole track. The final
  chunk is zero-padded; consumers must use `:real_samples` and
  `:anchor_max_t` to avoid emitting fingerprints from the padded region.

  ### Fields

  * `:samples` is a 1-D `Nx.Tensor` of `{:f, 32}` PCM samples, length
    `chunk_samples + overlap_samples`.

  * `:chunk_index` is the zero-based chunk number within the track.

  * `:real_samples` is the number of leading samples that came from the
    actual audio. Equal to the full chunk length except on the final
    chunk, which may be shorter.

  * `:advance_samples` is the number of *new* real samples this chunk
    contributes to the global PCM stream. For non-final chunks this is
    `chunk_samples` (the overlap region's samples are also present in
    the next chunk and are counted there); for the final chunk it is
    `:real_samples` outright. Pipeline-level accumulators (running
    SHA-256 of the decoded audio, duration counter) consume exactly
    these leading bytes from each chunk to avoid double-counting the
    overlap.

  * `:frame_offset` is the global STFT frame index of frame zero in this
    chunk's spectrogram. Used to translate per-chunk anchor times into
    track-global anchor times for `Shazza.DSP.Constellation`.

  * `:anchor_max_t` is the (exclusive) upper bound on per-chunk frame
    indices that may serve as anchor peaks. For non-final chunks this is
    the chunk's emit length so that anchors only come from the
    non-overlap region; for the final chunk it is the number of real
    frames.

  * `:last?` is `true` if this is the last chunk in the stream.
  """

  @enforce_keys [
    :samples,
    :chunk_index,
    :real_samples,
    :advance_samples,
    :frame_offset,
    :anchor_max_t,
    :last?
  ]
  defstruct [
    :samples,
    :chunk_index,
    :real_samples,
    :advance_samples,
    :frame_offset,
    :anchor_max_t,
    :last?
  ]

  @type t :: %__MODULE__{
          samples: Nx.Tensor.t(),
          chunk_index: non_neg_integer(),
          real_samples: pos_integer(),
          advance_samples: pos_integer(),
          frame_offset: non_neg_integer(),
          anchor_max_t: non_neg_integer(),
          last?: boolean()
        }
end
