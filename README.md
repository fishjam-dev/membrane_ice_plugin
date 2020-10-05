# Membrane Multimedia Framework: Interactive Connectivity Establishment (ICE) Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_ice_plugin.svg)](https://hex.pm/packages/membrane_ice_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_ice_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_ice_plugin)

This package uses [elixir_libnice] to provide GStreamer-style ICE source & sink elements.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

The package can be installed by adding `membrane_ice_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_ice_plugin, "~> 0.1.0"}
  ]
end
```

## Usage

See [example_project](examples/example_project) for example usage or refer to
[hex.pm](https://hex.pm/packages/membrane_ice_plugin) for more details about how to interact with
Sink and Source.

## Copyright and License

Copyright 2020, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_ice)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_ice)

Licensed under the [Apache License, Version 2.0](LICENSE)

[libnice]: https://libnice.freedesktop.org/
[elixir_libnice]: https://github.com/membraneframework/elixir_libnice
