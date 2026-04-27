defmodule Shazza.Match.Result do
  @moduledoc """
  Result of a successful identification.

  * `:track` is the matched `Shazza.Catalog.Track`.

  * `:score` is the count of fingerprints that aligned at the winning time
    offset. Higher means more confident.

  * `:offset_seconds` is where in the original track the query clip is
    estimated to begin.

  * `:second_best_score` is the score of the runner-up track, used as a
    confidence floor — a winning score that barely beats the runner-up is
    not a real match.
  """

  @enforce_keys [:track, :score, :offset_seconds]
  defstruct [:track, :score, :offset_seconds, :second_best_score]

  @type t :: %__MODULE__{
          track: Shazza.Catalog.Track.t(),
          score: non_neg_integer(),
          offset_seconds: float(),
          second_best_score: non_neg_integer() | nil
        }
end
