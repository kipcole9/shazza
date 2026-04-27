defmodule Shazza.Catalog.Track do
  @moduledoc """
  A track stored in the Shazza index. The `:sha256` field hashes the decoded
  PCM stream and acts as a dedupe key — re-ingesting the same audio is a
  no-op rather than doubling the index.
  """

  @enforce_keys [:id, :title, :sha256]
  defstruct [
    :id,
    :title,
    :artist,
    :album,
    :track_number,
    :duration_ms,
    :sha256,
    :source_path,
    :source_size,
    :source_mtime,
    :ingested_at
  ]

  @type id :: pos_integer()

  @type t :: %__MODULE__{
          id: id(),
          title: String.t(),
          artist: String.t() | nil,
          album: String.t() | nil,
          track_number: pos_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          sha256: String.t(),
          source_path: String.t() | nil,
          source_size: non_neg_integer() | nil,
          source_mtime: integer() | nil,
          ingested_at: DateTime.t() | nil
        }
end
