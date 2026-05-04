defmodule XMAVLink.HeartbeatTest do
  use ExUnit.Case, async: false

  alias XMAVLink.Heartbeat

  # `XMAVLink.Router.pack_and_send/2` sends `{:local, %Frame{message: ...}}`
  # to the process registered under the `XMAVLink.Router` name. Tests
  # run with `--no-start` (see mix.exs aliases), so the real router
  # isn't running. We register the test process under that name, let
  # it capture the framed message, then unregister.

  setup do
    # Make the test process stand in for the router so it receives the
    # framed messages produced by pack_and_send.
    Process.register(self(), XMAVLink.Router)

    on_exit(fn ->
      case Process.whereis(XMAVLink.Router) do
        nil -> :ok
        _pid -> :ok
      end
    end)

    :ok
  end

  describe "with a static :message" do
    test "emits the configured heartbeat immediately and on every interval" do
      msg = sample_heartbeat()
      {:ok, hb} = Heartbeat.start_link(interval_ms: 50, message: msg)

      # First heartbeat fires ASAP so peer-learning routers admit us
      # without waiting a full interval.
      assert_receive {:local, %{message: ^msg}}, 200
      assert_receive {:local, %{message: ^msg}}, 200

      GenServer.stop(hb)
    end
  end

  describe "with a {m, f, a} :builder" do
    test "calls the builder on each tick and dispatches the result" do
      :persistent_term.put({__MODULE__, :counter}, 0)

      {:ok, hb} =
        Heartbeat.start_link(
          interval_ms: 50,
          builder: {__MODULE__, :build_heartbeat_with_counter, []}
        )

      assert_receive {:local, %{message: %{custom_mode: 1}}}, 200
      assert_receive {:local, %{message: %{custom_mode: n}}} when n >= 2, 200

      GenServer.stop(hb)
    end
  end

  describe "validation" do
    test "raises when both :message and :builder are provided" do
      assert_raise ArgumentError, ~r/either :message or :builder, not both/, fn ->
        Heartbeat.init(
          interval_ms: 1000,
          message: sample_heartbeat(),
          builder: {__MODULE__, :build_heartbeat_with_counter, []}
        )
      end
    end

    test "raises when neither :message nor :builder is provided" do
      assert_raise ArgumentError, ~r/must include either :message or :builder/, fn ->
        Heartbeat.init(interval_ms: 1000)
      end
    end

    test "raises when :interval_ms is missing" do
      assert_raise KeyError, fn ->
        Heartbeat.init(message: sample_heartbeat())
      end
    end

    test "raises when :builder is malformed" do
      assert_raise ArgumentError, ~r/must be a \{module, function, args\}/, fn ->
        Heartbeat.init(interval_ms: 1000, builder: :not_an_mfa)
      end
    end
  end

  test "logs but keeps ticking when the builder raises" do
    {:ok, hb} =
      Heartbeat.start_link(
        interval_ms: 30,
        builder: fn -> raise "boom" end
      )

    # The GenServer must stay alive (the error is logged, not crashed).
    Process.sleep(100)
    assert Process.alive?(hb)

    GenServer.stop(hb)
  end

  # --- helpers ---

  def build_heartbeat_with_counter do
    n = :persistent_term.get({__MODULE__, :counter}, 0) + 1
    :persistent_term.put({__MODULE__, :counter}, n)

    %Common.Message.Heartbeat{
      type: :mav_type_gcs,
      autopilot: :mav_autopilot_invalid,
      base_mode: MapSet.new(),
      custom_mode: n,
      system_status: :mav_state_active,
      mavlink_version: 3
    }
  end

  defp sample_heartbeat do
    %Common.Message.Heartbeat{
      type: :mav_type_gcs,
      autopilot: :mav_autopilot_invalid,
      base_mode: MapSet.new(),
      custom_mode: 0,
      system_status: :mav_state_active,
      mavlink_version: 3
    }
  end
end
