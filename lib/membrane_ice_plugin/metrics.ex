defmodule Membrane.ICE.Metrics do
  @moduledoc false

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics() do
    [
      Telemetry.Metrics.counter(
        "ice.packets-received",
        event_name: [:ice, :payload, :received]
      ),
      Telemetry.Metrics.sum(
        "ice.bytes-received",
        event_name: [:ice, :payload, :received],
        measurement: :bytes
      ),
      Telemetry.Metrics.counter(
        "ice.packets-sent",
        event_name: [:ice, :payload, :sent]
      ),
      Telemetry.Metrics.sum(
        "ice.bytes-sent",
        event_name: [:ice, :payload, :sent],
        measurement: :bytes
      ),
      Telemetry.Metrics.counter(
        "ice.binding-responses-sent",
        event_name: [:stun, :response, :sent]
      ),
      Telemetry.Metrics.counter(
        "ice.binding-requests-received",
        event_name: [:stun, :request, :received]
      ),
      Telemetry.Metrics.counter(
        "ice.keepalives-sent",
        event_name: [:stun, :keepalive, :sent]
      )
    ]
  end
end
