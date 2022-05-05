defmodule Membrane.ICE.Support.TestPipeline do
  @moduledoc false

  use Membrane.Pipeline

  require Membrane.Logger

  @impl true
  def handle_init(opts) do
    children = %{ice: struct(Membrane.ICE.Endpoint, opts)}
    spec = %ParentSpec{children: children}

    {{:ok, spec: spec, playback: :playing}, %{}}
  end
end
