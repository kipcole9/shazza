ExUnit.start()

defmodule Shazza.TestFixtures do
  @moduledoc """
  Helpers for generating audio fixtures on demand via FFmpeg. Fixtures are
  written under `test/fixtures/` and reused across runs.
  """

  @fixtures_dir Path.join([__DIR__, "fixtures"])

  def fixtures_dir, do: @fixtures_dir

  def ensure_sine(name, freq_hz, duration_seconds) do
    path = Path.join(@fixtures_dir, name)

    if not File.exists?(path) do
      File.mkdir_p!(@fixtures_dir)
      filter = "sine=frequency=#{freq_hz}:sample_rate=44100:duration=#{duration_seconds}"
      args = ["-y", "-loglevel", "error", "-f", "lavfi", "-i", filter, "-ac", "1", path]
      {_, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
    end

    path
  end

  def ensure_chord(name, freqs_hz, duration_seconds) do
    path = Path.join(@fixtures_dir, name)

    if not File.exists?(path) do
      File.mkdir_p!(@fixtures_dir)

      inputs =
        Enum.flat_map(freqs_hz, fn f ->
          ["-f", "lavfi", "-i", "sine=frequency=#{f}:duration=#{duration_seconds}"]
        end)

      filter = "amix=inputs=#{length(freqs_hz)}"

      args =
        ["-y", "-loglevel", "error"] ++
          inputs ++
          ["-filter_complex", filter, "-ac", "1", "-ar", "44100", path]

      {_, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
    end

    path
  end

  def clip(source_path, name, start_seconds, duration_seconds) do
    path = Path.join(@fixtures_dir, name)

    if not File.exists?(path) do
      File.mkdir_p!(@fixtures_dir)

      args = [
        "-y",
        "-loglevel",
        "error",
        "-ss",
        Float.to_string(start_seconds * 1.0),
        "-t",
        Float.to_string(duration_seconds * 1.0),
        "-i",
        source_path,
        path
      ]

      {_, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
    end

    path
  end
end
