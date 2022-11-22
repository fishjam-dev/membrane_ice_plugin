defmodule Membrane.ICE.TURNCleanerTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec, only: [child: 2]
  import Membrane.Testing.Assertions

  test "TURNCleaner is created and destroyed properly" do
    turn_cleaner_sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    assert %{specs: 0, active: 0, supervisors: 0, workers: 0} ==
             DynamicSupervisor.count_children(turn_cleaner_sup)

    ice_endpoint = %Membrane.ICE.Endpoint{
      dtls?: false,
      integrated_turn_options: [ip: {127, 0, 0, 1}],
      turn_cleaner_sup: turn_cleaner_sup
    }

    children = child(:ice_endpoint, ice_endpoint)

    pipeline = Membrane.Testing.Pipeline.start_link_supervised!(structure: children)

    assert_pipeline_play(pipeline)

    assert %{specs: 1, active: 1, supervisors: 0, workers: 1} =
             count_children_sync(turn_cleaner_sup)

    [{:undefined, turn_cleaner_pid, :worker, _modules}] =
      DynamicSupervisor.which_children(turn_cleaner_sup)

    m_ref = Process.monitor(turn_cleaner_pid)

    :ok = Membrane.Testing.Pipeline.terminate(pipeline, blocking?: true)

    assert_receive {:DOWN, ^m_ref, :process, ^turn_cleaner_pid, :normal}

    assert %{specs: 0, active: 0, supervisors: 0, workers: 0} ==
             DynamicSupervisor.count_children(turn_cleaner_sup)
  end

  defp count_children_sync(sup) do
    my_pid = self()

    pid =
      spawn(fn ->
        send(my_pid, count_children_rec(sup))
      end)

    receive do
      {:ok, value} ->
        value
    after
      1000 ->
        Process.exit(pid, :kill)
        DynamicSupervisor.count_children(sup)
    end
  end

  defp count_children_rec(sup) do
    case DynamicSupervisor.count_children(sup) do
      %{specs: 0, active: 0, supervisors: 0, workers: 0} ->
        Process.sleep(10)
        count_children_rec(sup)

      non_zero_res ->
        {:ok, non_zero_res}
    end
  end
end
