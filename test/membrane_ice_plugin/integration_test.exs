defmodule Membrane.ICE.IntegrationTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.ICE.Utils
  alias Membrane.Testing

  @magic 225_597_803
  @remote_ice_ufrag "zmg3"
  @remote_ice_pwd "rEhkHyaAOPuZlqjBQrCQuL"
  @priority 2_015_363_327
  @component_id 1
  @stream_id 1

  test "Membrane.ICE.Endpoint connectivity checks and sends proper notifications" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: Membrane.ICE.Support.TestPipeline,
        custom_args: [
          dtls?: false,
          integrated_turn_options: [
            ip: {127, 0, 0, 1}
          ]
        ]
      )

    assert_pipeline_notified(pipeline, :ice, {:udp_integrated_turn, _turn})

    Testing.Pipeline.message_child(pipeline, :ice, :gather_candidates)

    assert_pipeline_notified(
      pipeline,
      :ice,
      {:handshake_init_data, @component_id, _hsk_init_data}
    )

    assert_pipeline_notified(pipeline, :ice, {:local_credentials, credentials})
    assert_pipeline_notified(pipeline, :ice, {:new_candidate_full, candidate})
    assert is_binary(candidate)

    [local_ice_ufrag, _local_ice_pwd] = String.split(credentials)

    msg = {:set_remote_credentials, "#{@remote_ice_ufrag} #{@remote_ice_pwd}"}
    Testing.Pipeline.message_child(pipeline, :ice, msg)
    Testing.Pipeline.message_child(pipeline, :ice, :sdp_offer_arrived)

    trid = Utils.generate_transaction_id()
    username = "#{@remote_ice_ufrag}:#{local_ice_ufrag}"

    binding_request = [
      class: :request,
      magic: @magic,
      trid: trid,
      username: username,
      priority: @priority,
      use_candidate: false,
      ice_controlling: true,
      ice_controlled: false
    ]

    msg = {:connectivity_check, binding_request, self()}
    Testing.Pipeline.message_child(pipeline, :ice, msg)

    assert_receive(
      {:send_connectivity_check, stun_msg},
      1000,
      "ICE.Endpoint hasn't responded to Binding Request"
    )

    assert :response == stun_msg[:class]
    assert @magic == stun_msg[:magic]
    assert trid == stun_msg[:trid]
    assert username == stun_msg[:username]

    trid = Utils.generate_transaction_id()
    username = "#{@remote_ice_ufrag}:#{local_ice_ufrag}"

    binding_request = [
      class: :request,
      magic: @magic,
      trid: trid,
      username: username,
      priority: @priority,
      use_candidate: true,
      ice_controlling: true,
      ice_controlled: false
    ]

    msg = {:connectivity_check, binding_request, self()}
    Testing.Pipeline.message_child(pipeline, :ice, msg)

    assert_receive(
      {:send_connectivity_check, stun_msg},
      1000,
      "ICE.Endpoint hasn't responded to Binding Request"
    )

    assert :response == stun_msg[:class]
    assert @magic == stun_msg[:magic]
    assert trid == stun_msg[:trid]
    assert username == stun_msg[:username]

    assert_pipeline_notified(pipeline, :ice, {:connection_ready, @stream_id, @component_id})

    Testing.Pipeline.terminate(pipeline, blocking?: true)
  end
end
