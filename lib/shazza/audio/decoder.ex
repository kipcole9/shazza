defmodule Shazza.Audio.Decoder do
  @moduledoc """
  Decode an audio file to mono PCM at the configured sample rate, suitable
  for the STFT pipeline.

  Built on top of `Xav`, which wraps FFmpeg as a NIF. The decoder requests
  `:flt` (32-bit interleaved float) PCM, mono, at the configured sample
  rate, so Shazza never touches integer samples or stereo channels.

  Two entry points are provided:

    * `stream/1` returns a lazy `Enumerable` of fixed-size
      `%Shazza.Audio.Chunk{}` blocks. Memory is bounded by the chunk size
      regardless of track length, and EXLA only ever sees one tensor
      shape, which keeps its compile cache from growing across many
      tracks. **This is the path used by ingest and identify.**

    * `decode/1` returns the entire decoded PCM as a single tensor. It is
      kept for tests and for callers that explicitly want the whole track
      in memory; in practice that means short fixtures only.

  Each chunk is `chunk_samples + overlap_samples` PCM samples long. The
  trailing overlap is the configured constellation `target_zone_max_dt`
  worth of audio (in samples), so that anchor peaks near the end of the
  non-overlap region can still pair with targets that fall just past it.
  The final chunk is zero-padded up to the standard size; consumers must
  use `chunk.real_samples` to avoid picking peaks from the padding.
  """

  alias Shazza.Audio.Chunk
  alias Shazza.Config

  @bytes_per_sample 4

  @type decoded :: %{
          samples: Nx.Tensor.t(),
          sample_rate: pos_integer(),
          duration_ms: non_neg_integer()
        }

  @type stream_result :: %{
          stream: Enumerable.t(),
          sample_rate: pos_integer(),
          chunk_samples: pos_integer(),
          overlap_samples: non_neg_integer()
        }

  @doc """
  Stream the file as a lazy sequence of fixed-size `%Shazza.Audio.Chunk{}`
  blocks.

  ### Arguments

  * `path` is the path to any FFmpeg-supported audio file.

  ### Returns

  * `{:ok, %{stream: enumerable, sample_rate: sr, chunk_samples: n,
    overlap_samples: m}}` on success. The enumerable yields
    `%Shazza.Audio.Chunk{}` values.

  * `{:error, reason}` on decode failure.
  """
  @spec stream(Path.t()) :: {:ok, stream_result()} | {:error, term()}
  def stream(path) do
    sample_rate = Config.get(:sample_rate)
    channels = Config.get(:channels)
    chunk_samples = Config.chunk_samples()
    overlap_samples = Config.overlap_samples()
    chunk_emit_frames = Config.chunk_emit_frames()

    chunk_total_samples = chunk_samples + overlap_samples
    chunk_total_bytes = chunk_total_samples * @bytes_per_sample
    advance_bytes = chunk_samples * @bytes_per_sample

    try do
      raw =
        Xav.Reader.stream!(path,
          read: :audio,
          out_format: :flt,
          out_channels: channels,
          out_sample_rate: sample_rate
        )
        |> Stream.map(fn frame ->
          frame |> Xav.Frame.to_nx() |> Nx.flatten() |> Nx.to_binary()
        end)

      enum =
        Stream.transform(
          raw,
          fn -> %{buffer: <<>>, chunk_index: 0} end,
          fn frame_bin, %{buffer: buffer, chunk_index: idx} = state ->
            buffer = buffer <> frame_bin

            {chunks, new_buffer, new_idx} =
              drain_full_chunks(
                buffer,
                idx,
                chunk_total_bytes,
                advance_bytes,
                chunk_samples,
                chunk_total_samples,
                chunk_emit_frames,
                []
              )

            {chunks, %{state | buffer: new_buffer, chunk_index: new_idx}}
          end,
          fn %{buffer: buffer, chunk_index: idx} = state ->
            if buffer == <<>> do
              {[], state}
            else
              real_samples = div(byte_size(buffer), @bytes_per_sample)
              padded = pad_to(buffer, chunk_total_bytes)

              chunk =
                build_chunk(
                  padded,
                  idx,
                  real_samples,
                  real_samples,
                  chunk_total_samples,
                  chunk_emit_frames,
                  true
                )

              {[chunk], %{state | buffer: <<>>, chunk_index: idx + 1}}
            end
          end,
          fn _state -> :ok end
        )

      {:ok,
       %{
         stream: enum,
         sample_rate: sample_rate,
         chunk_samples: chunk_samples,
         overlap_samples: overlap_samples
       }}
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Decode `path` to a single mono PCM tensor at the configured sample rate.

  ### Arguments

  * `path` is the path to any FFmpeg-supported audio file.

  ### Returns

  * `{:ok, %{samples: Nx.Tensor, sample_rate: integer, duration_ms: integer}}`
    on success.

  * `{:error, reason}` on decode failure.
  """
  @spec decode(Path.t()) :: {:ok, decoded()} | {:error, term()}
  def decode(path) do
    sample_rate = Config.get(:sample_rate)
    channels = Config.get(:channels)

    try do
      frames =
        Xav.Reader.stream!(path,
          read: :audio,
          out_format: :flt,
          out_channels: channels,
          out_sample_rate: sample_rate
        )
        |> Enum.map(&Xav.Frame.to_nx/1)

      case frames do
        [] ->
          {:error, :empty_audio}

        frames ->
          samples = frames |> Nx.concatenate() |> Nx.flatten()
          n = Nx.size(samples)
          duration_ms = div(n * 1000, sample_rate)
          {:ok, %{samples: samples, sample_rate: sample_rate, duration_ms: duration_ms}}
      end
    rescue
      e -> {:error, e}
    end
  end

  # ------------------------------------------------------------------
  # Chunk assembly
  # ------------------------------------------------------------------

  defp drain_full_chunks(
         buffer,
         idx,
         chunk_total_bytes,
         advance_bytes,
         chunk_samples,
         chunk_total_samples,
         emit_frames,
         acc
       ) do
    if byte_size(buffer) >= chunk_total_bytes do
      <<chunk_bytes::binary-size(^chunk_total_bytes), _::binary>> = buffer

      chunk =
        build_chunk(
          chunk_bytes,
          idx,
          chunk_total_samples,
          chunk_samples,
          chunk_total_samples,
          emit_frames,
          false
        )

      <<_::binary-size(^advance_bytes), rest::binary>> = buffer

      drain_full_chunks(
        rest,
        idx + 1,
        chunk_total_bytes,
        advance_bytes,
        chunk_samples,
        chunk_total_samples,
        emit_frames,
        [chunk | acc]
      )
    else
      {Enum.reverse(acc), buffer, idx}
    end
  end

  defp build_chunk(
         bytes,
         chunk_index,
         real_samples,
         advance_samples,
         chunk_total_samples,
         emit_frames,
         last?
       ) do
    samples =
      bytes
      |> Nx.from_binary({:f, 32})
      |> Nx.reshape({chunk_total_samples})

    %Chunk{
      samples: samples,
      chunk_index: chunk_index,
      real_samples: real_samples,
      advance_samples: advance_samples,
      frame_offset: chunk_index * emit_frames,
      anchor_max_t: anchor_max_t(real_samples, emit_frames, last?),
      last?: last?
    }
  end

  defp anchor_max_t(_real_samples, emit_frames, false), do: emit_frames

  defp anchor_max_t(real_samples, _emit_frames, true) do
    hop_size = Config.get(:hop_size)
    div(real_samples, hop_size)
  end

  defp pad_to(bytes, target_bytes) do
    deficit = target_bytes - byte_size(bytes)

    if deficit <= 0 do
      bytes
    else
      bytes <> :binary.copy(<<0::32>>, div(deficit, @bytes_per_sample))
    end
  end
end
