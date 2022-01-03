defmodule Membrane.TURN.Utils do
  @moduledoc false

  @numbers_and_letters Enum.concat([?0..?9, ?a..?z, ?A..?Z])

  @spec generate_credentials(binary(), binary()) :: {binary(), binary()}
  def generate_credentials(name, secret) do
    duration =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> tap(fn unix_timestamp -> unix_timestamp + 24 * 3600 end)

    username = "#{duration}:#{name}"

    password =
      :crypto.mac(:hmac, :sha, secret, username)
      |> Base.encode64()

    {username, password}
  end

  @spec generate_secret() :: binary()
  def generate_secret() do
    symbols = '0123456789abcdef'

    1..20
    |> Enum.map(fn _i -> Enum.random(symbols) end)
    |> to_string()
  end

  @spec start_integrated_turn(binary(), list()) :: {:ok, :inet.port_number(), pid()}
  def start_integrated_turn(secret, opts \\ []),
    do: :turn_starter.start(secret, opts)

  @spec stop_integrated_turn(map()) :: :ok
  def stop_integrated_turn(turn),
    do: :turn_starter.stop(turn.server_addr, turn.server_port, turn.relay_type)

  @spec generate_fake_ice_candidate({:inet.ip4_address(), :inet.port_number()}) :: binary()
  def generate_fake_ice_candidate({ip, port}) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
    |> then(&"a=candidate:1 1 UDP 2015363327 #{&1} #{port} typ host")
  end

  @spec send_binding_success(pid(), binary(), number(), number(), binary()) :: any()
  def send_binding_success(turn_pid, pwd, magic, trid, username) when is_pid(turn_pid) do
    [class: :response, username: username]
    |> send_connectivity_check(turn_pid, pwd, magic, trid)
  end

  @spec send_binding_request(pid(), binary(), number(), number(), binary(), number()) :: any()
  def send_binding_request(turn_pid, pwd, magic, trid, username, priority)
      when is_pid(turn_pid) do
    [
      class: :request,
      username: username,
      priority: priority,
      ice_controlled: true
    ]
    |> send_connectivity_check(turn_pid, pwd, magic, trid)
  end

  @spec send_binding_indication(pid(), binary(), number(), number()) :: any()
  def send_binding_indication(turn_pid, pwd, magic, trid) when is_pid(turn_pid) do
    [class: :indication]
    |> send_connectivity_check(turn_pid, pwd, magic, trid)
  end

  @spec send_error_role_conflict(pid(), binary(), number(), number()) :: any()
  def send_error_role_conflict(turn_pid, pwd, magic, trid) when is_pid(turn_pid) do
    [
      class: :error,
      error_code: 487
    ]
    |> send_connectivity_check(turn_pid, pwd, magic, trid)
  end

  @spec generate_transaction_id() :: number()
  def generate_transaction_id() do
    <<tr_id::12*8>> = :crypto.strong_rand_bytes(12)
    tr_id
  end

  @spec generate_ice_ufrag() :: binary()
  def generate_ice_ufrag(), do: random_readable_binary(4)

  @spec generate_ice_pwd() :: binary()
  def generate_ice_pwd(), do: random_readable_binary(22)

  defp send_connectivity_check(attrs, turn_pid, pwd, magic, trid) do
    attrs =
      [
        ice_pwd: pwd,
        magic: magic,
        trid: trid
      ] ++ attrs

    send(turn_pid, {:connectivity_check, attrs})
  end

  defp random_readable_binary(len),
    do: to_string(for _i <- 1..len, do: Enum.random(@numbers_and_letters))
end
