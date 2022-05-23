defmodule Membrane.ICE.Metrics do
  @moduledoc false

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics() do
    [
      Telemetry.Metrics.counter(
        "ice.packets-received",
        event_name: [:ice, :packet_received]
      ),
      Telemetry.Metrics.sum(
        "ice.bytes-received",
        event_name: [:ice, :packet_received],
        measurement: :bytes
      ),
      Telemetry.Metrics.counter(
        "ice.packets-sent",
        event_name: [:ice, :packet_sent]
      ),
      Telemetry.Metrics.sum(
        "ice.bytes-sent",
        event_name: [:ice, :packet_sent],
        measurement: :bytes
      )
    ]
  end
end
