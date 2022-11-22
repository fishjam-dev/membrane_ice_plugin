defmodule Membrane.ICE.Support.TestPipeline do
  @moduledoc false

  use Membrane.Pipeline

  require Membrane.Logger

  @impl true
  def handle_init(_context, opts) do
    structure = [
      child(:ice, struct(Membrane.ICE.Endpoint, opts))
    ]

    spec = {structure}

    {[spec: spec, playback: :playing], %{}}
  end
end
