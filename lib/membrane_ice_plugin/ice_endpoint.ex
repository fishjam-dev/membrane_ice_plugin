defmodule Membrane.ICE.Endpoint do
  @moduledoc """
  Endpoint used for establishing ICE connection, sending and receiving messages.

  ### Architecture and pad semantic
  Both input and output pads are dynamic ones.
  One instance of ICE Endpoint is responsible for handling only one ICE stream with only one component.

  ### Linking using output pad
  To receive messages after establishing ICE connection you have to link ICE Endpoint to your element
  via `Pad.ref(:output, 1)`. `1` is an id of component from which your element will receive messages - because
  there will be always at most one component, id of it will be equal `1`.

  **Important**: you can link to ICE Endpoint using its output pad in any moment you want but if you don't
  want to miss any messages do it before playing your pipeline.

  ### Linking using input pad
  To send messages after establishing ICE connection you have to link to ICE Endpoint via
  `Pad.ref(:input, 1)`. `1` is an id of component which will be used to send
  messages via net. To send data from multiple elements via the same component you have to
  use [membrane_funnel_plugin](https://github.com/membraneframework/membrane_funnel_plugin).

  ### Messages API
  You can send following messages to ICE Endpoint:

  - `:gather_candidates`

  - `{:set_remote_credentials, credentials}` - credentials are string in form of "ufrag passwd"

  - `:peer_candidate_gathering_done`

  ### Notifications API
  - `{:new_candidate_full, candidate}`
    Triggered by: `:gather_candidates`

  - `{:udp_integrated_turn, udp_integrated_turn}`

  - `{:handshake_init_data, component_id, handshake_init_data}`

  - `{:connection_ready, stream_id, component_id}`

  - `{:component_state_failed, stream_id, component_id}`

  ### Sending and receiving messages
  To send or receive messages just link to ICE Endpoint using relevant pads.
  As soon as connection is established your element will receive demands and incoming messages.

  ### Estabilishing a connection

  #### Gathering ICE candidates
  Data about integrated TURN servers set up by `Membrane.ICE.Endpoint`, passed to the parent via notification, should be
  forwarded to the second peer, that will try to establish ICE connection with `Membrane.ICE.Endpoint`. The second peer
  should have at least one allocation, in any of running integrated TURN servers (Firefox or Chrome will probably
  have one allocation per TURN Server)

  #### Performing ICE connectivity checks, selecting candidates pair
  All ICE candidates from the second peer, that are not relay candidates corresponded to allocations on integrated TURN
  servers, will be ignored. Every ICE connectivity check sent via integrated TURN server is captured, parsed, and
  forwarded to ICE Endpoint in message `{:connectivity_check, attributes, allocation_pid}`. ICE Endpoint sends to
  messages in form of `{:send_connectivity_check, attributes}` on `allocation_pid`, to send his connectivity checks
  to the second peer. Role of ICE Endpoint can be ice-controlled, but cannot be ice-controlling. It is suggested, to use
  `ice-lite` option in SDP message, but it is not necessary. ICE Endpoint supports both, aggressive and normal nomination.
  After starting ICE or after every ICE restart, ICE Endpoint will pass all traffic and connectivity checks via
  allocation, which corresponds to the last selected ICE candidates pair.
  """

  use Membrane.Endpoint

  require Membrane.Logger

  alias Membrane.ICE.{Utils, CandidatePortAssigner}
  alias Membrane.Funnel
  alias Membrane.RemoteStream
  alias Membrane.SRTP
  alias __MODULE__.Allocation

  @component_id 1
  @stream_id 1
  @time_between_keepalives 1_000_000_000
  @ice_restart_timeout 5_000

  @typedoc """
  Options defining the behavior of ICE.Endpoint in relation to integrated TURN servers.
  - `:ip` - IP, where integrated TURN server will open its sockets
  - `:mock_ip` - IP, that will be part of the allocation address contained in Allocation Succes
  message. Because of the fact, that in integrated TURNS no data is relayed via allocation address,
  there is no need to open socket there. There are some cases, where it is necessary, to tell
  the browser, that we have opened allocation on different IP, that we have TURN listening on,
  eg. we are using Docker container
  - `:ports_range` - range, where integrated TURN server will try to open ports
  - `:cert_file` - path to file with certificate and private key, used for estabilishing TLS connection
  for TURN using TLS over TCP
  """
  @type integrated_turn_options_t() :: [
          ip: :inet.ip4_address() | nil,
          mock_ip: :inet.ip4_address() | nil,
          ports_range: {:inet.port_number(), :inet.port_number()} | nil,
          cert_file: binary() | nil
        ]

  def_options dtls?: [
                spec: boolean(),
                default: true,
                description: "`true`, if using DTLS Handshake, `false` otherwise"
              ],
              ice_lite?: [
                spec: boolean(),
                default: true,
                description:
                  "`true`, when ice-lite option was send in SDP message, `false` otherwise"
              ],
              handshake_opts: [
                spec: keyword(),
                default: [],
                description:
                  "Options for `ExDTLS` module. They will be passed to `ExDTLS.start_link/1`"
              ],
              integrated_turn_options: [
                spec: [integrated_turn_options_t()],
                description: "Integrated TURN Options"
              ]

  def_input_pad :input,
    availability: :on_request,
    caps: :any,
    mode: :pull,
    demand_unit: :buffers

  def_output_pad :output,
    availability: :on_request,
    caps: {RemoteStream, content_format: nil, type: :packetized},
    mode: :push

  defmodule Allocation do
    @enforce_keys [:pid]

    # field `:in_nominated_pair` says, whenether or not, specific allocation
    # is a browser ICE candidate, that belongs to nominated ICE candidates pair
    defstruct @enforce_keys ++
                [
                  magic: nil,
                  in_nominated_pair: false,
                  passed_check_from_browser: false
                ]
  end

  @impl true
  def handle_init(options) do
    %__MODULE__{
      integrated_turn_options: integrated_turn_options,
      dtls?: dtls?,
      handshake_opts: hsk_opts
    } = options

    state = %{
      id: to_string(Enum.map(1..10, fn _i -> Enum.random(?a..?z) end)),
      turn_allocs: %{},
      integrated_turn_options: integrated_turn_options,
      fake_candidate_ip: integrated_turn_options[:mock_ip] || integrated_turn_options[:ip],
      selected_alloc: nil,
      dtls?: dtls?,
      hsk_opts: hsk_opts,
      component_connected?: false,
      cached_hsk_packets: nil,
      component_ready?: false,
      pending_connection_ready?: false,
      connection_status_sent?: false,
      sdp_offer_arrived?: false,
      ice_restart_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, %{dtls?: true} = state) do
    case CandidatePortAssigner.assign_candidate_port() do
      {:ok, candidate_port} ->
        {:ok, dtls} = ExDTLS.start_link(state.hsk_opts)
        {:ok, fingerprint} = ExDTLS.get_cert_fingerprint(dtls)
        hsk_state = %{:dtls => dtls, :client_mode => state.hsk_opts[:client_mode]}
        ice_ufrag = Utils.generate_ice_ufrag()
        ice_pwd = Utils.generate_ice_pwd()

        [udp_integrated_turn] =
          Utils.start_integrated_turn_servers([:udp], state.integrated_turn_options,
            parent: self()
          )

        state =
          Map.merge(state, %{
            candidate_port: candidate_port,
            udp_integrated_turn: udp_integrated_turn,
            local_ice_pwd: ice_pwd,
            handshake: %{state: hsk_state, status: :in_progress, keying_material_event: nil}
          })
          |> start_ice_restart_timer()

        actions = [
          caps: {Pad.ref(:output, @component_id), %RemoteStream{type: :packetized}},
          start_timer: {:keepalive_timer, @time_between_keepalives},
          notify: {:udp_integrated_turn, udp_integrated_turn},
          notify: {:handshake_init_data, @component_id, fingerprint},
          notify: {:local_credentials, "#{ice_ufrag} #{ice_pwd}"}
        ]

        {{:ok, actions}, state}

      {:error, :no_free_candidate_port} = err ->
        {err, state}
    end
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    case CandidatePortAssigner.assign_candidate_port() do
      {:ok, candidate_port} ->
        ice_ufrag = Utils.generate_ice_ufrag()
        ice_pwd = Utils.generate_ice_pwd()

        [udp_integrated_turn] =
          Utils.start_integrated_turn_servers([:udp], state.integrated_turn_options,
            parent: self()
          )

        state =
          Map.merge(state, %{
            candidate_port: candidate_port,
            udp_integrated_turn: udp_integrated_turn,
            local_ice_pwd: ice_pwd
          })

        actions = [
          notify: {:udp_integrated_turn, udp_integrated_turn},
          notify: {:handshake_init_data, @component_id, nil},
          notify: {:local_credentials, "#{ice_ufrag} #{ice_pwd}"}
        ]

        {{:ok, actions}, state}

      {:error, :no_free_candidate_port} = err ->
        {err, state}
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, @component_id), ctx, state) do
    actions = maybe_send_demands_actions(ctx, state)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:output, @component_id) = pad,
        ctx,
        %{dtls?: true, handshake: %{status: :finished}} = state
      ) do
    actions = maybe_send_caps(ctx) ++ [event: {pad, state.handshake.keying_material_event}]
    {{:ok, actions}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, @component_id), ctx, state) do
    {{:ok, maybe_send_caps(ctx)}, state}
  end

  @impl true
  def handle_write(
        Pad.ref(:input, @component_id) = pad,
        %Membrane.Buffer{payload: payload},
        _ctx,
        %{selected_alloc: alloc} = state
      )
      when is_pid(alloc) do
    Utils.send_ice_payload(alloc, payload)
    {{:ok, demand: pad}, state}
  end

  @impl true
  def handle_event(
        Pad.ref(:input, @component_id) = pad,
        %Funnel.NewInputEvent{},
        _ctx,
        %{dtls?: true, handshake: %{status: :finished}} = state
      ) do
    {{:ok, event: {pad, state.handshake.keying_material_event}}, state}
  end

  @impl true
  def handle_event(_pad, _event, _ctx, state), do: {:ok, state}

  @impl true
  def handle_tick(:keepalive_timer, _ctx, state) do
    with %{selected_alloc: alloc_pid} when is_pid(alloc_pid) <- state,
         %{^alloc_pid => %{magic: magic}} when magic != nil <- state.turn_allocs do
      tr_id = Utils.generate_transaction_id()
      Utils.send_binding_indication(alloc_pid, state.remote_ice_pwd, magic, tr_id)

      Membrane.Logger.debug(
        "Sending Binding Indication with params: #{inspect(magic: magic, transaction_id: tr_id)}"
      )
    end

    {:ok, state}
  end

  @impl true
  def handle_other(:gather_candidates, _ctx, state) do
    msg = {
      :new_candidate_full,
      Utils.generate_fake_ice_candidate({state.fake_candidate_ip, state.candidate_port})
    }

    {{:ok, notify: msg}, state}
  end

  @impl true
  def handle_other({:set_remote_credentials, credentials}, _ctx, state)
      when state.pending_connection_ready? do
    [_ice_ufrag, ice_pwd] = String.split(credentials)

    state =
      Map.merge(state, %{
        remote_ice_pwd: ice_pwd,
        sdp_offer_arrived?: true,
        connection_status_sent?: true,
        pending_connection_ready?: false
      })
      |> stop_ice_restart_timer()

    actions = [notify: {:connection_ready, @stream_id, @component_id}]
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:set_remote_credentials, credentials}, _ctx, state) do
    [_ice_ufrag, ice_pwd] = String.split(credentials)

    state =
      Map.merge(state, %{
        remote_ice_pwd: ice_pwd,
        sdp_offer_arrived?: true
      })

    {:ok, state}
  end

  @impl true
  def handle_other(:restart_stream, _ctx, state) do
    ice_ufrag = Utils.generate_ice_ufrag()
    ice_pwd = Utils.generate_ice_pwd()

    state =
      Map.merge(state, %{
        local_ice_pwd: ice_pwd,
        connection_status_sent?: false,
        sdp_offer_arrived?: false
      })
      |> start_ice_restart_timer()

    credentials = "#{ice_ufrag} #{ice_pwd}"
    {{:ok, notify: {:local_credentials, credentials}}, state}
  end

  @impl true
  def handle_other(:peer_candidate_gathering_done, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_other({:alloc_deleted, alloc_pid}, _ctx, state) do
    Membrane.Logger.debug("Deleting allocation with pid #{inspect(alloc_pid)}")
    {_alloc, state} = pop_in(state, [:turn_allocs, alloc_pid])
    {:ok, state}
  end

  @impl true
  def handle_other(
        {:connectivity_check, attrs, alloc_pid},
        ctx,
        state
      ) do
    state =
      if Map.has_key?(state.turn_allocs, alloc_pid) do
        state
      else
        Membrane.Logger.debug(
          "First connectivity check arrived from allocation with pid #{inspect(alloc_pid)}"
        )

        put_in(state, [:turn_allocs, alloc_pid], %Allocation{pid: alloc_pid})
      end

    {state, actions} = do_handle_connectivity_check(Map.new(attrs), alloc_pid, ctx, state)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:ice_payload, payload}, ctx, state) do
    if state.dtls? and Utils.is_dtls_hsk_packet(payload) do
      ExDTLS.process(state.handshake.state.dtls, payload)
      |> handle_process_result(ctx, state)
    else
      out_pad = Pad.ref(:output, @component_id)

      actions =
        cond do
          not Map.has_key?(ctx.pads, out_pad) ->
            Membrane.Logger.warn(
              "No links for component: #{@component_id}. Ignoring incoming message."
            )

            []

          ctx.playback_state != :playing ->
            Membrane.Logger.debug(
              "Received message in playback state: #{ctx.playback_state}. Ignoring."
            )

            []

          true ->
            [buffer: {out_pad, %Membrane.Buffer{payload: payload}}]
        end

      {{:ok, actions}, state}
    end
  end

  @impl true
  def handle_other(:ice_restart_timeout, _ctx, state) do
    Membrane.Logger.debug("ICE restart failed due to timeout")

    state = %{state | connection_status_sent?: true, pending_connection_ready?: false}
    actions = [notify: {:connection_failed, @stream_id, @component_id}]
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other(msg, _ctx, state), do: {{:ok, notify: msg}, state}

  @impl true
  def handle_shutdown(_reason, state) do
    with %{udp_integrated_turn: turn} <- state do
      Utils.stop_integrated_turn(turn)
    end

    :ok
  end

  defp do_handle_connectivity_check(%{class: :request} = attrs, alloc_pid, ctx, state) do
    log_debug_connectivity_check(attrs)

    alloc = state.turn_allocs[alloc_pid]

    Utils.send_binding_success(
      alloc_pid,
      state.local_ice_pwd,
      attrs.magic,
      attrs.trid,
      attrs.username
    )

    [magic: attrs.magic, transaction_id: attrs.trid, username: attrs.username]
    |> then(&"Sending Binding Success with params: #{inspect(&1)}")
    |> Membrane.Logger.debug()

    alloc = %Allocation{alloc | passed_check_from_browser: true, magic: attrs.magic}

    alloc =
      if attrs.use_candidate,
        do: %Allocation{alloc | in_nominated_pair: true},
        else: alloc

    state = put_in(state, [:turn_allocs, alloc_pid], alloc)
    maybe_select_alloc(alloc, ctx, state)
  end

  defp do_handle_connectivity_check(attrs, _alloc_pid, _ctx, state) do
    log_debug_connectivity_check(attrs)
    {state, []}
  end

  defp log_debug_connectivity_check(attrs) do
    request_type =
      case attrs.class do
        :response -> "Success"
        :request -> "Request"
        :error -> "Error"
      end

    Map.delete(attrs, :class)
    |> Map.to_list()
    |> then(&"Received Binding #{request_type} with params: #{inspect(&1)}")
    |> Membrane.Logger.debug()
  end

  defp maybe_select_alloc(
         %Allocation{
           passed_check_from_browser: true,
           in_nominated_pair: true
         } = alloc,
         ctx,
         state
       ) do
    if state.selected_alloc != alloc.pid do
      select_alloc(alloc.pid, ctx, state)
    else
      {state, []}
    end
  end

  defp maybe_select_alloc(_alloc, _ctx, state) do
    {state, []}
  end

  defp select_alloc(alloc_pid, ctx, state) do
    state = Map.put(state, :selected_alloc, alloc_pid)
    Membrane.Logger.debug("Component #{@component_id} READY")

    state = %{state | component_connected?: true}

    {state, actions} =
      if state.dtls? == false or state.handshake.status == :finished do
        maybe_send_connection_ready(state)
      else
        Membrane.Logger.debug("Checking for cached handshake packets")

        if state.cached_hsk_packets == nil do
          Membrane.Logger.debug("Nothing to be sent for component: #{@component_id}")
        else
          Membrane.Logger.debug(
            "Sending cached handshake packets for component: #{@component_id}"
          )

          Utils.send_ice_payload(state.selected_alloc, state.cached_hsk_packets)
        end

        with %{dtls?: true} <- state, %{dtls: dtls, client_mode: true} <- state.handshake.state do
          {:ok, packets} = ExDTLS.do_handshake(dtls)
          Utils.send_ice_payload(state.selected_alloc, packets)
        else
          _state -> :ok
        end

        {state, actions} =
          if state.handshake.status == :finished do
            maybe_send_connection_ready(state)
          else
            {state, []}
          end

        {%{state | cached_hsk_packets: nil}, actions}
      end

    {state, demand_actions} = handle_component_state_ready(ctx, state)
    actions = demand_actions ++ actions
    {state, actions}
  end

  defp handle_process_result(:handshake_want_read, _ctx, state) do
    {:ok, state}
  end

  defp handle_process_result({:ok, _packets}, _ctx, state) do
    Membrane.Logger.warn("Got regular handshake packet. Ignoring for now.")
    {:ok, state}
  end

  defp handle_process_result({:handshake_packets, packets}, _ctx, state) do
    if state.component_connected? do
      Utils.send_ice_payload(state.selected_alloc, packets)
      {:ok, state}
    else
      # if connection is not ready yet cache data
      # TODO maybe try to send?
      state = %{state | cached_hsk_packets: packets}
      {:ok, state}
    end
  end

  defp handle_process_result({:handshake_finished, hsk_data}, ctx, state),
    do: handle_end_of_hsk(hsk_data, ctx, state)

  defp handle_process_result({:handshake_finished, hsk_data, packets}, ctx, state) do
    Utils.send_ice_payload(state.selected_alloc, packets)
    handle_end_of_hsk(hsk_data, ctx, state)
  end

  defp handle_process_result({:connection_closed, reason}, _ctx, state) do
    Membrane.Logger.debug("Connection closed, reason: #{inspect(reason)}. Ignoring for now.")
    {:ok, state}
  end

  defp handle_end_of_hsk(hsk_data, ctx, state) do
    hsk_state = state.handshake.state
    event = to_srtp_keying_material_event(hsk_data)

    state =
      Map.put(state, :handshake, %{
        state: hsk_state,
        status: :finished,
        keying_material_event: event
      })

    {state, connection_ready_actions} = maybe_send_connection_ready(state)

    actions =
      connection_ready_actions ++
        maybe_send_demands_actions(ctx, state) ++
        maybe_send_keying_material_to_output(ctx, state)

    {{:ok, actions}, state}
  end

  defp handle_component_state_ready(ctx, state) do
    state = %{state | component_ready?: true}
    actions = maybe_send_demands_actions(ctx, state)
    {state, actions}
  end

  defp maybe_send_demands_actions(ctx, state) do
    pad = Pad.ref(:input, @component_id)
    # if something is linked, component is ready and handshake is done then send demands
    if Map.has_key?(ctx.pads, pad) and state.component_ready? and
         state.handshake.status == :finished do
      event = if state.dtls?, do: [event: {pad, state.handshake.keying_material_event}], else: []
      event ++ [demand: pad]
    else
      []
    end
  end

  defp maybe_send_keying_material_to_output(ctx, state) do
    pad = Pad.ref(:output, @component_id)

    if Map.has_key?(ctx.pads, pad),
      do: [event: {pad, state.handshake.keying_material_event}],
      else: []
  end

  defp maybe_send_caps(ctx) do
    pad = Pad.ref(:output, @component_id)

    if ctx.playback_state == :playing do
      [caps: {pad, %RemoteStream{}}]
    else
      []
    end
  end

  defp start_ice_restart_timer(state) do
    timer_ref = Process.send_after(self(), :ice_restart_timeout, @ice_restart_timeout)
    %{state | ice_restart_timer: timer_ref}
  end

  defp stop_ice_restart_timer(%{ice_restart_timer: timer_ref} = state)
       when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    state
  end

  defp stop_ice_restart_timer(state), do: state

  defp maybe_send_connection_ready(
         %{connection_status_sent?: false, sdp_offer_arrived?: true} = state
       ) do
    state =
      %{state | connection_status_sent?: true}
      |> stop_ice_restart_timer()

    actions = [notify: {:connection_ready, @stream_id, @component_id}]

    {state, actions}
  end

  defp maybe_send_connection_ready(
         %{connection_status_sent?: false, sdp_offer_arrived?: false} = state
       ),
       do: {%{state | pending_connection_ready?: true}, []}

  defp maybe_send_connection_ready(state), do: {state, []}

  defp to_srtp_keying_material_event(handshake_data) do
    {local_keying_material, remote_keying_material, protection_profile} = handshake_data

    %SRTP.KeyingMaterialEvent{
      local_keying_material: local_keying_material,
      remote_keying_material: remote_keying_material,
      protection_profile: protection_profile
    }
  end
end
