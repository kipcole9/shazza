defmodule Shazza.CLI.Stores do
  @moduledoc false

  # Shared `--db` / `--ets` switch handling for the `mix shazza.*`
  # tasks. Sets the application env so the supervisor brings up the
  # right store, and returns the configured module so callers can
  # pass it explicitly via `:store` if they prefer.

  @doc false
  @spec configure(keyword(), keyword()) :: module()
  def configure(opts, helper_opts \\ []) do
    require_existing? = Keyword.get(helper_opts, :require_existing?, true)

    cond do
      opts[:ets] ->
        Application.put_env(:shazza, :index_store, Shazza.Index.EtsStore)
        Shazza.Index.EtsStore

      true ->
        db = Keyword.get(opts, :db, "priv/index.sqlite")

        if require_existing? and not File.exists?(db) do
          Mix.raise(
            "Database not found at #{db}. Run `mix shazza.ingest <path> --db #{db}` first."
          )
        end

        Application.put_env(:shazza, :index_store, Shazza.Index.SqliteStore)
        Application.put_env(:shazza, :sqlite_path, db)
        Shazza.Index.SqliteStore
    end
  end
end
