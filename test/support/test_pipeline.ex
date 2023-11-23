defmodule Membrane.ICE.Support.TestPipeline do
  @moduledoc false

  use Membrane.Pipeline

  require Membrane.Logger

  @impl true
  def handle_init(_context, opts) do
    spec = child(:ice, struct(Membrane.ICE.Endpoint, opts))

    {[spec: spec], %{}}
  end
end
