defmodule Rafute.Backend.Agent do
  alias Rafute.Command

  def start_link() do
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    {__MODULE__, pid}
  end

  def exec(%Command{type: :read, args: {key}}, pid) do
    Agent.get(pid, &Map.get(&1, key))
  end

  def exec(%Command{type: :write, args: {key, value}}, pid) do
    Agent.update(pid, &Map.put(&1, key, value))
  end

  def exec(%Command{type: :c_old_new, args: {_servers, _new_servers}}, _pid) do
    :ok
  end

  def exec(%Command{type: :c_new, args: {_servers, _new_servers}}, _pid) do
    :ok
  end
end
