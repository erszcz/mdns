defmodule Mdns.Server do
    use GenServer
    require Logger

    @mdns_group {224,0,0,251}
    @port 5353

    @response_packet %DNS.Record{
        header: %DNS.Header{
            aa: true,
            qr: true,
            opcode: 0,
            rcode: 0,
        },
        anlist: []
    }

    defmodule State do
        defstruct udp: nil,
            services: [],
            ip: {0,0,0,0}
    end

    defmodule Service do
        defstruct domain: "_nerves._tcp.local",
            data: "_myapp._tcp.local",
            ttl: 120,
            type: :ptr
    end

    def start_link do
        GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    def add_service(%Service{} = service) do
        GenServer.call(__MODULE__, {:add_service, service})
    end

    def set_ip(ip) do
        GenServer.call(__MODULE__, {:ip, ip})
    end

    def start do
        GenServer.call(__MODULE__, :start)
    end

    def init(:ok) do
        {:ok, %State{}}
    end

    def handle_call(:start, _from, state) do
        udp_options = [
            :binary,
            active:          true,
            add_membership:  {@mdns_group, {0,0,0,0}},
            multicast_if:    {0,0,0,0},
            multicast_loop:  true,
            multicast_ttl:   255,
            reuseaddr:       true
        ]
        {:ok, udp} = :gen_udp.open(@port, udp_options)
        {:reply, :ok, %State{state | udp: udp}}
    end

    def handle_call({:ip, ip}, _from, state) do
        {:reply, :ok, %State{state | ip: ip}}
    end

    def handle_call({:add_service, service}, _from, state) do
        {:reply, :ok, %State{state | :services => Enum.uniq([service | state.services])}}
    end

    def handle_info({:udp, socket, ip, port, packet}, state) do
        {:noreply, handle_packet(ip, packet, state)}
    end

    def handle_packet(ip, packet, state) do
        try do
          record = DNS.Record.decode(packet)
          case record.header.qr do
              false -> handle_query(ip, record, state)
              _ -> state
          end
        catch
          :error, {:badmatch, {:error, :fmt}} ->
            Logger.error("DNS packet decode error: #{inspect ip} #{inspect packet}")
            state
        end
    end

    def handle_query(ip, record, state) do
        Logger.debug("Got Query: #{inspect record}")
        Enum.flat_map(record.qdlist, fn(%DNS.Query{} = q) ->
            Enum.reduce(state.services, [], fn(service, answers) ->
                cond do
                    service.domain == to_string(q.domain) ->
                        data =
                            case service.data do
                                :ip -> state.ip
                                _ ->
                                    case String.valid?(service.data) do
                                        true -> to_char_list(service.data)
                                        _ -> service.data
                                    end
                            end
                        [%DNS.Resource{
                            class: :in,
                            type: service.type,
                            ttl: service.ttl,
                            data: data,
                            domain: to_char_list(service.domain)
                        } | answers]
                    true -> answers
                end
            end)
        end) |> send_service_response(record, state)
        state
    end

    def send_service_response(services, record, state) do
        cond do
            length(services) > 0 ->
                packet = %DNS.Record{@response_packet | :anlist => services}
                Logger.debug("Sending Packet: #{inspect packet}")
                :gen_udp.send(state.udp, @mdns_group, @port, DNS.Record.encode(packet))
            true -> :nil
        end

    end

end
