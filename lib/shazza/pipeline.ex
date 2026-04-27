defmodule Shazza.Pipeline do
  @moduledoc """
  The shared chunked fingerprinting pipeline used by both
  `Shazza.Catalog.Ingest` and `Shazza.Match.Query`.

  Decodes `path` as a stream of fixed-size `Shazza.Audio.Chunk` blocks,
  runs each block through STFT → peak picking → constellation hashing,
  and accumulates global fingerprints, a streaming SHA-256 of the
  decoded PCM, and a real-sample count for the duration.

  Memory is bounded by one chunk's worth of audio plus the running
  fingerprint list. EXLA only ever sees one tensor shape per chunk, so
  its compile cache stays the same across however many tracks are
  ingested in a single BEAM session.
  """

  alias Shazza.Audio.{Chunk, Decoder}
  alias Shazza.Config
  alias Shazza.DSP.{Constellation, Peaks, STFT}
  alias Shazza.Index.Store

  @bytes_per_sample 4

  @type result :: %{
          fingerprints: [Store.fingerprint()],
          sha256: String.t(),
          duration_ms: non_neg_integer(),
          sample_rate: pos_integer()
        }

  @doc """
  Run the full pipeline over `path` and return its global fingerprints,
  PCM SHA-256, and duration.

  ### Arguments

  * `path` is the path to any FFmpeg-supported audio file.

  ### Returns

  * `{:ok, %{fingerprints: list, sha256: hex_string, duration_ms: int,
    sample_rate: int}}` on success.

  * `{:error, reason}` on decode or pipeline failure.
  """
  @spec fingerprint(Path.t()) :: {:ok, result()} | {:error, term()}
  def fingerprint(path) do
    with {:ok, %{stream: stream, sample_rate: sample_rate}} <- Decoder.stream(path) do
      try do
        initial = %{
          sha: :crypto.hash_init(:sha256),
          total_samples: 0,
          fingerprints: []
        }

        final =
          stream
          |> Enum.reduce(initial, &process_chunk/2)

        sha256 =
          final.sha
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok,
         %{
           fingerprints: Enum.reverse(final.fingerprints),
           sha256: sha256,
           duration_ms: div(final.total_samples * 1000, sample_rate),
           sample_rate: sample_rate
         }}
      rescue
        e -> {:error, e}
      end
    end
  end

  defp process_chunk(%Chunk{} = chunk, acc) do
    advance_bytes = advance_pcm_bytes(chunk)

    fingerprints_for_chunk =
      chunk.samples
      |> STFT.spectrogram()
      |> Peaks.pick()
      |> Constellation.hashes(
        frame_offset: chunk.frame_offset,
        anchor_max_t: chunk.anchor_max_t
      )

    %{
      acc
      | sha: :crypto.hash_update(acc.sha, advance_bytes),
        total_samples: acc.total_samples + chunk.advance_samples,
        # Prepend so we can reverse once at the end. List concatenation per
        # chunk would be O(n²) over the track.
        fingerprints: prepend_all(fingerprints_for_chunk, acc.fingerprints)
    }
  end

  # Take only the leading `:advance_samples` worth of bytes from the chunk —
  # the rest is either overlap (real audio that will be re-counted via the
  # next chunk's advance region) or zero-padding on the final chunk.
  defp advance_pcm_bytes(%Chunk{} = chunk) do
    advance_byte_size = chunk.advance_samples * @bytes_per_sample
    full = Nx.to_binary(chunk.samples)
    binary_part(full, 0, advance_byte_size)
  end

  defp prepend_all([], acc), do: acc
  defp prepend_all([head | tail], acc), do: prepend_all(tail, [head | acc])

  @doc false
  def expected_chunk_layout do
    %{
      chunk_samples: Config.chunk_samples(),
      overlap_samples: Config.overlap_samples(),
      chunk_emit_frames: Config.chunk_emit_frames()
    }
  end
end
