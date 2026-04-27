defmodule Shazza.Audio.Metadata do
  @moduledoc """
  Read container-level tags (ID3, MP4 atoms, Vorbis comments) from an
  audio file via `ffprobe`.

  `ffprobe` ships with FFmpeg, which Shazza already depends on through
  Xav. Shelling out is the pragmatic choice here: parsing every container
  format ourselves would be a significant project, and the cost of a one
  millisecond `ffprobe` call per ingest is invisible against the
  decode + STFT pipeline.

  Returned values are normalised:

    * Trimmed of surrounding whitespace.

    * Empty strings replaced with `nil`.

    * `:track` parsed as an integer (handling the common `"5/12"` form).

  Anything else not covered by the keys we care about is dropped — we
  don't try to be a generic tag library.
  """

  @type tags :: %{
          title: String.t() | nil,
          artist: String.t() | nil,
          album: String.t() | nil,
          track_number: pos_integer() | nil
        }

  @empty %{title: nil, artist: nil, album: nil, track_number: nil}

  @doc """
  Read tags from `path`. Returns `:none` if `ffprobe` fails or the file
  has no usable tags. Never raises.

  ### Arguments

  * `path` is the audio file to probe.

  ### Returns

  * `{:ok, %{title:, artist:, album:, track:}}` when at least one tag is
    present.

  * `:none` when the file has no relevant tags or `ffprobe` is
    unavailable / fails.
  """
  @spec read(Path.t()) :: {:ok, tags()} | :none
  def read(path) do
    args = [
      "-v",
      "error",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      "-i",
      path
    ]

    try do
      case System.cmd("ffprobe", args, stderr_to_stdout: false) do
        {output, 0} ->
          parse(output)

        _ ->
          :none
      end
    rescue
      ErlangError -> :none
    end
  end

  defp parse(json_text) do
    case safe_decode(json_text) do
      {:ok, %{"format" => %{"tags" => raw_tags}} = data} when is_map(raw_tags) ->
        merged = Map.merge(stream_tags(data), raw_tags)
        normalise(merged)

      {:ok, data} ->
        case stream_tags(data) do
          map when map_size(map) > 0 -> normalise(map)
          _ -> :none
        end

      :error ->
        :none
    end
  end

  defp stream_tags(%{"streams" => streams}) when is_list(streams) do
    Enum.reduce(streams, %{}, fn
      %{"tags" => tags}, acc when is_map(tags) -> Map.merge(acc, tags)
      _, acc -> acc
    end)
  end

  defp stream_tags(_), do: %{}

  defp normalise(raw) do
    title = pick(raw, ["title", "TITLE"])
    artist = pick(raw, ["artist", "ARTIST", "album_artist", "ALBUM_ARTIST"])
    album = pick(raw, ["album", "ALBUM"])
    track_number =
      parse_track(pick(raw, ["track", "TRACK", "tracknumber", "TRACKNUMBER"]))

    tags = %{title: title, artist: artist, album: album, track_number: track_number}

    if tags == @empty do
      :none
    else
      {:ok, tags}
    end
  end

  defp pick(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> clean(value)
      end
    end)
  end

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      str -> str
    end
  end

  defp clean(_), do: nil

  defp parse_track(nil), do: nil

  defp parse_track(str) when is_binary(str) do
    [head | _] = String.split(str, "/", parts: 2)

    case Integer.parse(head) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp safe_decode(text) do
    {:ok, :json.decode(text)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
