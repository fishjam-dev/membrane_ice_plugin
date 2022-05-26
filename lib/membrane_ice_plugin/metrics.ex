defmodule Membrane.ICE.Metrics do
  @moduledoc false

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics() do
    [
      Telemetry.Metrics.counter(
        "ice.packets_received",
        event_name: [:ice, :payload, :received]
      ),
      Telemetry.Metrics.sum(
        "ice.bytes_received",
        event_name: [:ice, :payload, :received],
        measurement: :bytes
      ),
      Telemetry.Metrics.counter(
        "ice.packets_sent",
        event_name: [:ice, :payload, :sent]
      ),
      Telemetry.Metrics.sum(
        "ice.bytes_sent",
        event_name: [:ice, :payload, :sent],
        measurement: :bytes
      ),
      Telemetry.Metrics.counter(
        "ice.binding_responses_sent",
        event_name: [:stun, :response, :sent]
      ),
      Telemetry.Metrics.counter(
        "ice.binding_requests_received",
        event_name: [:stun, :request, :received]
      ),
      Telemetry.Metrics.counter(
        "ice.keepalives_sent",
        event_name: [:stun, :keepalive, :sent]
      )
    ]
  end
end
