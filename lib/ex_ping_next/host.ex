defmodule ExPingNext.Host do
  @moduledoc """
  監視対象ホストと、そのホスト上の監視項目を保持する構造体。
  """

  alias ExPingNext.Item

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
