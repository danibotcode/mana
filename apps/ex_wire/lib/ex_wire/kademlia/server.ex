defmodule ExWire.Kademlia.Server do
  @moduledoc """
  GenServer that manages Kademlia state
  """
  use GenServer

  alias ExWire.Kademlia.{Discovery, Node, RoutingTable}

  @type state :: %{
          routing_table: RoutingTable.t() | nil,
          ignore_pongs: boolean() | nil,
          connection_observer: module() | nil
        }
  defstruct [:routing_table, :ignore_pongs, :connection_observer]
  @max_discovery_rounds 7

  # 5s
  @discovery_round_period 5_000

  # 10s
  @pong_cleanup_period 10_000

  @name __MODULE__
  @spec name() :: unquote(@name)
  def name, do: @name

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(params) do
    name = Keyword.get(params, :name, @name)
    network_client_name = Keyword.fetch!(params, :network_client_name)
    current_node = Keyword.fetch!(params, :current_node)
    nodes = Keyword.get(params, :nodes, [])
    connection_observer = Keyword.get(params, :connection_observer)

    GenServer.start_link(
      __MODULE__,
      {current_node, network_client_name, nodes, connection_observer},
      name: name
    )
  end

  @impl true
  def init({current_node = %Node{}, network_client_name, nodes, connection_observer}) do
    routing_table = RoutingTable.new(current_node, network_client_name)

    _ = schedule_discovery_round(0, nodes)
    schedule_pongs_cleanup()

    {:ok, %__MODULE__{routing_table: routing_table, connection_observer: connection_observer}}
  end

  @impl true
  def handle_cast({:refresh_node, node}, state = %{routing_table: table}) do
    updated_table = RoutingTable.refresh_node(table, node)

    {:noreply, %{state | routing_table: updated_table}}
  end

  def handle_cast(
        {:handle_pong, pong},
        state = %{routing_table: table}
      ) do
    updated_table =
      if Map.get(state, :ignore_pongs, false) do
        table
      else
        RoutingTable.handle_pong(table, pong)
      end

    {:noreply, %{state | routing_table: updated_table}}
  end

  def handle_cast({:handle_ping, params}, state = %{routing_table: table}) do
    updated_table = RoutingTable.handle_ping(table, params)

    {:noreply, %{state | routing_table: updated_table}}
  end

  def handle_cast({:ping, node}, state = %{routing_table: table}) do
    updated_table = RoutingTable.ping(table, node)

    {:noreply, %{state | routing_table: updated_table}}
  end

  def handle_cast({:handle_neighbours, neighbours}, state = %{routing_table: table}) do
    updated_table = RoutingTable.handle_neighbours(table, neighbours)

    {:noreply, %{state | routing_table: updated_table}}
  end

  def handle_cast({:set_ignore_pongs, ignore_pongs}, state) do
    {:noreply, Map.put(state, :ignore_pongs, ignore_pongs)}
  end

  @impl true
  def handle_call(:routing_table, _from, state = %{routing_table: routing_table}) do
    {:reply, routing_table, state}
  end

  def handle_call(
        {:neighbours, find_neighbours, endpoint},
        _from,
        state = %{routing_table: routing_table}
      ) do
    neighbours = RoutingTable.neighbours(routing_table, find_neighbours, endpoint)

    {:reply, neighbours, state}
  end

  def handle_call(
        :get_peers,
        _from,
        state
      ) do
    round = state.routing_table.discovery_round

    if round > 0 do
      {:reply, RoutingTable.discovery_nodes(state.routing_table), state}
    else
      {:reply, [], state}
    end
  end

  @impl true
  def handle_info(
        {:discovery_round, nodes},
        state = %{routing_table: routing_table, connection_observer: connection_observer}
      ) do
    updated_table = Discovery.start(routing_table, nodes)

    _ = schedule_discovery_round(updated_table.discovery_round)
    :ok = connection_observer.notify(:discovery_round)
    {:noreply, %{state | routing_table: updated_table}}
  end

  def handle_info(:remove_expired_nodes, state = %{routing_table: table}) do
    updated_table = RoutingTable.remove_expired_pongs(table)

    schedule_pongs_cleanup()

    {:noreply, %{state | routing_table: updated_table}}
  end

  @spec schedule_discovery_round(integer(), list(Node.t())) :: reference() | :ok
  defp schedule_discovery_round(round, nodes \\ []) do
    if round <= @max_discovery_rounds do
      Process.send_after(self(), {:discovery_round, nodes}, @discovery_round_period)
    else
      :ok
    end
  end

  @spec schedule_pongs_cleanup() :: reference()
  defp schedule_pongs_cleanup() do
    Process.send_after(self(), :remove_expired_nodes, @pong_cleanup_period)
  end
end
