defmodule XMAVLink.Signing do
  @moduledoc """
  Stateful MAVLink 2 signing policy helpers.

  This module validates parsed signed frames against a shared key and tracks
  inbound replay state by `{source_system, source_component, link_id}`. It is
  intentionally independent from router/connection wiring so the policy can be
  tested before transports start accepting signed traffic.
  """

  alias XMAVLink.Frame
  alias XMAVLink.Signing

  @mavlink_epoch_unix_microseconds 1_420_070_400_000_000
  @signature_timestamp_max 0xFFFF_FFFF_FFFF
  @max_initial_timestamp_lag 6_000_000

  defstruct secret_key: nil,
            link_id: nil,
            timestamp: nil,
            accept_unsigned: false,
            stream_timestamps: %{}

  @type stream_key :: {0..255, 0..255, 0..255}
  @type t :: %Signing{
          secret_key: <<_::256>>,
          link_id: 0..255,
          timestamp: 0..281_474_976_710_655,
          accept_unsigned: boolean,
          stream_timestamps: %{stream_key() => 0..281_474_976_710_655}
        }

  @type new_error ::
          :invalid_accept_unsigned
          | :invalid_link_id
          | :invalid_secret_key
          | :invalid_timestamp
          | :missing_link_id
          | :missing_secret_key

  @type validate_error ::
          :invalid_mavlink_2_frame
          | :invalid_secret_key
          | :signature_invalid
          | :signature_replay
          | :signature_too_old
          | :signed_frame_unsupported
          | :unsigned_frame
          | :unsigned_frame_rejected

  @spec new(nil | keyword()) :: {:ok, t | nil} | {:error, new_error}
  def new(nil), do: {:ok, nil}

  def new(opts) when is_list(opts) do
    with {:ok, secret_key} <- fetch_secret_key(opts),
         {:ok, link_id} <- fetch_link_id(opts),
         {:ok, timestamp} <- validate_timestamp(Keyword.get(opts, :timestamp, now_timestamp())),
         {:ok, accept_unsigned} <-
           validate_accept_unsigned(Keyword.get(opts, :accept_unsigned, false)) do
      {:ok,
       %Signing{
         secret_key: secret_key,
         link_id: link_id,
         timestamp: timestamp,
         accept_unsigned: accept_unsigned
       }}
    end
  end

  @spec validate_inbound(Frame.t(), t | nil) ::
          {:ok, Frame.t(), t | nil} | {:error, validate_error, t | nil}
  def validate_inbound(frame = %Frame{}, nil) do
    if Frame.signed?(frame) do
      {:error, :signed_frame_unsupported, nil}
    else
      {:ok, frame, nil}
    end
  end

  def validate_inbound(frame = %Frame{}, signing = %Signing{}) do
    cond do
      Frame.signed?(frame) ->
        validate_signed_inbound(frame, signing)

      signing.accept_unsigned ->
        {:ok, frame, signing}

      true ->
        {:error, :unsigned_frame_rejected, signing}
    end
  end

  @spec now_timestamp() :: 0..281_474_976_710_655
  def now_timestamp do
    timestamp =
      (System.os_time(:microsecond) - @mavlink_epoch_unix_microseconds)
      |> div(10)

    timestamp
    |> max(0)
    |> min(@signature_timestamp_max)
  end

  defp validate_signed_inbound(frame, signing) do
    with :ok <- Frame.validate_signature(frame, signing.secret_key),
         :ok <- validate_inbound_timestamp(frame, signing) do
      {:ok, frame, record_inbound_timestamp(frame, signing)}
    else
      {:error, reason} -> {:error, reason, signing}
    end
  end

  defp validate_inbound_timestamp(
         %Frame{
           source_system: source_system,
           source_component: source_component,
           signature: %{link_id: link_id, timestamp: timestamp}
         },
         %Signing{stream_timestamps: stream_timestamps, timestamp: local_timestamp}
       ) do
    stream_key = {source_system, source_component, link_id}

    case Map.fetch(stream_timestamps, stream_key) do
      {:ok, previous_timestamp} when timestamp <= previous_timestamp ->
        {:error, :signature_replay}

      {:ok, _previous_timestamp} ->
        :ok

      :error ->
        if timestamp + @max_initial_timestamp_lag < local_timestamp do
          {:error, :signature_too_old}
        else
          :ok
        end
    end
  end

  defp record_inbound_timestamp(
         frame = %Frame{signature: %{timestamp: timestamp}},
         signing = %Signing{timestamp: local_timestamp, stream_timestamps: stream_timestamps}
       ) do
    %Signing{
      signing
      | timestamp: max(local_timestamp, timestamp),
        stream_timestamps: Map.put(stream_timestamps, stream_key(frame), timestamp)
    }
  end

  defp stream_key(%Frame{
         source_system: source_system,
         source_component: source_component,
         signature: %{link_id: link_id}
       }) do
    {source_system, source_component, link_id}
  end

  defp fetch_secret_key(opts) do
    case Keyword.fetch(opts, :secret_key) do
      {:ok, secret_key} when is_binary(secret_key) and byte_size(secret_key) == 32 ->
        {:ok, secret_key}

      {:ok, _secret_key} ->
        {:error, :invalid_secret_key}

      :error ->
        {:error, :missing_secret_key}
    end
  end

  defp fetch_link_id(opts) do
    case Keyword.fetch(opts, :link_id) do
      {:ok, link_id} when is_integer(link_id) and link_id in 0..255 ->
        {:ok, link_id}

      {:ok, _link_id} ->
        {:error, :invalid_link_id}

      :error ->
        {:error, :missing_link_id}
    end
  end

  defp validate_timestamp(timestamp)
       when is_integer(timestamp) and timestamp in 0..@signature_timestamp_max,
       do: {:ok, timestamp}

  defp validate_timestamp(_timestamp), do: {:error, :invalid_timestamp}

  defp validate_accept_unsigned(accept_unsigned) when is_boolean(accept_unsigned),
    do: {:ok, accept_unsigned}

  defp validate_accept_unsigned(_accept_unsigned), do: {:error, :invalid_accept_unsigned}
end
