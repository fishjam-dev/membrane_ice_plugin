defmodule Membrane.ICE.TURNCleaner do
  @moduledoc """
  Integrated TURN cleaner.

  It monitors given process and when it exits, stops Integrated TURN.
  """

  @doc """
  Spawns a new TURN cleaner and links it to calling process.

  `pid` is a pid of a process to monitor and `turn` is an TURN server to terminate when process
  with pid `pid` exits.
  """
  @spec start_link(pid(), map()) :: {:ok, pid}
  def start_link(pid, turn) do
    cleaner_pid =
      Process.spawn(
        fn ->
          monitor_ref = Process.monitor(pid)

          receive do
            {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
              Membrane.ICE.Utils.stop_integrated_turn(turn)
          end
        end,
        [:link]
      )

    {:ok, cleaner_pid}
  end

  @doc """
  Spawns a new TURN cleaner under supervisor `supervisor`.

  `pid` and `turn` have the same meaning as in `start_link/2`.
  """
  @spec start_under(Supervisor.supervisor(), pid(), map()) :: DynamicSupervisor.on_start_child()
  def start_under(supervisor, pid, turn) do
    DynamicSupervisor.start_child(
      supervisor,
      %{id: make_ref(), start: {__MODULE__, :start_link, [pid, turn]}, restart: :transient}
    )
  end
end
