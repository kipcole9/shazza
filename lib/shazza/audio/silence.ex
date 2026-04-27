defmodule Shazza.Audio.Silence do
  @moduledoc """
  Quiet libav's stderr chatter via a small NIF wrapping
  `av_log_set_level()`.

  By default libavformat / libavcodec emit `AV_LOG_INFO` lines like
  `[mp3 @ ...] Estimating duration from bitrate, this may be inaccurate`
  to fd 2. Those messages come from the C side of Xav's NIF, so they
  bypass Elixir's IO redirection — the only way to silence them in-process
  is to call `av_log_set_level()` from C.

  The application supervisor calls `install/0` at boot. If the NIF
  fails to load (FFmpeg headers not found at compile time, NIF binary
  missing, etc.) it logs a single warning and proceeds — the messages are
  noisy but not fatal.
  """

  @compile {:autoload, false}
  @on_load :load_nif

  require Logger

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:shazza), ~c"libav_silence")

    case :erlang.load_nif(path, 0) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Shazza.Audio.Silence NIF not loaded: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Silence libav's INFO/WARNING/ERROR/FATAL output. Returns `:ok` whether
  or not the NIF actually loaded — if it didn't, this is a no-op.
  """
  @spec install() :: :ok
  def install do
    try do
      set_quiet()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # NIF stubs. Real bodies live in c_src/av_silence.c; these clauses run
  # only if the NIF binary failed to load.

  @doc false
  def set_quiet, do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def set_error, do: :erlang.nif_error(:nif_not_loaded)
end
