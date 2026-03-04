defmodule Rafute.Supervisor do
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    Supervisor.init([], strategy: :one_for_one)
  end

  def start_server(name, servers) do
    child = %{id: name, start: {Rafute.Server, :start_link, [name, servers]}, restart: :permanent, shutdown: 5000, type: :worker}
    Supervisor.start_child(__MODULE__, child)
  end
end
