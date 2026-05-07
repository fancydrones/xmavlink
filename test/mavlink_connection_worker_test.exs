defmodule XMAVLink.Test.ConnectionWorker do
  use ExUnit.Case, async: true

  alias XMAVLink.ConnectionWorker

  defmodule Transport do
    defstruct [:worker, :parent, :attempt]

    def open(tokens, worker) do
      parent = Keyword.fetch!(tokens, :parent)
      attempt = Process.get(:open_attempt, 0) + 1
      Process.put(:open_attempt, attempt)
      send(parent, {:open_attempt, attempt})

      if attempt <= Keyword.get(tokens, :failures, 0) do
        {:error, {:failed_attempt, attempt}}
      else
        {:ok, Keyword.get(tokens, :connection_key, :fake_connection),
         %__MODULE__{worker: worker, parent: parent, attempt: attempt}}
      end
    end

    def close(%__MODULE__{parent: parent, attempt: attempt}) do
      send(parent, {:closed, attempt})
      :ok
    end

    def forward(%__MODULE__{parent: parent, attempt: attempt}, frame) do
      send(parent, {:forwarded, attempt, frame})
      :ok
    end
  end

  test "retries failed opens and announces the connection after success" do
    {:ok, worker} =
      ConnectionWorker.start_link(%{
        router: self(),
        transport: Transport,
        tokens: [parent: self(), failures: 2],
        retry_ms: 5
      })

    assert_receive {:open_attempt, 1}, 100
    assert_receive {:open_attempt, 2}, 100
    assert_receive {:open_attempt, 3}, 100

    assert_receive {:add_connection, :fake_connection, %Transport{attempt: 3}, ^worker}, 100

    assert %{status: :connected, connection_key: :fake_connection} =
             ConnectionWorker.status(worker)

    GenServer.stop(worker)
  end

  test "reconnect closes the current connection and opens another one" do
    {:ok, worker} =
      ConnectionWorker.start_link(%{
        router: self(),
        transport: Transport,
        tokens: [parent: self(), failures: 0],
        retry_ms: 5
      })

    assert_receive {:open_attempt, 1}, 100
    assert_receive {:add_connection, :fake_connection, connection, ^worker}, 100

    ConnectionWorker.forward(worker, connection, :frame)
    assert_receive {:forwarded, 1, :frame}, 100

    ConnectionWorker.reconnect(worker)

    assert_receive {:closed, 1}, 100
    assert_receive {:open_attempt, 2}, 100
    assert_receive {:add_connection, :fake_connection, %Transport{attempt: 2}, ^worker}, 100

    GenServer.stop(worker)
  end

  test "ignores stale retry timer messages after an explicit reconnect" do
    {:ok, worker} =
      ConnectionWorker.start_link(%{
        router: self(),
        transport: Transport,
        tokens: [parent: self(), failures: 1],
        retry_ms: 1_000
      })

    assert_receive {:open_attempt, 1}, 100
    assert %{retry_timer: {_timer_ref, connect_ref}} = ConnectionWorker.status(worker)

    ConnectionWorker.reconnect(worker)

    assert_receive {:open_attempt, 2}, 100
    assert_receive {:add_connection, :fake_connection, %Transport{attempt: 2}, ^worker}, 100

    send(worker, {:connect, connect_ref})
    refute_receive {:open_attempt, 3}, 50

    GenServer.stop(worker)
  end
end
