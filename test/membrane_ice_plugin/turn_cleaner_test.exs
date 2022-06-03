defmodule Membrane.ICE.TURNCleanerTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  test "TURNCleaner is created and destroyed properly" do
    turn_cleaner_sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    children = [
      ice_endpoint: %Membrane.ICE.Endpoint{
        dtls?: false,
        integrated_turn_options: [ip: {127, 0, 0, 1}],
        turn_cleaner_sup: turn_cleaner_sup
      }
    ]

    {:ok, pipeline} = Membrane.Testing.Pipeline.start_link(children: children)

    assert_pipeline_playback_changed(pipeline, :prepared, :playing)

    assert %{specs: 1, active: 1, supervisors: 0, workers: 1} ==
             DynamicSupervisor.count_children(turn_cleaner_sup)

    :ok = Membrane.Testing.Pipeline.terminate(pipeline, blocking?: true)

    # give TURN cleaner some time to exit
    Process.sleep(100)

    assert %{specs: 0, active: 0, supervisors: 0, workers: 0} ==
             DynamicSupervisor.count_children(turn_cleaner_sup)
  end
end
