defmodule ExPingNext.Host do
  @moduledoc """
  監視対象1台分の設定を保持する構造体。
  """

  @enforce_keys [:name, :address, :type]
  defstruct name: nil,
            address: nil,
            type: :icmp,
            port: nil,
            interval: 1000,
            timeout: 1000,
            mac_address: nil

  @type t :: %__MODULE__{
          name: String.t(),
          address: String.t(),
          type: :icmp | :tcp,
          port: non_neg_integer() | nil,
          interval: non_neg_integer(),
          timeout: non_neg_integer(),
          mac_address: String.t() | nil
        }
end
