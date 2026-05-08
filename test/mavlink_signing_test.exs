defmodule XMAVLink.Test.Signing do
  use ExUnit.Case, async: true

  alias XMAVLink.Frame
  alias XMAVLink.Signing

  @secret_key :binary.copy(<<42>>, 32)
  @wrong_secret_key :binary.copy(<<43>>, 32)
  @link_id 9
  @local_timestamp 10_000_000
  @valid_timestamp 10_000_001

  describe "new/1" do
    test "normalizes disabled and configured signing policy" do
      assert {:ok, nil} = Signing.new(nil)

      assert {:ok,
              %Signing{
                secret_key: @secret_key,
                link_id: @link_id,
                timestamp: @local_timestamp,
                accept_unsigned: true,
                stream_timestamps: %{}
              }} =
               Signing.new(
                 secret_key: @secret_key,
                 link_id: @link_id,
                 timestamp: @local_timestamp,
                 accept_unsigned: true
               )
    end

    test "rejects invalid signing policy inputs" do
      assert {:error, :missing_secret_key} = Signing.new(link_id: @link_id)
      assert {:error, :invalid_secret_key} = Signing.new(secret_key: <<1>>, link_id: @link_id)
      assert {:error, :missing_link_id} = Signing.new(secret_key: @secret_key)
      assert {:error, :invalid_link_id} = Signing.new(secret_key: @secret_key, link_id: 256)

      assert {:error, :invalid_timestamp} =
               Signing.new(secret_key: @secret_key, link_id: @link_id, timestamp: -1)

      assert {:error, :invalid_accept_unsigned} =
               Signing.new(
                 secret_key: @secret_key,
                 link_id: @link_id,
                 accept_unsigned: :sometimes
               )

      assert {:error, :invalid_options} = Signing.new([1, 2])
      assert {:error, :invalid_options} = Signing.new(:invalid)
    end
  end

  describe "validate_inbound/2" do
    test "accepts valid signed frames and records replay state" do
      signing = signing()
      frame = signed_frame(@valid_timestamp)

      assert {:ok, ^frame, updated_signing} = Signing.validate_inbound(frame, signing)

      assert updated_signing.timestamp == @valid_timestamp

      assert updated_signing.stream_timestamps[
               {frame.source_system, frame.source_component, @link_id}
             ] == @valid_timestamp
    end

    test "rejects repeated or older timestamps for the same signed stream" do
      frame = signed_frame(@valid_timestamp)

      assert {:ok, ^frame, updated_signing} = Signing.validate_inbound(frame, signing())

      assert {:error, :signature_replay, ^updated_signing} =
               Signing.validate_inbound(signed_frame(@valid_timestamp), updated_signing)

      assert {:error, :signature_replay, ^updated_signing} =
               Signing.validate_inbound(signed_frame(@valid_timestamp - 1), updated_signing)

      assert {:ok, _frame, newer_signing} =
               Signing.validate_inbound(signed_frame(@valid_timestamp + 1), updated_signing)

      assert newer_signing.stream_timestamps[{1, 1, @link_id}] == @valid_timestamp + 1
    end

    test "rejects first-seen signed frames more than one minute behind local signing time" do
      signing = signing()

      assert {:error, :signature_too_old, ^signing} =
               Signing.validate_inbound(signed_frame(@local_timestamp - 6_000_001), signing)

      assert {:ok, _frame, _updated_signing} =
               Signing.validate_inbound(signed_frame(@local_timestamp - 6_000_000), signing)
    end

    test "rejects invalid signatures without updating replay state" do
      signing = signing()

      assert {:error, :signature_invalid, ^signing} =
               Signing.validate_inbound(
                 signed_frame(@valid_timestamp, @wrong_secret_key),
                 signing
               )
    end

    test "rejects unsigned frames unless policy explicitly accepts them" do
      unsigned_frame = unsigned_frame()
      signing = signing()

      assert {:error, :unsigned_frame_rejected, ^signing} =
               Signing.validate_inbound(unsigned_frame, signing)

      {:ok, permissive_signing} =
        Signing.new(
          secret_key: @secret_key,
          link_id: @link_id,
          timestamp: @local_timestamp,
          accept_unsigned: true
        )

      assert {:ok, ^unsigned_frame, ^permissive_signing} =
               Signing.validate_inbound(unsigned_frame, permissive_signing)
    end

    test "keeps MAVLink 1 frames accepted when signing policy is enabled" do
      frame =
        Frame.pack_frame(%Frame{
          version: 1,
          sequence_number: 7,
          source_system: 1,
          source_component: 1,
          message_id: 24,
          payload: <<1, 2, 3>>,
          crc_extra: 0
        })

      signing = signing()

      assert {:ok, ^frame, ^signing} = Signing.validate_inbound(frame, signing)
    end

    test "disabled policy keeps unsigned frames accepted and signed frames unsupported" do
      unsigned_frame = unsigned_frame()
      signed_frame = signed_frame(@valid_timestamp)

      assert {:ok, ^unsigned_frame, nil} = Signing.validate_inbound(unsigned_frame, nil)

      assert {:error, :signed_frame_unsupported, nil} =
               Signing.validate_inbound(signed_frame, nil)
    end
  end

  defp signing do
    {:ok, signing} =
      Signing.new(
        secret_key: @secret_key,
        link_id: @link_id,
        timestamp: @local_timestamp
      )

    signing
  end

  defp signed_frame(timestamp, secret_key \\ @secret_key) do
    {:ok, frame} = Frame.sign_frame(unsigned_frame(), secret_key, @link_id, timestamp)
    frame
  end

  defp unsigned_frame do
    Frame.pack_frame(%Frame{
      version: 2,
      sequence_number: 7,
      source_system: 1,
      source_component: 1,
      message_id: 24,
      payload: <<1, 2, 3>>,
      crc_extra: 0
    })
  end
end
