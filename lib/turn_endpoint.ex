defmodule Membrane.ICE.Endpoint do
  @moduledoc """
  Filter used for establishing ICE connection, sending and receiving messages.

  ### Architecture and pad semantic
  Both input and output pads are dynamic ones.
  One instance of ICE Endpoint is responsible for handling only one ICE stream with only one component.

  ### Linking using output pad
  To receive messages after establishing ICE connection you have to link ICE Endpoint to your element
  via `Pad.ref(:output, 1)`. `1` is an id of component from which your element will receive messages - because
  there will be always at most one component, id of it will be equal `1`.

  **Important**: you can link to ICE Endpoint using its output pad in any moment you want but if you don't
  want to miss any messages do it before playing your pipeline.

  **Important**: you can't link multiple elements using the same `component_id`. Messages from
  one component can be conveyed only to one element.

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

  - `{:integrated_turn_servers, integrated_turn_servers}`

  - `{:handshake_init_data, component_id, handshake_init_data}`

  - `{:connection_ready, stream_id, component_id}`

  - `{:component_state_failed, @stream_id, @component_id}`

  ### Sending and receiving messages
  To send or receive messages just link to ICE Endpoint using relevant pads.
  As soon as connection is established your element will receive demands and incoming messages.
  """
  use Membrane.Filter

  alias Membrane.ICE.{Utils, Handshake}
  alias Membrane.Funnel
  alias __MODULE__.Allocation

  require Membrane.Logger

  @component_id 1
  @stream_id 1
  @fake_candidate_port 41847

  @typedoc """
  Options defining the behavior of ICE.Endpoint in relation to integrated TURN servers.
  - `:ip` - IP, where integrated TURN server will open its sockets
  - `:mock_ip` - IP, that will be part of the allocation address contained in Allocation Succes
  message. Because of the fact, that in integrated TURNS no data is relayed via allocation address,
  there is no need to open socket there. There are some cases, where it is necessary, to tell
  the browser, that we have opened allocation on different IP, that we have TURN listening on,
  eg. we are using Docker container
  - `:ports_range` range, where integrated TURN server will try to open ports
  """
  @type integrated_turn_options_t() :: [
          ip: :inet.ip4_address() | nil,
          mock_ip: :inet.ip4_address() | nil,
          ports_range: {:inet.port_number(), :inet.port_number()} | nil
        ]

  def_options handshake_module: [
                spec: module(),
                default: Handshake.Default,
                description: "Module implementing Handshake behaviour"
              ],
              handshake_opts: [
                spec: keyword(),
                default: [],
                description:
                  "Options for handshake module. They will be passed to init function of hsk_module"
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
    caps: :any,
    mode: :push

  defmodule Allocation do
    @enforce_keys [:pid]

    # field `:in_nominated_pair` says, whenether or not, specific allocation
    # is a browser ICE candidate, that belongs to nominated ICE candidates pair
    defstruct @enforce_keys ++
                [
                  magic: nil,
                  in_nominated_pair: false,
                  passed_check_from_browser: false,
                  passed_check_from_sfu: false
                ]
  end

  @impl true
  def handle_init(options) do
    %__MODULE__{
      integrated_turn_options: integrated_turn_options,
      handshake_module: hsk_module,
      handshake_opts: hsk_opts
    } = options

    integrated_turn_servers = start_integrated_turn_servers(integrated_turn_options, self())

    {{:ok, notify: {:integrated_turn_servers, integrated_turn_servers}},
     %{
       integrated_turn_servers: Map.new(integrated_turn_servers, &{&1.pid, &1}),
       turn_allocs: %{},
       fake_candidate_ip: integrated_turn_options[:mock_ip] || integrated_turn_options[:ip],
       selected_alloc: nil,
       hsk_module: hsk_module,
       hsk_opts: hsk_opts,
       component_connected?: false,
       cached_hsk_packets: nil,
       component_ready?: false,
       handshake_finished?: false
     }}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    {hsk_init_data, actions, state} = add_stream(ctx, state)
    ice_ufrag = Utils.generate_ice_ufrag()
    ice_pwd = Utils.generate_ice_pwd()

    state = Map.put(state, :local_ice_pwd, ice_pwd)

    actions =
      actions ++
        [
          notify: {:handshake_init_data, @component_id, hsk_init_data},
          notify: {:local_credentials, "#{ice_ufrag} #{ice_pwd}"}
        ]

    {{:ok, actions}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, @component_id), ctx, state) do
    actions = maybe_send_demands_actions(ctx, state)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, @component_id) = pad, _ctx, state) do
    if state.handshake_finished? do
      {_hsk_state, _hsk_status, hsk_data} = state.handshake
      event = %Handshake.Event{handshake_data: hsk_data}
      {{:ok, event: {pad, event}}, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_process(
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
  def handle_process(
        Pad.ref(:input, @component_id),
        %Membrane.Buffer{},
        _ctx,
        state
      ) do
    {{:ok, notify: {:could_not_send_payload, :no_selected_ice_candidates_pair}}, state}
  end

  @impl true
  def handle_event(Pad.ref(:input, @component_id) = pad, %Funnel.NewInputEvent{}, _ctx, state) do
    if state.handshake_finished? do
      {_hsk_state, _hsk_status, hsk_data} = state.handshake
      event = {pad, %Handshake.Event{handshake_data: hsk_data}}
      {{:ok, event: event}, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_event(_pad, _event, _ctx, state), do: {:ok, state}

  @impl true
  def handle_caps(_pad, _caps, _ctx, state), do: {:ok, state}

  @impl true
  def handle_other(:gather_candidates, _ctx, state) do
    msg = {
      :new_candidate_full,
      Utils.generate_fake_ice_candidate({state.fake_candidate_ip, @fake_candidate_port})
    }

    {{:ok, notify: msg}, state}
  end

  @impl true
  def handle_other({:set_remote_credentials, credentials}, _ctx, state) do
    [_ice_ufrag, ice_pwd] = String.split(credentials)
    state = Map.put(state, :remote_ice_pwd, ice_pwd)
    {:ok, state}
  end

  @impl true
  def handle_other(:restart_stream, _ctx, state) do
    ice_ufrag = Utils.generate_ice_ufrag()
    ice_pwd = Utils.generate_ice_pwd()

    state = Map.put(state, :local_ice_pwd, ice_pwd)
    credentials = "#{ice_ufrag} #{ice_pwd}"
    {{:ok, notify: {:local_credentials, credentials}}, state}
  end

  @impl true
  def handle_other(:peer_candidate_gathering_done, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_other({:hsk_finished, @component_id, hsk_data}, ctx, state) do
    {state, actions} = handle_handshake_finished(hsk_data, ctx, state)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:alloc_created, alloc_pid}, _ctx, state) do
    state = put_in(state, [:turn_allocs, alloc_pid], %Allocation{pid: alloc_pid})
    {:ok, state}
  end

  @impl true
  def handle_other({:alloc_deleted, alloc_pid}, _ctx, state) do
    {_alloc, state} = pop_in(state, [:turn_allocs, alloc_pid])
    {:ok, state}
  end

  @impl true
  def handle_other(
        {:connectivity_check, attrs, alloc_pid},
        ctx,
        state
      ) do
    {state, actions} = do_handle_connectivity_check(Map.new(attrs), alloc_pid, ctx, state)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other(:maybe_send_binding_indication, _ctx, state) do
    with %{selected_alloc: alloc_pid} when is_pid(alloc_pid) <- state,
         %{^alloc_pid => %{magic: magic}} when magic != nil <- state.turn_allocs do
      tr_id = Utils.generate_transaction_id()
      Utils.send_binding_indication(alloc_pid, state.remote_ice_pwd, magic, tr_id)
    end

    Process.send_after(self(), :maybe_send_binding_indication, 1000)
    {:ok, state}
  end

  @impl true
  def handle_other({:ice_payload, payload}, ctx, state) do
    {hsk_state, _hsk_status, _hsk_data} = state.handshake

    if state.hsk_module.is_hsk_packet(payload, hsk_state) do
      state.hsk_module.process(payload, hsk_state)
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
  def handle_other(msg, _ctx, state), do: {{:ok, notify: msg}, state}

  @impl true
  def handle_shutdown(_reason, state) do
    Enum.each(
      state.integrated_turn_servers,
      fn {_pid, turn} -> Utils.stop_integrated_turn(turn) end
    )

    :ok
  end

  defp handle_handshake_finished(hsk_data, ctx, state) do
    pad = Pad.ref(:output, @component_id)
    state = %{state | handshake_finished?: true}

    actions =
      maybe_send_demands_actions(ctx, state) ++
        if Map.has_key?(ctx.pads, pad),
          do: [event: {pad, %Handshake.Event{handshake_data: hsk_data}}],
          else: []

    {state, actions}
  end

  defp start_integrated_turn_servers(options, connector)
       when is_list(options) and is_pid(connector) do
    Map.new(options)
    |> start_integrated_turn_servers(connector)
  end

  defp start_integrated_turn_servers(options, connector)
       when is_pid(connector) do
    ip = options[:ip] || {0, 0, 0, 0}
    mock_ip = options[:mock_ip] || ip
    {min_port, max_port} = options[:ports_range] || {50_000, 59_999}
    medium = trunc((min_port + max_port) / 2)

    client_port_range = {min_port, medium}

    alloc_port_range =
      if medium == max_port,
        do: {medium, max_port},
        else: {medium + 1, max_port}

    [:udp, :tcp]
    |> Enum.map(fn transport ->
      secret = Utils.generate_secret()

      {:ok, port, pid} =
        Utils.start_integrated_turn(
          secret,
          client_port_range: client_port_range,
          alloc_port_range: alloc_port_range,
          ip: ip,
          mock_ip: mock_ip,
          transport: transport,
          parent: connector,
          fake_candidate_addr: {mock_ip, @fake_candidate_port},
          elixir_ice_impl: true
        )

      %{
        relay_type: transport,
        secret: secret,
        server_addr: ip,
        mocked_server_addr: mock_ip,
        server_port: port,
        pid: pid
      }
    end)
  end

  defp start_integrated_turn_servers(_options, _connector), do: []

  defp do_handle_connectivity_check(%{class: :request} = attrs, alloc_pid, ctx, state) do
    alloc = state.turn_allocs[alloc_pid]

    Utils.send_binding_success(
      alloc_pid,
      state.local_ice_pwd,
      attrs.magic,
      attrs.trid,
      attrs.username
    )

    alloc = %Allocation{alloc | passed_check_from_browser: true, magic: attrs.magic}

    if not alloc.passed_check_from_sfu do
      trid = Utils.generate_transaction_id()
      new_username = String.split(attrs.username, ":") |> Enum.reverse() |> Enum.join(":")

      Utils.send_binding_request(
        alloc_pid,
        state.remote_ice_pwd,
        attrs.magic,
        trid,
        new_username,
        attrs.priority
      )
    end

    alloc =
      if attrs.use_candidate,
        do: %Allocation{alloc | in_nominated_pair: true},
        else: alloc

    state = put_in(state, [:turn_allocs, alloc_pid], alloc)
    maybe_select_allocation(alloc, ctx, state)
  end

  defp do_handle_connectivity_check(%{class: :response}, alloc_pid, ctx, state) do
    alloc = state.turn_allocs[alloc_pid]
    alloc = %Allocation{alloc | passed_check_from_sfu: true}
    maybe_select_allocation(alloc, ctx, state)
  end

  defp do_handle_connectivity_check(%{class: :error}, _, _, state) do
    {state, []}
  end

  defp maybe_select_allocation(
         %Allocation{
           passed_check_from_browser: true,
           passed_check_from_sfu: true,
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

  defp maybe_select_allocation(_alloc, _ctx, state) do
    {state, []}
  end

  defp select_alloc(alloc_pid, ctx, state) do
    state = Map.put(state, :selected_alloc, alloc_pid)
    Membrane.Logger.debug("Component #{@component_id} READY")

    {hsk_state, hsk_status, _hsk_data} = state.handshake
    state = %{state | component_connected?: true}

    {state, actions} =
      if hsk_status == :finished do
        {state, [notify: {:connection_ready, @stream_id, @component_id}]}
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

        handle_connection_ready(
          state.hsk_module.connection_ready(hsk_state),
          state
        )

        {%{state | cached_hsk_packets: nil}, []}
      end

    {state, demand_actions} = handle_component_state_ready(ctx, state)
    actions = demand_actions ++ actions
    {state, actions}
  end

  defp handle_connection_ready(:ok, _state), do: :ok

  defp handle_connection_ready({:ok, packets}, state) do
    Utils.send_ice_payload(state.selected_alloc, packets)
    :ok
  end

  defp add_stream(ctx, state) do
    %{
      hsk_module: hsk_module,
      hsk_opts: hsk_opts
    } = state

    hsk_init_result = hsk_module.init(1, self(), hsk_opts)

    {hsk_init_data, handshake} =
      case hsk_init_result do
        {:ok, init_data, hsk_state} ->
          {init_data, {hsk_state, :in_progress, nil}}

        {:finished, init_data} ->
          {init_data, {nil, :finished, nil}}
      end

    {state, actions} =
      hsk_init_result
      |> case do
        {:ok, _init_data, _state} ->
          {state, []}

        {:finished, _init_data} ->
          handle_handshake_finished(nil, ctx, state)
      end

    state = Map.put(state, :handshake, handshake)
    {hsk_init_data, actions, state}
  end

  defp handle_process_result(:ok, _ctx, state) do
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
    {hsk_state, _hsk_status, _hsk_data} = state.handshake
    state = Map.put(state, :handshake, {hsk_state, :finished, hsk_data})

    {state, actions} = handle_handshake_finished(hsk_data, ctx, state)

    actions =
      actions ++
        if state.component_connected?,
          do: [notify: {:connection_ready, @stream_id, @component_id}],
          else: []

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
         state.handshake_finished? do
      {_hsk_state, _hsk_status, hsk_data} = state.handshake

      [
        demand: pad,
        event: {pad, %Handshake.Event{handshake_data: hsk_data}}
      ]
    else
      []
    end
  end
end
