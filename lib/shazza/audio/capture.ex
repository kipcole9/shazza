defmodule Shazza.Audio.Capture do
  @moduledoc """
  Capture audio from the system microphone via an FFmpeg subprocess.

  The captured audio is written to a temporary `.wav` (mono, 44.1 kHz,
  16-bit PCM) and the path is returned. The caller is responsible for
  deleting the file when done.

  Why a subprocess and not Membrane PortAudio? An 8-second capture
  window is too short for the streaming-pipeline benefits of Membrane
  to matter, and FFmpeg is already in the runtime environment via Xav.
  Adding `:membrane_portaudio_plugin` and friends just for `mix
  shazza.listen` would more than double the build's native-dep surface.

  Per-platform input devices:

    * macOS — `avfoundation`, default audio device `:0`. First run will
      prompt the user to grant microphone access via System Settings.

    * Linux — `pulse`, default audio source.

    * Other — not yet supported. Contributions welcome.
  """

  @type record_options :: [
          device: String.t(),
          output: Path.t(),
          sample_rate: pos_integer()
        ]

  @doc """
  Record `seconds` of audio from the configured input device.

  ### Arguments

  * `seconds` is the capture window in whole seconds.

  ### Options

  * `:device` overrides the platform default. Format is
    platform-specific — for macOS pass an avfoundation device spec like
    `":0"`, for Linux a Pulse source name.

  * `:output` overrides the destination path. Defaults to a unique
    `.wav` under `System.tmp_dir!()`.

  * `:sample_rate` is the WAV sample rate. Defaults to 44_100; Shazza's
    decode pipeline downsamples internally so anything ≥ 8 kHz works.

  ### Returns

  * `{:ok, path}` on success — `path` is the recorded WAV.

  * `{:error, {:ffmpeg_failed, exit_code, output}}` if FFmpeg returned
    non-zero.

  * `{:error, :unsupported_platform}` on operating systems we don't
    have an FFmpeg input device wired up for.
  """
  @spec record(pos_integer(), record_options()) ::
          {:ok, Path.t()} | {:error, term()}
  def record(seconds, options \\ []) when is_integer(seconds) and seconds > 0 do
    output = Keyword.get(options, :output, default_output_path())
    sample_rate = Keyword.get(options, :sample_rate, 44_100)

    case device_args(:os.type(), Keyword.get(options, :device)) do
      {:ok, input_args} ->
        args =
          ["-y", "-loglevel", "error"] ++
            input_args ++
            [
              "-t",
              Integer.to_string(seconds),
              "-ac",
              "1",
              "-ar",
              Integer.to_string(sample_rate),
              output
            ]

        case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
          {_log, 0} -> {:ok, output}
          {log, status} -> {:error, {:ffmpeg_failed, status, String.trim(log)}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp default_output_path do
    Path.join(
      System.tmp_dir!(),
      "shazza-listen-#{System.unique_integer([:positive])}.wav"
    )
  end

  defp device_args({:unix, :darwin}, device) do
    {:ok, ["-f", "avfoundation", "-i", device || ":0"]}
  end

  defp device_args({:unix, _}, device) do
    {:ok, ["-f", "pulse", "-i", device || "default"]}
  end

  defp device_args(_other, _device), do: {:error, :unsupported_platform}
end
