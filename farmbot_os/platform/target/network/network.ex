defmodule Farmbot.Target.Network do
  @moduledoc "Bring up network."

  import Farmbot.Config, only: [get_config_value: 3, get_all_network_configs: 0]
  alias Farmbot.Config.NetworkInterface
  alias Farmbot.Target.Network.Manager, as: NetworkManager
  alias Farmbot.Target.Network.NotFoundTimer
  alias Farmbot.Target.Network.ScanResult

  use Supervisor
  require Farmbot.Logger

  @doc "List available interfaces. Removes unusable entries."
  def get_interfaces(tries \\ 5)
  def get_interfaces(0), do: []

  def get_interfaces(tries) do
    case Nerves.NetworkInterface.interfaces() do
      ["lo"] ->
        Process.sleep(100)
        get_interfaces(tries - 1)

      interfaces when is_list(interfaces) ->
        interfaces
        # Delete unusable entries if they exist.
        |> List.delete("usb0")
        |> List.delete("lo")
        |> List.delete("sit0")
        |> Map.new(fn interface ->
          {:ok, settings} = Nerves.NetworkInterface.status(interface)
          {interface, settings}
        end)
    end
  end

  @doc "Scan on an interface."
  def scan(iface) do
    do_scan(iface)
    |> ScanResult.decode()
    |> ScanResult.sort_results()
    |> ScanResult.decode_security()
    |> Enum.filter(&Map.get(&1, :ssid))
    |> Enum.map(&Map.update(&1, :ssid, nil, fn ssid -> to_string(ssid) end))
    |> Enum.reject(&String.contains?(&1.ssid, "\\x00"))
    |> Enum.uniq_by(fn %{ssid: ssid} -> ssid end)
  end

  defp wait_for_results(pid) do
    Nerves.WpaSupplicant.request(pid, :SCAN_RESULTS)
    |> String.trim()
    |> String.split("\n")
    |> tl()
    |> Enum.map(&String.split(&1, "\t"))
    |> reduce_decode()
    |> case do
      [] ->
        Process.sleep(500)
        wait_for_results(pid)

      res ->
        res
    end
  end

  defp reduce_decode(results, acc \\ [])
  defp reduce_decode([], acc), do: Enum.reverse(acc)

  defp reduce_decode([[bssid, freq, signal, flags, ssid] | rest], acc) do
    decoded = %{
      bssid: bssid,
      frequency: String.to_integer(freq),
      flags: flags,
      level: String.to_integer(signal),
      ssid: ssid
    }

    reduce_decode(rest, [decoded | acc])
  end

  defp reduce_decode([[bssid, freq, signal, flags] | rest], acc) do
    decoded = %{
      bssid: bssid,
      frequency: String.to_integer(freq),
      flags: flags,
      level: String.to_integer(signal),
      ssid: nil
    }

    reduce_decode(rest, [decoded | acc])
  end

  defp reduce_decode([_ | rest], acc) do
    reduce_decode(rest, acc)
  end

  def do_scan(iface) do
    pid = :"Nerves.WpaSupplicant.#{iface}"

    if Process.whereis(pid) do
      Nerves.WpaSupplicant.request(pid, :SCAN)
      wait_for_results(pid)
    else
      []
    end
  end

  def get_level(ifname, ssid) do
    r = Farmbot.Target.Network.scan(ifname)

    if res = Enum.find(r, &(Map.get(&1, :ssid) == ssid)) do
      res.level
    end
  end

  @doc "Tests if we can make dns queries."
  def test_dns(hostname \\ nil)

  def test_dns(nil) do
    case get_config_value(:string, "authorization", "server") do
      nil ->
        test_dns(get_config_value(:string, "settings", "default_dns_name"))

      url when is_binary(url) ->
        %URI{host: hostname} = URI.parse(url)
        test_dns(hostname)
    end
  end

  def test_dns(hostname) when is_binary(hostname) do
    test_dns(to_charlist(hostname))
  end

  def test_dns(hostname) do
    :ok = :inet_db.clear_cache()
    # IO.puts "testing dns: #{hostname}"
    case :inet.parse_ipv4_address(hostname) do
      {:ok, addr} -> {:ok, {:hostent, hostname, [], :inet, 4, [addr]}}
      _ -> :inet_res.gethostbyname(hostname)
    end
  end

  # TODO Expand this to allow for more settings.
  def to_network_config(config)

  def to_network_config(%NetworkInterface{type: "wireless"} = config) do
    Farmbot.Logger.debug(3, "wireless network config: ssid: #{config.ssid}")
    Nerves.Network.set_regulatory_domain(config.regulatory_domain)
    case config.security do
      "WPA-EAP" ->
        opts = [
          ssid: config.ssid,
          scan_ssid: 1,
          key_mgmt: :"WPA-EAP",
          pairwise: :"CCMP TKIP",
          group: :"CCMP TKIP",
          eap: :PEAP,
          identity: config.identity,
          password: config.password,
          phase1: "peapver=auto",
          phase2: "MSCHAPV2"
        ]
        ip_settings = ip_settings(config)
        {config.name, [networks: [opts ++ ip_settings]]}
      "WPA-PSK" ->
        opts = [ssid: config.ssid, psk: config.psk, key_mgmt: :"WPA-PSK", scan_ssid: 1]
        ip_settings = ip_settings(config)
        {config.name, [networks: [opts ++ ip_settings]]}
      "NONE" ->
        opts = [ssid: config.ssid, psk: config.psk, scan_ssid: 1]
        ip_settings = ip_settings(config)
        {config.name, [networks: [opts ++ ip_settings]]}
      other -> raise "Unsupported wireless security type: #{other}"
    end
  end

  def to_network_config(%NetworkInterface{type: "wired"} = config) do
    {config.name, ip_settings(config)}
  end

  defp ip_settings(config) do
    case config.ipv4_method do
      "static" ->
        [
          ipv4_address_method: :static,
          ipv4_address: config.ipv4_address,
          ipv4_gateway: config.ipv4_gateway,
          ipv4_subnet_mask: config.ipv4_subnet_mask
        ]

        {name, Keyword.merge(opts, settings)}

      "dhcp" ->
        {name, opts}
    end
    |> maybe_use_name_servers(config)
    |> maybe_use_domain(config)
  end

  # This is a typo. It should have been `nameservers` not `name_servers`
  # It is however stored in the database as
  # `name_servers`, so it can not be changed without a migration.
  defp maybe_use_name_servers(opts, config) do
    if config.name_servers do
      Keyword.put(opts, :nameservers, String.split(config.name_servers, " "))
    else
      opts
    end
  end

  defp maybe_use_domain(opts, config) do
    if config.domain do
      Keyword.put(opts, :domain, config.domain)
    else
      opts
    end
  end

  def to_child_spec({interface, opts}) do
    worker(NetworkManager, [interface, opts], restart: :transient)
  end

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init([]) do
    config = get_all_network_configs()
    Farmbot.Logger.info(3, "Starting Networking")
    s1 = Farmbot.Config.get_config_value(:string, "settings", "default_ntp_server_1")
    s2 = Farmbot.Config.get_config_value(:string, "settings", "default_ntp_server_2")
    Nerves.Time.set_ntp_servers([s1, s2])
    maybe_hack_tzdata()

    children =
      config
      |> Enum.map(&to_network_config/1)
      |> Enum.map(&to_child_spec/1)
      # Don't know why/if we need this?
      |> Enum.uniq()

    children = [{NotFoundTimer, []}] ++ children
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 20, max_seconds: 1)
  end

  @fb_data_dir Application.get_env(:farmbot_ext, :data_path)
  @tzdata_dir Application.app_dir(:tzdata, "priv")
  def maybe_hack_tzdata do
    case Tzdata.Util.data_dir() do
      @fb_data_dir ->
        :ok

      _ ->
        Farmbot.Logger.debug(3, "Hacking tzdata.")
        objs_to_cp = Path.wildcard(Path.join(@tzdata_dir, "*"))

        for obj <- objs_to_cp do
          File.cp_r(obj, @fb_data_dir)
        end

        Application.put_env(:tzdata, :data_dir, @fb_data_dir)
        :ok
    end
  end
end
