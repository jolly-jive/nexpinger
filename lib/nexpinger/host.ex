defmodule NexPinger.Host do
  @moduledoc """
  A monitored host and its items.
  """

  alias NexPinger.Item

  @enforce_keys [:name, :address, :items]
  defstruct name: nil,
            address: nil,
            items: [],
            mac_address: nil

  @type t :: %__MODULE__{
          name: String.t(),
          address: String.t(),
          items: [Item.t()],
          mac_address: String.t() | nil
        }
end
