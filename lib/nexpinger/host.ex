defmodule NexPinger.Host do
  @moduledoc """
  A monitored host and its items.
  """

  alias NexPinger.{Item, Resolver}

  @enforce_keys [:name, :address, :items]
  defstruct name: nil,
            address: nil,
            family: :auto,
            items: [],
            mac_address: nil

  @type t :: %__MODULE__{
          name: String.t(),
          address: String.t(),
          family: Resolver.family(),
          items: [Item.t()],
          mac_address: String.t() | nil
        }
end
