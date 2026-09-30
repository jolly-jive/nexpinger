defmodule NexPinger.MacResolver do
  @moduledoc """
  同一 IPv4 サブネット上のホストについて、近隣テーブルから MAC アドレスを取得する。
  """

  import Bitwise

  @spec lookup(String.t()) :: String.t() | nil
  def lookup(address) do
    with {:ok, ip} <- :inet.getaddr(to_charlist(address), :inet),
         true <- same_subnet?(ip),
         {:ok, mac} <- neighbor_mac(ip) do
      mac
    else
      _ -> nil
    end
  end

  @spec same_subnet?({byte(), byte(), byte(), byte()}, list() | nil) :: boolean()
  def same_subnet?(target_ip, interfaces \\ nil) do
    interface_list =
      case interfaces || local_interfaces() do
        {:ok, interfaces} ->
          interfaces

        interfaces when is_list(interfaces) ->
          interfaces

        _ ->
          []
      end

    Enum.any?(interface_list, fn {local_ip, _broadcast, netmask} ->
      same_network?(target_ip, local_ip, netmask)
    end)
  end

  defp local_interfaces do
    case :inet.getif() do
      {:ok, interfaces} ->
        {:ok, interfaces}

      error ->
        error
    end
  end

  defp neighbor_mac(ip) do
    case :os.type() do
      {:unix, _} -> lookup_with_ip_command(ip)
      {:win32, _} -> lookup_with_arp_command(ip)
    end
  end

  defp lookup_with_ip_command(ip) do
    {output, exit_code} =
      System.cmd("ip", ["neigh", "show", ip_to_string(ip)], stderr_to_stdout: true)

    if exit_code == 0 do
      parse_ip_neighbor(output)
    else
      {:error, :not_found}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp lookup_with_arp_command(ip) do
    {output, exit_code} = System.cmd("arp", ["-a", ip_to_string(ip)], stderr_to_stdout: true)

    if exit_code == 0 do
      parse_arp(output)
    else
      {:error, :not_found}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp parse_ip_neighbor(output) do
    case Regex.run(~r/\blladdr\s+([0-9a-f]{2}(?::[0-9a-f]{2}){5})\b/i, output) do
      [_, mac] -> {:ok, String.downcase(mac)}
      nil -> {:error, :not_found}
    end
  end

  defp parse_arp(output) do
    case Regex.run(~r/\b([0-9a-f]{2}(?:[:-][0-9a-f]{2}){5})\b/i, output) do
      [_, mac] -> {:ok, String.downcase(String.replace(mac, "-", ":"))}
      nil -> {:error, :not_found}
    end
  end

  defp same_network?({a, b, c, d}, {e, f, g, h}, {mask_a, mask_b, mask_c, mask_d}) do
    band(a, mask_a) == band(e, mask_a) and
      band(b, mask_b) == band(f, mask_b) and
      band(c, mask_c) == band(g, mask_c) and
      band(d, mask_d) == band(h, mask_d)
  end

  defp ip_to_string({a, b, c, d}), do: Enum.join([a, b, c, d], ".")
end
