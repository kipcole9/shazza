defmodule Shazza.Application do
  @moduledoc false

  use Application

  alias Shazza.Config

  @impl true
  def start(_type, _args) do
    :ok = Shazza.Audio.Silence.install()

    children = [store_child(Config.get(:index_store))]

    Supervisor.start_link(children, strategy: :one_for_one, name: Shazza.Supervisor)
  end

  defp store_child(Shazza.Index.SqliteStore = mod) do
    {mod, [path: Config.get(:sqlite_path)]}
  end

  defp store_child(mod), do: mod
end
