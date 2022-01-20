defmodule Membrane.ICE.TURNManager do
  @moduledoc false

  alias Membrane.ICE

  require Membrane.Logger

  @spec launch_tcp_turn(ICE.Endpoint.integrated_turn_options_t()) :: :ok
  def launch_tcp_turn(options), do: do_launch_turn(:tcp, options)

  @spec launch_tls_turn(ICE.Endpoint.integrated_turn_options_t()) :: :ok
  def launch_tls_turn(options), do: do_launch_turn(:tls, options)

  @spec get_launched_turn_servers() :: [any()]
  def get_launched_turn_servers() do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, & &1)
    else
      []
    end
  end

  defp do_launch_turn(transport, options) do
    cond do
      Process.whereis(__MODULE__) == nil ->
        turns = ICE.Utils.start_integrated_turn_servers([transport], options)
        Agent.start_link(fn -> turns end, name: __MODULE__)
        :ok

      Agent.get(__MODULE__, & &1) |> Enum.find(&(&1.relay_type == transport)) == nil ->
        turns = ICE.Utils.start_integrated_turn_servers([transport], options)
        Agent.update(__MODULE__, &(turns ++ &1))

      true ->
        :ok
    end
  end
end
