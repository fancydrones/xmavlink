defmodule XMAVLink.ConnectionWorker do
  @moduledoc false

  use GenServer
  require Logger

  defstruct [
    :router,
    :transport,
    :tokens,
    :connection_key,
    :connection,
    retry_ms: 1_000,
    retry_timer: nil,
    status: :disconnected
  ]

  @type transport :: module

  @type t :: %__MODULE__{
          router: pid,
          transport: transport,
          tokens: [term],
          connection_key: term | nil,
          connection: term | nil,
          retry_ms: non_neg_integer,
          retry_timer: reference | nil,
          status: :disconnected | :connecting | :connected
        }

  def start_link(args) do
    GenServer.start_link(__MODULE__, Map.new(args))
  end

  @doc false
  def child_spec(args) do
    args = Map.new(args)

    %{
      id: {__MODULE__, Map.fetch!(args, :tokens)},
      start: {__MODULE__, :start_link, [args]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  def reconnect(worker) when is_pid(worker) do
    GenServer.cast(worker, :reconnect)
  end

  @doc false
  def forward(worker, connection, frame) when is_pid(worker) do
    GenServer.cast(worker, {:forward, connection, frame})
  end

  @doc false
  def status(worker) when is_pid(worker) do
    GenServer.call(worker, :status)
  end

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      router: Map.fetch!(args, :router),
      transport: Map.fetch!(args, :transport),
      tokens: Map.fetch!(args, :tokens),
      retry_ms: Map.get(args, :retry_ms, 1_000)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: state.status,
       connection_key: state.connection_key,
       retry_timer: state.retry_timer
     }, state}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    state =
      state
      |> cancel_retry()
      |> close_connection()

    {:noreply, connect(%{state | connection_key: nil, connection: nil})}
  end

  def handle_cast({:forward, connection, frame}, state) do
    _ = state.transport.forward(connection, frame)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    {:noreply, connect(%{state | retry_timer: nil})}
  end

  def handle_info(message = {:udp, _socket, _address, _port, _raw}, state) do
    send(state.router, {:connection_message, self(), message})
    {:noreply, state}
  end

  def handle_info(message = {:tcp, _socket, _raw}, state) do
    send(state.router, {:connection_message, self(), message})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, state) do
    send(state.router, {:connection_closed, self(), socket})

    state =
      state
      |> close_connection()
      |> schedule_retry()

    {:noreply, %{state | connection_key: nil, connection: nil}}
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    send(state.router, {:connection_closed, self(), socket})

    state =
      state
      |> close_connection()
      |> schedule_retry(reason)

    {:noreply, %{state | connection_key: nil, connection: nil}}
  end

  def handle_info(message = {:circuits_uart, _port, raw}, state) when is_binary(raw) do
    send(state.router, {:connection_message, self(), message})
    {:noreply, state}
  end

  def handle_info({:circuits_uart, port, {:error, reason}}, state) do
    send(state.router, {:connection_closed, self(), port})

    state =
      state
      |> close_connection()
      |> schedule_retry(reason)

    {:noreply, %{state | connection_key: nil, connection: nil}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = close_connection(state)
    :ok
  end

  defp connect(state) do
    state = %{state | status: :connecting}

    case state.transport.open(state.tokens, self()) do
      {:ok, nil, connection} ->
        %{state | status: :connected, connection: connection}

      {:ok, connection_key, connection} ->
        send(state.router, {:add_connection, connection_key, connection, self()})

        %{
          state
          | status: :connected,
            connection_key: connection_key,
            connection: connection
        }

      {:error, reason} ->
        schedule_retry(state, reason)
    end
  end

  defp schedule_retry(state, reason \\ nil) do
    if reason do
      Logger.warning(
        "Could not open #{connection_description(state.tokens)}: #{inspect(reason)}. " <>
          "Retrying in #{state.retry_ms} ms"
      )
    end

    %{
      state
      | status: :disconnected,
        retry_timer: Process.send_after(self(), :connect, state.retry_ms)
    }
  end

  defp cancel_retry(%{retry_timer: nil} = state), do: state

  defp cancel_retry(%{retry_timer: retry_timer} = state) do
    Process.cancel_timer(retry_timer)
    %{state | retry_timer: nil}
  end

  defp close_connection(%{connection: nil} = state), do: state

  defp close_connection(state) do
    _ = state.transport.close(state.connection)
    state
  end

  defp connection_description([protocol, address, port])
       when is_tuple(address) and tuple_size(address) == 4 do
    "#{protocol}:#{Enum.join(Tuple.to_list(address), ".")}:#{port}"
  end

  defp connection_description(["serial", port, baud]), do: "serial:#{port}:#{baud}"
  defp connection_description(tokens), do: inspect(tokens)
end
