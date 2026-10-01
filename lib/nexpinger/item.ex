defmodule NexPinger.Item do
  @moduledoc """
  One check on a host.
  """

  @enforce_keys [:name, :type]
  defstruct name: nil,
            type: :icmp,
            service: nil,
            port: nil,
            interval: 1000,
            timeout: 1000

  @type t :: %__MODULE__{
          name: String.t(),
          type: :icmp | :tcp | :udp,
          service: NexPinger.UdpProbe.service() | nil,
          port: non_neg_integer() | nil,
          interval: non_neg_integer(),
          timeout: non_neg_integer()
        }
end
