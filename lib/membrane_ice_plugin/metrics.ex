defmodule Membrane.ICE.Metrics do
  @moduledoc """
  Defines list of metrics, that can be aggregated based on events from membrane_ice_plugin.
  """

  @doc """
  Returns list of metrics, that can be aggregated based on events from membrane_ice_plugin.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics() do
    [
      Telemetry.Metrics.counter(
        "ice.packets_received",
        event_name: [Membrane.ICE, :ice, :payload, :received]
      ),
      Telemetry.Metrics.sum(
        "ice.bytes_received",
        event_name: [Membrane.ICE, :ice, :payload, :received],
        measurement: :bytes
      ),
      Telemetry.Metrics.counter(
        "ice.packets_sent",
        event_name: [Membrane.ICE, :ice, :payload, :sent]
      ),
      Telemetry.Metrics.sum(
        "ice.bytes_sent",
        event_name: [Membrane.ICE, :ice, :payload, :sent],
        measurement: :bytes
      ),
      Telemetry.Metrics.counter(
        "ice.binding_responses_sent",
        event_name: [Membrane.ICE, :stun, :response, :sent]
      ),
      Telemetry.Metrics.counter(
        "ice.binding_requests_received",
        event_name: [Membrane.ICE, :stun, :request, :received]
      ),
      Telemetry.Metrics.counter(
        "ice.keepalives_sent",
        event_name: [Membrane.ICE, :stun, :keepalive, :sent]
      ),
      Telemetry.Metrics.counter(
        "ice.buffers_processed",
        event_name: [Membrane.ICE, :ice, :buffer, :processing_time]
      ),
      Telemetry.Metrics.sum(
        "ice.buffers_processed_time",
        event_name: [Membrane.ICE, :ice, :buffer, :processing_time],
        measurement: :microseconds
      )
    ]
  end
end
