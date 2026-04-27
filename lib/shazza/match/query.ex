defmodule Shazza.Match.Query do
  @moduledoc """
  Decode → STFT → peak pick → constellation hash → lookup → score, driven
  by `Shazza.Pipeline`.

  The decode/STFT/peaks/hash steps are identical to
  `Shazza.Catalog.Ingest`; the difference is what we do with the
  fingerprints — query hashes are looked up in the index and the resulting
  `(track_id, db_t, query_t)` triples are scored by
  `Shazza.Match.Scorer`.
  """

  alias Shazza.Config
  alias Shazza.Match.{Result, Scorer}
  alias Shazza.Pipeline

  @spec run(Path.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(path, options \\ []) do
    store = Keyword.get(options, :store, Config.get(:index_store))
    min_score = Keyword.get(options, :min_score, 5)

    with {:ok, %{fingerprints: fingerprints, sample_rate: sample_rate}} <-
           Pipeline.fingerprint(path) do
      hashes = Enum.map(fingerprints, fn {hash, _t} -> hash end)
      postings = store.lookup_many(hashes)

      Scorer.best_match(fingerprints, postings, store,
        sample_rate: sample_rate,
        min_score: min_score
      )
    end
  end
end
