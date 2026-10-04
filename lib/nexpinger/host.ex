defmodule NexPinger.Host do
  @moduledoc """
  A monitored host and its items.
  `ip` and `resolved` (its text form) are set once at startup.
  `mac_address` is set per probe.
  """

  alias NexPinger.{Item, Resolver}

  @enforce_keys [:name, :address, :items]
  defstruct name: nil,
            address: nil,
            family: :auto,
            items: [],
            ip: nil,
            resolved: nil,
            mac_address: nil

  @type t :: %__MODULE__{
          name: String.t(),
          address: String.t(),
          family: Resolver.family(),
          items: [Item.t()],
          ip: :inet.ip_address() | nil,
          resolved: String.t() | nil,
          mac_address: String.t() | nil
        }
end
