defmodule XMAVLink.LocalConnection do
  @moduledoc false
  # XMAVLink.Router delegate for local connections, i.e
  # Elixir processes using the Router API to subscribe to
  # and send MAVLink messages.

  require Logger

  import Enum, only: [reduce: 3, filter: 2]

  alias XMAVLink.Frame
  alias XMAVLink.LocalConnection

  defstruct system: nil,
            component: nil,
            subscription_cache: nil,
            subscriptions: [],
            sequence_number: 0,
            sequence_numbers: %{}

  @type t :: %LocalConnection{
          system: 1..255,
          component: 1..255,
          subscription_cache: GenServer.server() | nil,
          subscriptions: [],
          sequence_number: 0..255,
          sequence_numbers: %{{1..255, 1..255} => 0..255}
        }

  # Handle message from Router.pack_and_send()
  # We use handle_info instead of cast for symmetry
  # with the other connection types
  def handle_info(
        {:local, frame = %Frame{source_system: frame_system, source_component: frame_component}},
        receiving_connection = %LocalConnection{
          system: system,
          component: component
        },
        _dialect
      ) do
    # Fill in missing frame details source_system, source_component, sequence_number
    source_system = frame_system || system
    source_component = frame_component || component
    source_identity = {source_system, source_component}

    {sequence_number, updated_connection} =
      next_sequence_number(receiving_connection, source_identity)

    {
      :ok,
      :local,
      updated_connection,
      struct(frame,
        source_system: source_system,
        source_component: source_component,
        sequence_number: sequence_number
      )
      |> Frame.pack_frame()
    }
  end

  def new(system, component, subscription_cache \\ XMAVLink.SubscriptionCache) do
    local_connection =
      struct(LocalConnection,
        system: system,
        component: component,
        subscription_cache: subscription_cache
      )

    restore_subscriptions(local_connection)
  end

  def connect(:local, system, component, subscription_cache \\ XMAVLink.SubscriptionCache) do
    local_connection = new(system, component, subscription_cache)

    send(
      # Local connection guaranteed, so this connect() called directly from Router process
      self(),
      {
        :add_connection,
        :local,
        local_connection
      }
    )
  end

  def forward(to_connection, frame = %Frame{message: nil}) do
    # If we couldn't unpack the message set the message_type to XMAVLink.UnknownMessage
    forward(to_connection, struct(frame, message: %{__struct__: XMAVLink.UnknownMessage}))
  end

  def forward(
        %LocalConnection{
          subscriptions: subscriptions
        },
        frame = %Frame{
          source_system: source_system,
          source_component: source_component,
          target_system: target_system,
          target_component: target_component,
          target: target,
          message: message = %{__struct__: message_type}
        }
      ) do
    for {
          %{
            message: q_message_type,
            source_system: q_source_system,
            source_component: q_source_component,
            target_system: q_target_system,
            target_component: q_target_component,
            as_frame: as_frame?
          },
          pid
        } <- subscriptions do
      if (q_message_type == nil or q_message_type == message_type) and
           (q_source_system == 0 or q_source_system == source_system) and
           (q_source_component == 0 or q_source_component == source_component) and
           (q_target_system == 0 or
              (target != :broadcast and target != :component and q_target_system == target_system)) and
           (q_target_component == 0 or
              (target != :broadcast and target != :system and
                 q_target_component == target_component)) do
        send(pid, if(as_frame?, do: frame, else: message))
      end
    end
  end

  # Subscription request from subscriber
  def subscribe(query, pid, local_connection = %LocalConnection{}) do
    :ok = Logger.debug("Subscribe #{inspect(pid)} to query #{inspect(query)}")
    # Monitor so that we can unsubscribe dead processes
    Process.monitor(pid)
    # Uniq prevents duplicate subscriptions
    %LocalConnection{
      local_connection
      | subscriptions:
          Enum.uniq([{query, pid} | local_connection.subscriptions])
          |> update_subscription_cache(local_connection.subscription_cache)
    }
  end

  # Unsubscribe request from subscriber
  def unsubscribe(pid, local_connection = %LocalConnection{}) do
    :ok = Logger.debug("Unsubscribe #{inspect(pid)}")

    %LocalConnection{
      local_connection
      | subscriptions:
          filter(local_connection.subscriptions, &(not match?({_, ^pid}, &1)))
          |> update_subscription_cache(local_connection.subscription_cache)
    }
  end

  # Automatically unsubscribe a dead subscriber process
  def subscriber_down(pid, local_connection = %LocalConnection{}) do
    :ok = Logger.debug("Subscriber #{inspect(pid)} exited")

    %LocalConnection{
      local_connection
      | subscriptions:
          filter(local_connection.subscriptions, &(not match?({_, ^pid}, &1)))
          |> update_subscription_cache(local_connection.subscription_cache)
    }
  end

  defp restore_subscriptions(local_connection = %LocalConnection{subscription_cache: nil}) do
    local_connection
  end

  defp restore_subscriptions(
         local_connection = %LocalConnection{subscription_cache: subscription_cache}
       ) do
    case Agent.start(fn -> [] end, name: subscription_cache) do
      {:ok, _} ->
        :ok = Logger.debug("Started Subscription Cache #{inspect(subscription_cache)}")
        # No subscriptions to restore
        local_connection

      {:error, {:already_started, _}} ->
        :ok =
          Logger.debug(
            "Restoring subscriptions from Subscription Cache #{inspect(subscription_cache)}"
          )

        reduce(
          Agent.get(subscription_cache, fn subs -> subs end),
          local_connection,
          fn {query, pid}, lc -> subscribe(query, pid, lc) end
        )
    end
  end

  defp update_subscription_cache(subscriptions, nil), do: subscriptions

  defp update_subscription_cache(subscriptions, subscription_cache) do
    :ok = Logger.debug("Update subscription cache: #{inspect(subscriptions)}")
    Agent.update(subscription_cache, fn _ -> subscriptions end)
    subscriptions
  end

  defp next_sequence_number(local_connection = %LocalConnection{}, source_identity) do
    sequence_number =
      Map.get(
        local_connection.sequence_numbers,
        source_identity,
        initial_sequence_number(local_connection, source_identity)
      )

    next_sequence_number = rem(sequence_number + 1, 255)

    updated_connection = %LocalConnection{
      local_connection
      | sequence_number:
          default_sequence_number(local_connection, source_identity, next_sequence_number),
        sequence_numbers:
          Map.put(local_connection.sequence_numbers, source_identity, next_sequence_number)
    }

    {sequence_number, updated_connection}
  end

  defp initial_sequence_number(
         %LocalConnection{system: system, component: component, sequence_number: sequence_number},
         {system, component}
       ),
       do: sequence_number

  defp initial_sequence_number(_local_connection, _source_identity), do: 0

  defp default_sequence_number(
         %LocalConnection{system: system, component: component},
         {system, component},
         next
       ),
       do: next

  defp default_sequence_number(
         %LocalConnection{sequence_number: sequence_number},
         _source_identity,
         _next
       ),
       do: sequence_number
end
