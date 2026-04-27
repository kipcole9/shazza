defmodule ShazzaTest do
  use ExUnit.Case, async: false

  alias Shazza.TestFixtures

  setup do
    Shazza.Index.EtsStore.reset()
    :ok
  end

  describe "ingest/2 + identify/2" do
    test "self-recognition returns the same track at offset 0" do
      sine = TestFixtures.ensure_sine("sine_440.wav", 440, 5)

      {:ok, :ingested, track} = Shazza.ingest(sine, title: "Sine 440")
      assert track.title == "Sine 440"
      assert track.duration_ms in 4900..5100

      {:ok, result} = Shazza.identify(sine)
      assert result.track.id == track.id
      assert result.score > result.second_best_score * 5
      assert_in_delta result.offset_seconds, 0.0, 0.05
    end

    test "identifies a clipped middle section with non-zero offset" do
      sine_a = TestFixtures.ensure_sine("sine_440.wav", 440, 5)
      sine_b = TestFixtures.ensure_sine("sine_660.wav", 660, 5)

      {:ok, :ingested, _} = Shazza.ingest(sine_a, title: "Sine 440")
      {:ok, :ingested, _} = Shazza.ingest(sine_b, title: "Sine 660")

      clip = TestFixtures.clip(sine_a, "sine_440_clip_2s.wav", 2.0, 2.0)

      {:ok, result} = Shazza.identify(clip)
      assert result.track.title == "Sine 440"
      assert_in_delta result.offset_seconds, 2.0, 0.05
      assert result.score > result.second_best_score * 2
    end

    test "re-ingesting the same path is an idempotent no-op (resume-on-restart)" do
      sine = TestFixtures.ensure_sine("sine_440.wav", 440, 5)
      {:ok, :ingested, first} = Shazza.ingest(sine, title: "Sine 440")
      {:ok, :resumed, second} = Shazza.ingest(sine, title: "Sine 440 (dup)")

      # Same row returned, no second copy.
      assert second.id == first.id
      assert second.title == "Sine 440"
    end

    test "different path with identical PCM is rejected via SHA-256 dedupe" do
      sine = TestFixtures.ensure_sine("sine_440.wav", 440, 5)
      copied = Path.join(System.tmp_dir!(), "shazza_dup_#{System.unique_integer([:positive])}.wav")
      File.cp!(sine, copied)

      try do
        {:ok, :ingested, _} = Shazza.ingest(sine, title: "Original")
        assert {:error, :already_indexed} = Shazza.ingest(copied, title: "Copy")
      after
        File.rm!(copied)
      end
    end
  end
end
