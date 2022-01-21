defmodule Membrane.ICE.TURNManager do
  @moduledoc false

  alias Membrane.ICE

  require Membrane.Logger

  @spec ensure_tcp_turn_launched(ICE.Endpoint.integrated_turn_options_t(), Keyword.t()) :: :ok
  def ensure_tcp_turn_launched(turn_options, opts \\ []),
    do: do_ensure_turn_launched(:tcp, turn_options, opts)

  @spec ensure_tls_turn_launched(ICE.Endpoint.integrated_turn_options_t(), Keyword.t()) ::
          :ok | {:error, :lack_of_cert_file_turn_option}
  def ensure_tls_turn_launched(turn_options, opts \\ []) do
    if turn_options[:cert_file] do
      do_ensure_turn_launched(:tls, turn_options, opts)
    else
      {:error, :lack_of_cert_file_turn_option}
    end
  end

  @spec get_launched_turn_servers() :: [any()]
  def get_launched_turn_servers() do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, & &1)
    else
      []
    end
  end

  @spec stop_launched_turn_servers() :: :ok
  def stop_launched_turn_servers() do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, & &1)
      |> Enum.each(&ICE.Utils.stop_integrated_turn/1)
    end

    :ok
  end

  defp do_ensure_turn_launched(transport, turn_options, opts) do
    cond do
      Process.whereis(__MODULE__) == nil ->
        Agent.start_link(
          fn -> ICE.Utils.start_integrated_turn_servers([transport], turn_options, opts) end,
          name: __MODULE__
        )

        :ok

      Agent.get(__MODULE__, & &1) |> Enum.find(&(&1.relay_type == transport)) == nil ->
        turns = ICE.Utils.start_integrated_turn_servers([transport], turn_options, opts)
        Agent.update(__MODULE__, &(turns ++ &1))

      true ->
        :ok
    end
  end
end
