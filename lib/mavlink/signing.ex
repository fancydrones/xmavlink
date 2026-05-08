defmodule XMAVLink.Signing do
  @moduledoc """
  Stateful MAVLink 2 signing policy helpers.

  This module validates parsed signed frames against a shared key, tracks
  inbound replay state by `{source_system, source_component, link_id}`, and
  signs unsigned outbound MAVLink 2 frames with a per-connection timestamp.
  Optional timestamp load/save callbacks let applications preserve the local
  signing timestamp across restarts.
  """

  alias XMAVLink.Frame
  alias XMAVLink.Signing

  @mavlink_epoch_unix_microseconds 1_420_070_400_000_000
  @signature_timestamp_max 0xFFFF_FFFF_FFFF
  @max_initial_timestamp_lag 6_000_000

  defstruct secret_key: nil,
            link_id: nil,
            timestamp: nil,
            timestamp_load: nil,
            timestamp_save: nil,
            accept_unsigned: false,
            stream_timestamps: %{}

  @type timestamp :: 0..281_474_976_710_655
  @type stream_key :: {0..255, 0..255, 0..255}
  @type timestamp_load_result ::
          timestamp | {:ok, timestamp | nil} | nil | :error | {:error, term}
  @type timestamp_save_result :: :ok | {:ok, term} | :error | {:error, term}
  @type timestamp_load :: (-> timestamp_load_result) | {module, atom, [term]}
  @type timestamp_save :: (timestamp -> timestamp_save_result) | {module, atom, [term]}
  @type t :: %Signing{
          secret_key: <<_::256>>,
          link_id: 0..255,
          timestamp: timestamp,
          timestamp_load: timestamp_load | nil,
          timestamp_save: timestamp_save | nil,
          accept_unsigned: boolean,
          stream_timestamps: %{stream_key() => timestamp}
        }

  @type new_error ::
          :invalid_accept_unsigned
          | :invalid_options
          | :invalid_link_id
          | :invalid_secret_key
          | :invalid_timestamp
          | :invalid_timestamp_load
          | :invalid_timestamp_save
          | :missing_link_id
          | :missing_secret_key
          | :timestamp_load_failed

  @type validate_error ::
          :invalid_mavlink_2_frame
          | :invalid_secret_key
          | :signature_invalid
          | :signature_replay
          | :signature_too_old
          | :signed_frame_unsupported
          | :timestamp_save_failed
          | :unsigned_frame
          | :unsigned_frame_rejected

  @type sign_error ::
          :already_signed
          | :checksum_invalid
          | :invalid_crc_extra
          | :invalid_link_id
          | :invalid_mavlink_2_frame
          | :invalid_secret_key
          | :invalid_timestamp
          | :mavlink_1_not_signable
          | :missing_crc_extra
          | :missing_mavlink_2_raw
          | :timestamp_save_failed
          | :timestamp_exhausted
          | :unsupported_incompatible_flags

  @spec new(nil | keyword()) :: {:ok, t | nil} | {:error, new_error}
  def new(nil), do: {:ok, nil}

  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      new_keyword(opts)
    else
      {:error, :invalid_options}
    end
  end

  def new(_opts), do: {:error, :invalid_options}

  defp new_keyword(opts) do
    with {:ok, secret_key} <- fetch_secret_key(opts),
         {:ok, link_id} <- fetch_link_id(opts),
         {:ok, timestamp_load} <- validate_timestamp_load(Keyword.get(opts, :timestamp_load)),
         {:ok, timestamp_save} <- validate_timestamp_save(Keyword.get(opts, :timestamp_save)),
         {:ok, timestamp} <-
           initial_timestamp(Keyword.get_lazy(opts, :timestamp, &now_timestamp/0), timestamp_load),
         {:ok, accept_unsigned} <-
           validate_accept_unsigned(Keyword.get(opts, :accept_unsigned, false)) do
      {:ok,
       %Signing{
         secret_key: secret_key,
         link_id: link_id,
         timestamp: timestamp,
         timestamp_load: timestamp_load,
         timestamp_save: timestamp_save,
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
      frame.version == 1 ->
        {:ok, frame, signing}

      Frame.signed?(frame) ->
        validate_signed_inbound(frame, signing)

      signing.accept_unsigned ->
        {:ok, frame, signing}

      true ->
        {:error, :unsigned_frame_rejected, signing}
    end
  end

  @spec sign_outbound(Frame.t(), t | nil) ::
          {:ok, Frame.t(), t | nil} | {:error, sign_error, t | nil}
  def sign_outbound(frame = %Frame{}, nil), do: {:ok, frame, nil}

  def sign_outbound(frame = %Frame{version: 1}, signing = %Signing{}),
    do: {:ok, frame, signing}

  def sign_outbound(
        frame = %Frame{version: 2, signature: %{timestamp: timestamp}},
        signing = %Signing{}
      )
      when is_integer(timestamp) do
    signing
    |> update_timestamp(max(signing.timestamp, timestamp))
    |> persist_if_timestamp_changed(signing)
    |> case do
      {:ok, updated_signing} -> {:ok, frame, updated_signing}
      {:error, reason} -> {:error, reason, signing}
    end
  end

  def sign_outbound(frame = %Frame{version: 2}, signing = %Signing{}) do
    with {:ok, timestamp} <- next_outbound_timestamp(signing),
         {:ok, signed_frame} <-
           Frame.sign_frame(frame, signing.secret_key, signing.link_id, timestamp),
         {:ok, updated_signing} <-
           signing
           |> update_timestamp(timestamp)
           |> persist_if_timestamp_changed(signing) do
      {:ok, signed_frame, updated_signing}
    else
      {:error, reason} -> {:error, reason, signing}
    end
  end

  @spec now_timestamp() :: timestamp
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
         :ok <- validate_inbound_timestamp(frame, signing),
         updated_signing = record_inbound_timestamp(frame, signing),
         {:ok, persisted_signing} <- persist_if_timestamp_changed(updated_signing, signing) do
      {:ok, frame, persisted_signing}
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

  defp next_outbound_timestamp(%Signing{timestamp: @signature_timestamp_max}),
    do: {:error, :timestamp_exhausted}

  defp next_outbound_timestamp(%Signing{timestamp: timestamp}), do: {:ok, timestamp + 1}

  defp update_timestamp(signing = %Signing{}, timestamp),
    do: %Signing{signing | timestamp: timestamp}

  defp persist_if_timestamp_changed(updated_signing, %Signing{timestamp: same_timestamp})
       when updated_signing.timestamp == same_timestamp,
       do: {:ok, updated_signing}

  defp persist_if_timestamp_changed(updated_signing, _previous_signing) do
    case save_timestamp(updated_signing.timestamp_save, updated_signing.timestamp) do
      :ok -> {:ok, updated_signing}
      {:error, reason} -> {:error, reason}
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

  defp initial_timestamp(configured_timestamp, timestamp_load) do
    with {:ok, configured_timestamp} <- validate_timestamp(configured_timestamp),
         {:ok, loaded_timestamp} <- load_timestamp(timestamp_load),
         {:ok, timestamp} <- resolve_initial_timestamp(configured_timestamp, loaded_timestamp) do
      {:ok, timestamp}
    end
  end

  defp resolve_initial_timestamp(configured_timestamp, nil), do: {:ok, configured_timestamp}

  defp resolve_initial_timestamp(configured_timestamp, loaded_timestamp) do
    case validate_timestamp(loaded_timestamp) do
      {:ok, loaded_timestamp} -> {:ok, max(configured_timestamp, loaded_timestamp)}
      {:error, :invalid_timestamp} -> {:error, :timestamp_load_failed}
    end
  end

  defp load_timestamp(nil), do: {:ok, nil}

  defp load_timestamp(timestamp_load) do
    timestamp_load
    |> call_timestamp_load()
    |> normalize_timestamp_load_result()
  end

  defp call_timestamp_load(timestamp_load) when is_function(timestamp_load, 0) do
    safe_call(fn -> timestamp_load.() end)
  end

  defp call_timestamp_load({module, function, args}) do
    safe_call(fn -> apply(module, function, args) end)
  end

  defp save_timestamp(nil, _timestamp), do: :ok

  defp save_timestamp(timestamp_save, timestamp) do
    timestamp_save
    |> call_timestamp_save(timestamp)
    |> normalize_timestamp_save_result()
  end

  defp call_timestamp_save(timestamp_save, timestamp) when is_function(timestamp_save, 1) do
    safe_call(fn -> timestamp_save.(timestamp) end)
  end

  defp call_timestamp_save({module, function, args}, timestamp) do
    safe_call(fn -> apply(module, function, args ++ [timestamp]) end)
  end

  defp safe_call(fun) do
    try do
      {:ok, fun.()}
    rescue
      _exception -> {:error, :callback_failed}
    catch
      _kind, _reason -> {:error, :callback_failed}
    end
  end

  defp normalize_timestamp_load_result({:ok, nil}), do: {:ok, nil}
  defp normalize_timestamp_load_result({:ok, {:ok, timestamp}}), do: {:ok, timestamp}

  defp normalize_timestamp_load_result({:ok, timestamp}) when is_integer(timestamp),
    do: {:ok, timestamp}

  defp normalize_timestamp_load_result(_result), do: {:error, :timestamp_load_failed}

  defp normalize_timestamp_save_result({:ok, :ok}), do: :ok
  defp normalize_timestamp_save_result({:ok, {:ok, _result}}), do: :ok
  defp normalize_timestamp_save_result(_result), do: {:error, :timestamp_save_failed}

  defp validate_timestamp(timestamp)
       when is_integer(timestamp) and timestamp in 0..@signature_timestamp_max,
       do: {:ok, timestamp}

  defp validate_timestamp(_timestamp), do: {:error, :invalid_timestamp}

  defp validate_accept_unsigned(accept_unsigned) when is_boolean(accept_unsigned),
    do: {:ok, accept_unsigned}

  defp validate_accept_unsigned(_accept_unsigned), do: {:error, :invalid_accept_unsigned}

  defp validate_timestamp_load(nil), do: {:ok, nil}

  defp validate_timestamp_load(timestamp_load) when is_function(timestamp_load, 0),
    do: {:ok, timestamp_load}

  defp validate_timestamp_load({module, function, args} = timestamp_load)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {:ok, timestamp_load}

  defp validate_timestamp_load(_timestamp_load), do: {:error, :invalid_timestamp_load}

  defp validate_timestamp_save(nil), do: {:ok, nil}

  defp validate_timestamp_save(timestamp_save) when is_function(timestamp_save, 1),
    do: {:ok, timestamp_save}

  defp validate_timestamp_save({module, function, args} = timestamp_save)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {:ok, timestamp_save}

  defp validate_timestamp_save(_timestamp_save), do: {:error, :invalid_timestamp_save}
end
