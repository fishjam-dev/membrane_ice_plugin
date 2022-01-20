defmodule Membrane.ICE.CandidatePortAssigner do
  @moduledoc false

  @min_port 40000
  @max_port 65535

  @spec assign_candidate_port() :: {:ok, number()} | {:error, :no_free_candidate_port}
  def assign_candidate_port() do
    if Process.whereis(__MODULE__) == nil,
      do: Registry.start_link(keys: :unique, name: __MODULE__)

    random_port = :rand.uniform(@max_port - @min_port) + @min_port
    do_assign_candidate_port(random_port, 0)
  end

  @spec get_candidate_port_owner(number()) ::
          {:ok, pid()} | {:error, :candidate_port_owner_not_alive}
  def get_candidate_port_owner(port) do
    if Process.whereis(__MODULE__) == nil do
      {:error, :candidate_owner_not_alive}
    else
      case Registry.lookup(__MODULE__, port) do
        [{pid, nil}] -> {:ok, pid}
        [] -> {:error, :candidate_owner_not_alive}
      end
    end
  end

  defp do_assign_candidate_port(current_port, counter) do
    case Registry.register(__MODULE__, current_port, nil) do
      {:ok, _pid} ->
        {:ok, current_port}

      {:error, {:already_registered, _pid}} ->
        cond do
          counter == @max_port - @min_port ->
            {:error, :no_free_candidate_port}

          current_port == @max_port ->
            do_assign_candidate_port(@min_port, counter + 1)

          true ->
            do_assign_candidate_port(current_port + 1, counter + 1)
        end
    end
  end
end
