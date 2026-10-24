defmodule NexPinger.ErrorQueue do
  @moduledoc """
  Linux only. Turns on IP_RECVERR / IPV6_RECVERR for a `:socket` and reads why it failed
  from its error queue.

  Without these options Linux reports only the ICMP errors it counts as fatal
  (Port Unreachable, Admin Prohibited, etc.). Time Exceeded and the Net / Host Unreachable
  that routers usually send never reach the socket, and recv waits until the timeout.
  With them, recv fails at once (Time Exceeded as `:ehostunreach`), and the error queue
  holds the ICMP type and code.
  """

  # sock_extended_err.ee_origin
  @origin_icmp 2
  @origin_icmp6 3

  @time_exceeded_v4 11
  @time_exceeded_v6 3

  @spec enable(:socket.socket(), :inet | :inet6) :: :ok | {:error, term()}
  def enable(socket, :inet), do: :socket.setopt(socket, {:ip, :recverr}, true)
  def enable(socket, :inet6), do: :socket.setopt(socket, {:ipv6, :recverr}, true)

  @doc """
  Takes the first error from the queue without waiting.
  Returns `:ttl_expired` for a Time Exceeded in transit, else `:other` (also when the
  queue is empty); the caller then goes by the error recv returned.
  """
  @spec cause(:socket.socket()) :: :ttl_expired | :other
  def cause(socket) do
    case :socket.recvmsg(socket, 0, 0, [:errqueue], 0) do
      {:ok, %{ctrl: ctrl}} ->
        Enum.find_value(ctrl, :other, fn
          %{type: :recverr, data: data} -> classify(data)
          _other -> nil
        end)

      _error ->
        :other
    end
  end

  # struct sock_extended_err: ee_errno(32) ee_origin ee_type ee_code ee_pad ee_info(32)
  # ee_data(32), then the offender address. Decoded here rather than from OTP's `value`,
  # which gives type and code as atoms only for the ones it knows.
  # Code 0 is "in transit"; code 1 (fragment reassembly) is not a TTL expiry.
  @doc false
  @spec classify(binary()) :: :ttl_expired | :other
  def classify(<<_errno::32, @origin_icmp, @time_exceeded_v4, 0, _rest::binary>>),
    do: :ttl_expired

  def classify(<<_errno::32, @origin_icmp6, @time_exceeded_v6, 0, _rest::binary>>),
    do: :ttl_expired

  def classify(_data), do: :other
end
