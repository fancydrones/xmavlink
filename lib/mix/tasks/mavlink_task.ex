defmodule Mix.Tasks.Mavlink do # Mavlink case required for `mix mavlink ...` to work
  use Mix.Task

  
  import MAVLink.Parser
  import DateTime
  import Enum, only: [any?: 2, count: 1, join: 2, map: 2, filter: 2, reduce: 3, reverse: 1, sort: 1, into: 3]
  import String, only: [trim: 1, replace: 3, split: 2, capitalize: 1, downcase: 1]
  import MAVLink.Utils
  import Mix.Generator, only: [create_file: 3]
  import Path, only: [rootname: 1, basename: 1]
  
  use Bitwise, only_operators: true
  
  @doc """
  
  """
  @shortdoc "Generate Elixir Module from MAVLink dialect XML"
  @spec run([String.t]) :: :ok
  @impl Mix.Task
  def run([dialect_xml_path]) do
    run([dialect_xml_path, "#{dialect_xml_path |> rootname |> basename}.ex"])
  end
  
  def run([dialect_xml_path, output_ex_source_path]) do
    run([
      dialect_xml_path,
      output_ex_source_path,
      dialect_xml_path
      |> rootname
      |> basename
      |> module_case])
  end
  
  def run([dialect_xml_path, output_ex_source_path, module_name]) do
    case parse_mavlink_xml(dialect_xml_path) do
      {:error, message} ->
        IO.puts message
        
      %{version: version, dialect: dialect, enums: enums, messages: messages} ->
     
        enum_code_fragments = get_enum_code_fragments(enums, module_name)
        message_code_fragments = get_message_code_fragments(messages, enums, module_name)
        unit_code_fragments = get_unit_code_fragments(messages)
        
        true = create_file(output_ex_source_path,
        """
        defmodule #{module_name}.Types do
        
          @typedoc "A MAVLink message"
          @type message :: #{map(messages, & "#{module_name}.Message.#{&1[:name] |> module_case}") |> join(" | ")}
          
          
          @typedoc "An atom representing a MAVLink enumeration type"
          @type enum_type :: #{map(enums, & ":#{&1[:name]}") |> join(" | ")}
          
          
          @typedoc "An atom representing a MAVLink enumeration type value"
          @type enum_value :: #{map(enums, & "#{&1[:name]}") |> join(" | ")}
          
          
          @typedoc "Measurement unit of field value"
          @type field_unit :: #{unit_code_fragments |> join(~s( | )) |> trim}
          
          
          #{enum_code_fragments |> map(& &1[:type]) |> join("\n\n  ")}
        
        end
        
        
        #{message_code_fragments |> map(& &1.module) |> join("\n\n") |> trim}
        
        
        defmodule #{module_name} do
        
          import String, only: [replace_trailing: 3]
          import MAVLink.Utils, only: [unpack_array: 2, unpack_float: 1]
          
          use Bitwise, only_operators: true
        
          @moduledoc ~s(#{module_name} #{version}.#{dialect} generated by MAVLink mix task from #{dialect_xml_path} on #{utc_now()})
        
          
          @doc "MAVLink version"
          @spec mavlink_version() :: #{version}
          def mavlink_version(), do: #{version}
          
          
          @doc "MAVLink dialect"
          @spec mavlink_dialect() :: #{dialect}
          def mavlink_dialect(), do: #{dialect}
          
          
          @doc "Return a String description of a MAVLink enumeration"
          @spec describe(#{module_name}.Types.enum_type | #{module_name}.Types.enum_value) :: String.t
          #{enum_code_fragments |> map(& &1[:describe]) |> join("\n  ") |> trim}
          
          
          @doc "Return keyword list of mav_cmd parameters"
          @spec describe_params(#{module_name}.Types.mav_cmd) :: MAVLink.Types.param_description_list
          #{enum_code_fragments |> map(& &1[:describe_params]) |> join("\n  ") |> trim}
          
          
          @doc "Return encoded integer value used in a MAVLink message for an enumeration value"
          #{enum_code_fragments |> map(& &1[:encode_spec]) |> join("\n  ") |> trim}
          #{enum_code_fragments |> map(& &1[:encode]) |> join("\n  ") |> trim}
          
          
          @doc "Return the atom representation of a MAVLink enumeration value from the enumeration type and encoded integer"
          #{enum_code_fragments |> map(& &1[:decode_spec]) |> join("\n  ") |> trim}
          #{enum_code_fragments |> map(& &1[:decode]) |> join("\n  ") |> trim}
          def decode(value, _enum), do: value
          
          
          @doc "Return the message checksum and size in bytes for a message with a specified id"
          @typep target_type :: :broadcast | :system | :system_component | :component
          @spec msg_attributes(MAVLink.Types.message_id) :: {:ok, MAVLink.Types.crc_extra, pos_integer, target_type} | {:error, :unknown_message_id}
          #{message_code_fragments |> map(& &1.msg_attributes) |> join("") |> trim}
          def msg_attributes(_), do: {:error, :unknown_message_id}

        
          @doc "Helper function for messages to pack bitmask fields"
          @spec pack_bitmask(MapSet.t(#{module_name}.Types.enum_value), #{module_name}.Types.enum_type, (#{module_name}.Types.enum_value, #{module_name}.Types.enum_type -> integer)) :: integer
          def pack_bitmask(flag_set, enum, encode), do: Enum.reduce(flag_set, 0, & &2 ^^^ encode.(&1, enum))
        
        
          @doc "Helper function for decode() to unpack bitmask fields"
          @spec unpack_bitmask(integer, #{module_name}.Types.enum_type, (integer, #{module_name}.Types.enum_type -> #{module_name}.Types.enum_value), MapSet.t, integer) :: MapSet.t(#{module_name}.Types.enum_value)
          def unpack_bitmask(value, enum, decode, acc \\\\ MapSet.new(), pos \\\\ 1) do
            case {decode.(pos, enum), (value &&& pos) != 0} do
              {not_atom, _} when not is_atom(not_atom) ->
                acc
              {entry, true} ->
                unpack_bitmask(value, enum, decode, MapSet.put(acc, entry), pos <<< 1)
              {_, false} ->
                unpack_bitmask(value, enum, decode, acc, pos <<< 1)
            end
          end
        
        
          @doc "Unpack a MAVLink message given a MAVLink frame's message id and payload"
          @spec unpack(MAVLink.Types.message_id, binary) :: #{module_name}.Types.message | {:error, :unknown_message}
          #{message_code_fragments |> map(& &1.unpack) |> join("") |> trim}
          def unpack(_, _), do: {:error, :unknown_message}
          
        end
        """, [])
      
        IO.puts("Generated #{module_name} in '#{output_ex_source_path}'.")
        :ok
    
    end
    
  end
  
  
  @type enum_detail :: %{type: String.t, describe: String.t, describe_params: String.t, encode: String.t, decode: String.t}
  @spec get_enum_code_fragments([MAVLink.Parser.enum_description], String.t) :: [ enum_detail ]
  defp get_enum_code_fragments(enums, module_name) do
    for enum <- enums do
      %{
        name: name,
        description: description
      } = enum
      
      entry_code_fragments = get_entry_code_fragments(enum)
      
      %{
        type: ~s/@typedoc "#{description}"\n  / <>
          ~s/@type #{name} :: / <>
          (map(entry_code_fragments, & ":#{&1[:name]}") |> join(" | ")),
          
        describe: ~s/def describe(:#{name}), do: "#{escape(description)}"\n  / <>
          (map(entry_code_fragments, & &1[:describe])
          |> join("\n  ")),
          
        describe_params: filter(entry_code_fragments, & &1 != nil)
          |> map(& &1[:describe_params])
          |> join("\n  "),
      
        encode_spec: "@spec encode(#{module_name}.Types.#{name}, :#{name}) :: " <>
          (map(entry_code_fragments, & &1[:value])
          |> join(" | ")),
          
        encode: map(entry_code_fragments, & &1[:encode])
          |> join("\n  "),
      
        decode_spec: "@spec decode(" <>
          (map(entry_code_fragments, & &1[:value])
          |> join(" | ")) <> ", :#{name}) :: #{module_name}.Types.#{name}",
        
        decode: map(entry_code_fragments, & &1[:decode])
          |> join("\n  ")
      }
    end
  end
  
  
  @type entry_detail :: %{name: String.t, describe: String.t, describe_params: String.t, encode: String.t, decode: String.t}
  @spec get_entry_code_fragments(MAVLink.Parser.enum_description) :: [ entry_detail ]
  defp get_entry_code_fragments(enum = %{name: enum_name, entries: entries}) do
    bitmask? = looks_like_a_bitmask?(enum)
    {details, _} = reduce(
      entries,
      {[], 0},
      fn entry, {details, next_value} ->
        %{
          name: entry_name,
          description: entry_description,
          value: entry_value,
          params: entry_params
        } = entry
        
        # Use provided value or continue monotonically from last value: in common.xml MAV_STATE uses this
        {entry_value, next_value} = case entry_value do
          nil ->
            {next_value, next_value + 1}
          _ ->
            {entry_value, entry_value + 1}
        end
        entry_value_string = if bitmask?, do: "0b#{Integer.to_string(entry_value, 2)}", else: Integer.to_string(entry_value)
        {
          [
            %{
              name: entry_name,
              describe: ~s/def describe(:#{entry_name}), do: "#{escape(entry_description)}"/,
              describe_params: get_param_code_fragments(entry_name, entry_params),
              encode: ~s/def encode(:#{entry_name}, :#{enum_name}), do: #{entry_value_string}/,
              decode: ~s/def decode(#{entry_value_string}, :#{enum_name}), do: :#{entry_name}/,
              value: entry_value_string
            }
            | details
          ],
          next_value
        }

      end
    )
    reverse(details)
  end
  
  
  @spec get_param_code_fragments(String.t, [MAVLink.Parser.param_description]) :: String.t
  defp get_param_code_fragments(entry_name, entry_params) do
    cond do
      count(entry_params) == 0 ->
        nil
      true ->
        ~s/def describe_params(:#{entry_name}), do: [/ <>
        (map(entry_params, & ~s/{#{&1[:index]}, "#{&1[:description]}"}/) |> join(", ")) <>
        ~s/]/
    end
  end
  
  
  @spec get_message_code_fragments([MAVLink.Parser.message_description], [enum_detail], String.t) :: [ String.t ]
  defp get_message_code_fragments(messages, enums, module_name) do
    # Lookup used by looks_like_a_bitmask?()
    enums_by_name = into(enums, %{}, fn (enum) -> {Atom.to_string(enum.name), enum} end)

    for message <- messages do
      message_module_name = message.name |> module_case
      enforce_field_names = Enum.filter(message.fields, & !&1.is_extension) |> map(& ":" <> downcase(&1.name)) |> join(", ")
      field_names = message.fields |> map(& ":" <> downcase(&1.name)) |> join(", ")
      field_types = message.fields |> map(& downcase(&1.name) <> ": " <> field_type(&1, module_name)) |> join(", ")
      wire_order = message.fields |> wire_order
      
      target = case {any?(message.fields, & &1.name == "target_system"), any?(message.fields, & &1.name == "target_component")} do
        {false, false} ->
          :broadcast
        {true, false} ->
          :system
        {true, true} ->
          :system_component
        {false, true} ->
          :component # Does this happen?
      end
      
      # Have to append "_f" to stop clash with reserved elixir words like "end"
      [unpack_binary_pattern, unpack_binary_pattern_ext] = for field_list <- wire_order do
        field_list
        |> map(& downcase(&1.name) <> "_f::"
           <> (if &1.ordinality > 1, do: "binary-size(#{type_to_binary(&1.type).size * &1.ordinality})", else: type_to_binary(&1.type).pattern))
        |> join(",")
      end
      
      [unpack_struct_fields, unpack_struct_fields_ext] = for field_list <- wire_order do
        field_list
        |> map(& downcase(&1.name) <> ": " <> unpack_field_code_fragment(&1, enums_by_name))
        |> join(", ")
      end
      
      [pack_binary_pattern, pack_binary_pattern_ext] = for field_list <- wire_order do
        field_list
        |> map(& pack_field_code_fragment(&1, enums_by_name, module_name))
        |> join(",")
      end
  
      crc_extra = calculate_message_crc_extra(message)
      
      # Including extension fields - currently only used for MAVLink 2 payload truncation
      expected_payload_size = reduce(
        message.fields,
        0,
        fn(field, sum) -> sum + type_to_binary(field.type).size * field.ordinality end) # Before MAVLink 2 trailing 0 truncation
      
      if message.has_ext_fields do
        %{
          msg_attributes:
            """
              def msg_attributes(#{message.id}), do: {:ok, #{crc_extra}, #{expected_payload_size}, :#{target}}
            """,
          unpack:
            """
              def unpack(#{message.id}, 1, <<#{unpack_binary_pattern}>>), do: {:ok, %#{module_name}.Message.#{message_module_name}{#{unpack_struct_fields}}}
              def unpack(#{message.id}, 2, <<#{unpack_binary_pattern},#{unpack_binary_pattern_ext}>>), do: {:ok, %#{module_name}.Message.#{message_module_name}{#{unpack_struct_fields},#{unpack_struct_fields_ext}}}
            """,
          module:
            """
            defmodule #{module_name}.Message.#{message_module_name} do
              @enforce_keys [#{enforce_field_names}]
              defstruct [#{field_names}]
              @typedoc "#{escape(message.description)}"
              @type t :: %#{module_name}.Message.#{message_module_name}{#{field_types}}
              defimpl MAVLink.Message do
                def pack(msg, 1), do: {:ok, #{message.id}, #{module_name}.msg_attributes(#{message.id}), <<#{pack_binary_pattern}>>}
                def pack(msg, 2), do: {:ok, #{message.id}, #{module_name}.msg_attributes(#{message.id}), <<#{pack_binary_pattern},#{pack_binary_pattern_ext}>>}
              end
            end
            """
        }
      else
        %{
          msg_attributes:
            """
              def msg_attributes(#{message.id}), do: {:ok, #{crc_extra}, #{expected_payload_size}, :#{target}}
            """,
          unpack:
            """
              def unpack(#{message.id}, _, <<#{unpack_binary_pattern}>>), do: {:ok, %#{module_name}.Message.#{message_module_name}{#{unpack_struct_fields}}}
            """,
          module:
            """
            defmodule #{module_name}.Message.#{message_module_name} do
              @enforce_keys [#{enforce_field_names}]
              defstruct [#{field_names}]
              @typedoc "#{escape(message.description)}"
              @type t :: %#{module_name}.Message.#{message_module_name}{#{field_types}}
              defimpl MAVLink.Message do
                def pack(msg, _), do: {:ok, #{message.id}, #{module_name}.msg_attributes(#{message.id}), <<#{pack_binary_pattern}>>}
              end
            end
            """
        }
      end
    end
  end
  
  @spec calculate_message_crc_extra(MAVLink.Parser.message_description) :: MAVLink.Types.crc_extra
  defp calculate_message_crc_extra(message) do
    reduce(
      message.fields |> wire_order |> hd, # Do not include extension fields
      x25_crc(message.name <> " "),
      fn(field, crc) ->
        case field.ordinality do
          1 ->
            crc |> x25_crc(field.type <> " ") |> x25_crc(field.name <> " ")
          _ ->
            crc |> x25_crc(field.type <> " ") |> x25_crc(field.name <> " ") |> x25_crc([field.ordinality])
        end
      end
    ) |> eight_bit_checksum
  end
  
  
  # Unpack Message Fields
  defp unpack_field_code_fragment(%{name: name, ordinality: 1, enum: "", type: "float"}, _) do
    "unpack_float(#{downcase(name)}_f)"
  end
  
  defp unpack_field_code_fragment(%{name: name, ordinality: 1, enum: "", type: "double"}, _) do
    "unpack_double(#{downcase(name)}_f)"
  end
  
  defp unpack_field_code_fragment(%{name: name, ordinality: 1, enum: ""}, _) do
    downcase(name) <> "_f"
  end
  
  defp unpack_field_code_fragment(%{name: name, ordinality: 1, enum: enum, display: :bitmask}, _) when enum != "" do
    "unpack_bitmask(#{downcase(name)}_f, :#{enum}, &decode/2)"
  end
  
  defp unpack_field_code_fragment(%{name: name, ordinality: 1, enum: enum}, enums_by_name) do
    case looks_like_a_bitmask?(enums_by_name[enum]) do
      true ->
        IO.puts(~s[Warning: assuming #{enum} is a bitmask although display="bitmask" not set])
        "unpack_bitmask(#{downcase(name)}_f, :#{enum}, &decode/2)"
      false ->
        "decode(#{downcase(name)}_f, :#{enum})"
    end
  end
  
  defp unpack_field_code_fragment(%{name: name, type: "char"}, _) do
    ~s[replace_trailing(#{downcase(name)}_f, <<0>>, "")]
  end
  
  defp unpack_field_code_fragment(%{name: name, type: type}, _) do
    "unpack_array(#{downcase(name)}_f, fn(<<elem::#{type_to_binary(type).pattern},rest::binary>>) ->  {elem, rest} end)"
  end
  
  
  # Pack Message Fields
  
  defp pack_field_code_fragment(%{name: name, ordinality: 1, enum: "", type: "float"}, _, _) do
    "MAVLink.Utils.pack_float(msg.#{downcase(name)})::binary-size(4)"
  end
  
  defp pack_field_code_fragment(%{name: name, ordinality: 1, enum: "", type: "double"}, _, _) do
    "MAVLink.Utils.pack_double(msg.#{downcase(name)})::binary-size(8)"
  end
  
  defp pack_field_code_fragment(%{name: name, ordinality: 1, enum: "", type: type}, _, _) do
    "msg.#{downcase(name)}::#{type_to_binary(type).pattern}"
  end
  
  defp pack_field_code_fragment(%{name: name, ordinality: 1, enum: enum, display: :bitmask, type: type}, _, module_name) when enum != "" do
    "#{module_name}.pack_bitmask(msg.#{downcase(name)}, :#{enum}, &#{module_name}.encode/2)::#{type_to_binary(type).pattern}"
  end
  
  defp pack_field_code_fragment(%{name: name, ordinality: 1, enum: enum, type: type}, enums_by_name, module_name) do
    case looks_like_a_bitmask?(enums_by_name[enum]) do
      true ->
        "#{module_name}.pack_bitmask(msg.#{downcase(name)}, :#{enum}, &#{module_name}.encode/2)::#{type_to_binary(type).pattern}"
      false ->
        "#{module_name}.encode(msg.#{downcase(name)}, :#{enum})::#{type_to_binary(type).pattern}"
    end
  end
  
  defp pack_field_code_fragment(%{name: name, ordinality: ordinality, type: "char"}, _, _) do
    "MAVLink.Utils.pack_string(msg.#{downcase(name)}, #{ordinality})::binary-size(#{ordinality})"
  end
  
  defp pack_field_code_fragment(%{name: name, ordinality: ordinality, type: type}, _, _) do
    "MAVLink.Utils.pack_array(msg.#{downcase(name)}, #{ordinality}, fn(elem) -> <<elem::#{type_to_binary(type).pattern}>> end)::binary-size(#{type_to_binary(type).size * ordinality})"
  end
  
  
  @spec get_unit_code_fragments([MAVLink.Parser.message_description]) :: [ String.t ]
  defp get_unit_code_fragments(messages) do
    reduce(
      messages,
      MapSet.new(),
      fn message, units ->
        reduce(
          message.fields,
          units,
          fn %{units: next_unit}, units ->
            cond do
              next_unit == nil ->
                units
              Regex.match?(~r/^[a-zA-Z0-9@_]+$/, Atom.to_string(next_unit)) ->
                MapSet.put(units, ~s(:#{next_unit}))
              true ->
                MapSet.put(units, ~s(:"#{next_unit}"))
            end
            
          end
        )
      end
    ) |> MapSet.to_list |> Enum.sort
  end
  
  
  @spec module_case(String.t) :: String.t
  defp module_case(name) do
    name
    |> split("_")
    |> map(&capitalize/1)
    |> join("")
  end
  
  
  # Some bitmask fields e.g. EkfStatusReport.flags are not marked with display="bitmask". This function
  # returns true if the enum entry values start with 1, 2, 4 and then continue increasing through powers of 2.
  defp looks_like_a_bitmask?(%{entries: entries}), do: looks_like_a_bitmask?(entries |> map(& &1.value) |> sort)
  defp looks_like_a_bitmask?([1, 2, 4 | rest]), do: looks_like_a_bitmask?(rest)
  defp looks_like_a_bitmask?([8 | rest]), do: looks_like_a_bitmask?(rest |> map(& &1 >>> 1))
  defp looks_like_a_bitmask?([]), do: true
  defp looks_like_a_bitmask?(_), do: false
  
  
  # Have to deal with some overlap between MAVLink and Elixir types
  defp field_type(%{type: type, ordinality: ordinality, enum: enum}, module_name) when ordinality > 1, do: "[ #{field_type(%{type: type, ordinality: 1, enum: enum}, module_name)} ]"
  defp field_type(%{enum: enum, display: :bitmask}, module_name) when enum != "", do: "MapSet.t(#{module_name}.Types.#{enum})"
  defp field_type(%{enum: enum}, module_name) when enum != "", do: "#{module_name}.Types.#{enum}"
  defp field_type(%{type: "char"}, _), do: "char"
  defp field_type(%{type: "float"}, _), do: "Float32"
  defp field_type(%{type: "double"}, _), do: "Float64"
  defp field_type(%{type: type}, _), do: "MAVLink.Types.#{type}"
  
  
  # Map field types to a binary pattern code fragment and a size
  defp type_to_binary("char"), do: %{pattern: "integer-size(8)", size: 1}
  defp type_to_binary("uint8_t"), do: %{pattern: "integer-size(8)", size: 1}
  defp type_to_binary("int8_t"), do: %{pattern: "signed-integer-size(8)", size: 1}
  defp type_to_binary("uint16_t"), do: %{pattern: "little-integer-size(16)", size: 2}
  defp type_to_binary("int16_t"), do: %{pattern: "little-signed-integer-size(16)", size: 2}
  defp type_to_binary("uint32_t"), do: %{pattern: "little-integer-size(32)", size: 4}
  defp type_to_binary("int32_t"), do: %{pattern: "little-signed-integer-size(32)", size: 4}
  defp type_to_binary("uint64_t"), do: %{pattern: "little-integer-size(64)", size: 8}
  defp type_to_binary("int64_t"), do: %{pattern: "little-signed-integer-size(64)", size: 8}
  defp type_to_binary("float"), do: %{pattern: "binary-size(4)", size: 4} # Delegate to (un)pack_float to handle :nan
  defp type_to_binary("double"), do: %{pattern: "binary-size(8)", size: 8} # " " (un)pack_double
  
  
  @spec escape(String.t) :: String.t
  defp escape(s) do
    replace(s, ~s("), ~s(\\"))
  end
  
  
end
