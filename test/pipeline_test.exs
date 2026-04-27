defmodule Shazza.PipelineTest do
  use ExUnit.Case, async: false

  alias Shazza.TestFixtures

  setup do
    Shazza.Index.EtsStore.reset()
    :ok
  end

  describe "chunked streaming pipeline" do
    test "decodes a multi-chunk track into fixed-shape chunks" do
      chord = TestFixtures.ensure_chord("chord_30s.wav", [440, 660, 880], 30)

      {:ok, %{stream: stream, chunk_samples: cs, overlap_samples: os}} =
        Shazza.Audio.Decoder.stream(chord)

      chunks = Enum.to_list(stream)

      assert length(chunks) >= 3, "expected ≥3 chunks for a 30s file at 10s/chunk"

      # Every chunk has the same tensor shape — that is the whole point of the
      # refactor (EXLA only ever sees one shape).
      shapes = chunks |> Enum.map(& &1.samples) |> Enum.map(&Nx.shape/1) |> Enum.uniq()
      assert shapes == [{cs + os}]

      # Frame offsets are strictly increasing and match `chunk_emit_frames`.
      offsets = Enum.map(chunks, & &1.frame_offset)
      assert offsets == Enum.sort(offsets)
      assert hd(offsets) == 0

      # Exactly one final chunk, and it carries the `last?` flag.
      assert chunks |> Enum.filter(& &1.last?) |> length() == 1
      assert List.last(chunks).last? == true
    end

    test "ingest + self-identify works on a multi-chunk track" do
      chord = TestFixtures.ensure_chord("chord_30s.wav", [440, 660, 880], 30)

      {:ok, :ingested, track} = Shazza.ingest(chord, title: "Chord 30s")
      assert track.duration_ms in 29_000..31_000

      {:ok, result} = Shazza.identify(chord)
      assert result.track.id == track.id
      assert result.score > result.second_best_score * 5
      assert_in_delta result.offset_seconds, 0.0, 0.05
    end

    test "identifies a clip drawn from the second chunk with correct offset" do
      chord = TestFixtures.ensure_chord("chord_30s.wav", [440, 660, 880], 30)
      decoy = TestFixtures.ensure_sine("sine_220.wav", 220, 5)

      {:ok, :ingested, _} = Shazza.ingest(chord, title: "Chord 30s")
      {:ok, :ingested, _} = Shazza.ingest(decoy, title: "Sine 220")

      # Chunk 0 covers seconds 0-10 (with 3.2s overlap into 13.2). Pull a clip
      # from t=15s, which lives entirely inside chunk 1's emit region.
      clip = TestFixtures.clip(chord, "chord_clip_15s_4s.wav", 15.0, 4.0)

      {:ok, result} = Shazza.identify(clip)
      assert result.track.title == "Chord 30s"
      assert_in_delta result.offset_seconds, 15.0, 0.10
      assert result.score > result.second_best_score
    end
  end
end
