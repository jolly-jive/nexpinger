defmodule NexPinger.Item do
  @moduledoc """
  One check on a host.
  """

  @enforce_keys [:name, :type]
  defstruct name: nil,
            type: :icmp,
            port: nil,
            interval: 1000,
            timeout: 1000

  @type t :: %__MODULE__{
          name: String.t(),
          type: :icmp | :tcp,
          port: non_neg_integer() | nil,
          interval: non_neg_integer(),
          timeout: non_neg_integer()
        }
end
