defmodule Membrane.ICE.TURNCleaner do
  @moduledoc """
  Integrated TURN cleaner.

  It monitors given process and when it exits, stops Integrated TURN.
  """
  use GenServer, restart: :transient

  @typedoc """
  * `pid` - pid to monitor
  * `turn` - TURN server to terminate when process with pid `pid` exits
  """
  @type init_arg() :: [pid: pid(), turn: map()]

  @doc """
  Starts and links Integrated TURN cleaner to calling process.
  """
  @spec start_link(init_arg()) :: GenServer.on_start()
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg)
  end

  @doc """
  Spawns new `Membrane.ICE.TurnCleaner` under supervisor `supervisor`.
  """
  @spec start_under(Supervisor.supervisor(), init_arg()) :: DynamicSupervisor.on_start_child()
  def start_under(supervisor, init_arg) do
    DynamicSupervisor.start_child(
      supervisor,
      {__MODULE__, init_arg}
    )
  end

  @impl true
  def init(pid: pid, turn: turn) do
    pid_monitor = Process.monitor(pid)
    state = %{pid_monitor: pid_monitor, pid: pid, turn: turn}
    {:ok, state}
  end

  @impl true
  def handle_info(
        {:DOWN, pid_monitor, :process, pid, _reason},
        %{pid_monitor: pid_monitor, pid: pid, turn: turn} = state
      ) do
    Membrane.ICE.Utils.stop_integrated_turn(turn)
    {:stop, :normal, state}
  end
end
