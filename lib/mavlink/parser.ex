defmodule XMAVLink.Parser do
  @moduledoc """
  Parse a mavlink xml file into an idiomatic Elixir representation:

  %{
      version: 2,
      dialect: 0,
      enums: [
        %{
          name: :mav_autopilot,
          description: "Micro air vehicle...",
          entries: [
            %{
              value: 0,
              name: :mav_autopilot_generic,         (use atoms for identifiers)
              description: "Generic autopilot..."
              params: [                             (only used by commands)
                %{
                    index: 0,
                    description: ""
                 },
                 ... more entry params
              ]
             },
             ... more enum entries
          ]
         },
        ... more enums
      ],
      messages: [
        %{
          id: 0,
          name: "optical_flow",
          description: "Optical flow...",
          fields: [
            %{
                type: "uint16_t",
                ordinality: 1,
                name: "flow_x",
                units: "dpixels",                   (note: string not atom)
                description: "Flow in pixels..."
             },
             ... more message fields
          ]
         },
        ... more messages
      ]
   }
  """

  import Enum, only: [empty?: 1, reduce: 3, reverse: 1, map: 2, sort_by: 2, into: 3, filter: 2]
  import Record, only: [defrecord: 2, extract: 2]
  import Regex, only: [replace: 3]
  import String, only: [to_integer: 1, downcase: 1, to_atom: 1, split: 3]

  @identifier_regex ~r/\A[A-Za-z][A-Za-z0-9_]*\z/
  @unit_regex ~r/\A[A-Za-z0-9_%@\/\*\^\.\-]+\z/
  @scalar_field_types ~w(char uint8_t int8_t uint16_t int16_t uint32_t int32_t uint64_t int64_t float double)
  @valid_display_values ~w(bitmask)
  @default_limits %{
    max_xml_file_bytes: 2_000_000,
    max_include_depth: 32,
    max_include_files: 128
  }

  @xmerl_header "xmerl/include/xmerl.hrl"
  defrecord :xmlElement, extract(:xmlElement, from_lib: @xmerl_header)
  defrecord :xmlAttribute, extract(:xmlAttribute, from_lib: @xmerl_header)
  defrecord :xmlText, extract(:xmlText, from_lib: @xmerl_header)

  @type mavlink_definition :: %{
          version: String.t(),
          dialect: String.t(),
          enums: [enum_description],
          messages: [message_description]
        }

  @type parser_limit :: pos_integer | :infinity
  @type parse_option ::
          {:max_xml_file_bytes, parser_limit}
          | {:max_include_depth, parser_limit}
          | {:max_include_files, parser_limit}
  @type parse_options :: [parse_option]

  @spec parse_mavlink_xml(String.t()) ::
          mavlink_definition | {:error, String.t()}
  def parse_mavlink_xml(path) do
    parse_mavlink_xml(path, [])
  end

  @spec parse_mavlink_xml(String.t(), parse_options) ::
          mavlink_definition | {:error, String.t()}
  def parse_mavlink_xml(path, opts) when is_list(opts) do
    with {:ok, limits} <- parse_limits(opts) do
      path
      |> parse_mavlink_xml_file(initial_acc(limits))
      |> combined_definition()
    end
  end

  @doc false
  def parse_mavlink_xml(path, paths) when is_map(paths) do
    acc =
      if Map.has_key?(paths, :seen) and Map.has_key?(paths, :definitions) do
        normalize_acc(paths)
      else
        normalize_acc(%{
          seen: MapSet.new(Map.keys(paths)),
          definitions: Map.values(paths)
        })
      end

    parse_mavlink_xml_file(path, acc)
  end

  defp combined_definition({:error, _message} = error), do: error

  defp combined_definition(%{definitions: definitions}) do
    definitions
    |> reverse()
    |> combine_definitions()
    |> validate_definition()
  end

  defp initial_acc(limits) do
    %{
      seen: MapSet.new(),
      definitions: [],
      stack: [],
      file_count: 0,
      limits: limits
    }
  end

  defp normalize_acc(acc) do
    seen =
      acc
      |> Map.get(:seen, MapSet.new())
      |> MapSet.to_list()
      |> map(&Path.expand/1)
      |> MapSet.new()

    Map.merge(acc, %{
      seen: seen,
      definitions: Map.get(acc, :definitions, []),
      stack: Map.get(acc, :stack, []),
      file_count: Map.get(acc, :file_count, 0),
      limits: Map.get(acc, :limits, @default_limits)
    })
  end

  defp parse_limits(opts) do
    reduce(opts, {:ok, @default_limits}, fn
      _option, {:error, _message} = error ->
        error

      {key, value}, {:ok, limits} when is_map_key(@default_limits, key) ->
        if valid_limit?(value) do
          {:ok, Map.put(limits, key, value)}
        else
          {:error, "Invalid MAVLink XML parser limit #{inspect(key)}: #{inspect(value)}"}
        end

      option, {:ok, _limits} ->
        {:error, "Invalid MAVLink XML parser option #{inspect(option)}"}
    end)
  end

  defp valid_limit?(:infinity), do: true
  defp valid_limit?(value), do: is_integer(value) and value > 0

  defp parse_mavlink_xml_file(path, acc) do
    path_key = Path.expand(path)

    cond do
      path_key in acc.stack ->
        {:error,
         "Cyclic MAVLink XML include detected: #{format_path_chain(acc.stack ++ [path_key])}"}

      MapSet.member?(acc.seen, path_key) ->
        # Don't include a file twice
        acc

      exceeds_limit?(length(acc.stack) + 1, acc.limits.max_include_depth) ->
        {:error,
         "MAVLink XML include depth for '#{path_key}' exceeds max_include_depth limit of #{format_limit(acc.limits.max_include_depth)} in #{format_path_chain(acc.stack ++ [path_key])}"}

      exceeds_limit?(acc.file_count + 1, acc.limits.max_include_files) ->
        {:error,
         "MAVLink XML include graph exceeds max_include_files limit of #{format_limit(acc.limits.max_include_files)} while parsing '#{path_key}'"}

      true ->
        parse_new_mavlink_xml_file(path, path_key, acc)
    end
  end

  defp parse_new_mavlink_xml_file(path, path_key, acc) do
    parent_stack = acc.stack

    acc = %{
      acc
      | seen: MapSet.put(acc.seen, path_key),
        stack: parent_stack ++ [path_key],
        file_count: acc.file_count + 1
    }

    case scan_file(path, acc.limits) do
      {defs, []} ->
        with {:ok, acc} <- parse_includes(defs, path_key, acc),
             {:ok, definition} <- parse_definition(defs) do
          %{acc | definitions: [definition | acc.definitions], stack: parent_stack}
        end

      {:error, :enoent} ->
        {:error, "File '#{path}' does not exist"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, message} ->
        {:error, "Failed to parse MAVLink XML file '#{path}': #{inspect(message)}"}
    end
  end

  defp parse_includes(defs, path, acc) do
    with {:ok, includes} <- include_paths(defs, path),
         :ok <- validate_include_conflicts(includes, path) do
      reduce(includes, {:ok, acc}, fn
        _include, {:error, _message} = error ->
          error

        {_include, include_path}, {:ok, acc} ->
          case parse_mavlink_xml_file(include_path, acc) do
            {:error, _message} = error -> error
            acc -> {:ok, acc}
          end
      end)
    end
  end

  defp include_paths(defs, path) do
    :xmerl_xpath.string(~c"/mavlink/include/text()", defs)
    |> map(&extract_text/1)
    |> reduce({:ok, []}, fn
      _include, {:error, _message} = error ->
        error

      include, {:ok, _acc} when include in [nil, ""] ->
        {:error, "Empty MAVLink XML include in '#{path}'"}

      include, {:ok, acc} ->
        {:ok, [{include, Path.expand(include, Path.dirname(path))} | acc]}
    end)
    |> case do
      {:ok, includes} -> {:ok, reverse(includes)}
      {:error, _message} = error -> error
    end
  end

  defp validate_include_conflicts(includes, path) do
    includes
    |> Enum.group_by(fn {_include, include_path} -> include_path end, fn {include, _path} ->
      include
    end)
    |> Enum.find(fn {_include_path, include_names} ->
      include_names
      |> MapSet.new()
      |> MapSet.size()
      |> Kernel.>(1)
    end)
    |> case do
      nil ->
        :ok

      {include_path, include_names} ->
        names =
          include_names
          |> Enum.uniq()
          |> map(&inspect/1)
          |> Enum.join(", ")

        {:error,
         "Conflicting MAVLink XML includes in '#{path}' resolve to '#{include_path}': #{names}"}
    end
  end

  defp parse_definition(defs) do
    with {:ok, enums} <-
           parse_elements(:xmerl_xpath.string(~c"/mavlink/enums/enum", defs), &parse_enum/1) do
      version =
        :xmerl_xpath.string(~c"/mavlink/version/text()", defs)
        |> extract_text
        |> nil_to_zero_string

      case parse_elements(
             :xmerl_xpath.string(~c"/mavlink/messages/message", defs),
             &parse_message(&1, version)
           ) do
        {:ok, messages} ->
          {:ok,
           %{
             version: version,
             dialect:
               :xmerl_xpath.string(~c"/mavlink/dialect/text()", defs)
               |> extract_text
               |> nil_to_zero_string,
             enums: enums,
             messages: messages
           }}

        {:error, _message} = error ->
          error
      end
    end
  end

  defp scan_file(path, limits) do
    with :ok <- validate_file_size(path, limits) do
      try do
        :xmerl_scan.file(path)
      catch
        kind, reason ->
          {:error, "Failed to parse MAVLink XML file '#{path}': #{inspect({kind, reason})}"}
      end
    end
  end

  defp validate_file_size(path, limits) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} ->
        if exceeds_limit?(size, limits.max_xml_file_bytes) do
          {:error,
           "MAVLink XML file '#{path}' is #{size} bytes, exceeding max_xml_file_bytes limit of #{format_limit(limits.max_xml_file_bytes)}"}
        else
          :ok
        end

      {:ok, %{type: type}} ->
        {:error, "MAVLink XML path '#{path}' is not a regular file: #{inspect(type)}"}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, "Failed to stat MAVLink XML file '#{path}': #{inspect(reason)}"}
    end
  end

  defp exceeds_limit?(_value, :infinity), do: false
  defp exceeds_limit?(value, limit), do: value > limit

  defp format_limit(limit) do
    case limit do
      :infinity -> "infinity"
      limit -> Integer.to_string(limit)
    end
  end

  defp format_path_chain(paths) do
    paths
    |> map(&Path.basename/1)
    |> Enum.join(" -> ")
  end

  def combine_definitions([single_def]) do
    single_def
  end

  def combine_definitions([
        %{
          version: v1,
          dialect: d1,
          enums: e1,
          messages: m1
        },
        %{
          version: v2,
          dialect: d2,
          enums: e2,
          messages: m2
        }
        | more_definitions
      ]) do
    combine_definitions([
      %{
        # strings > nil
        version: max(v1, v2),
        dialect: max(d1, d2),
        enums: merge_enums(e1, e2),
        messages: sort_by(m1 ++ m2, & &1.id)
      }
      | more_definitions
    ])
  end

  def merge_enums(as, bs) do
    a_index = into(as, %{}, fn enum -> {enum.name, enum} end)
    b_index = into(bs, %{}, fn enum -> {enum.name, enum} end)

    only_in_a =
      for name <- filter(Map.keys(a_index), &(!Map.has_key?(b_index, &1))), do: a_index[name]

    only_in_b =
      for name <- filter(Map.keys(b_index), &(!Map.has_key?(a_index, &1))), do: b_index[name]

    in_a_and_b =
      for name <- filter(Map.keys(a_index), &Map.has_key?(b_index, &1)) do
        %{
          a_index[name]
          | description:
              preferred_description(a_index[name].description, b_index[name].description),
            bitmask: a_index[name].bitmask or b_index[name].bitmask,
            entries: sort_by(a_index[name].entries ++ b_index[name].entries, & &1.value)
        }
      end

    sort_by(only_in_a ++ in_a_and_b ++ only_in_b, & &1.name)
  end

  @type enum_description :: %{
          name: atom,
          bitmask: boolean,
          description: String.t(),
          entries: [entry_description]
        }

  @spec parse_enum(tuple) :: {:ok, enum_description} | {:error, String.t()}
  defp parse_enum(element) do
    raw_name = :xmerl_xpath.string(~c"@name", element) |> extract_text

    with {:ok, enum_name} <- required_identifier(raw_name, "enum name", "enum"),
         {:ok, entries} <-
           parse_elements(
             :xmerl_xpath.string(~c"/enum/entry", element),
             &parse_entry(&1, enum_name)
           ) do
      {:ok,
       %{
         name: enum_name |> downcase |> to_atom,
         bitmask: :xmerl_xpath.string(~c"@bitmask", element) |> extract_text |> true_string?,
         description:
           :xmerl_xpath.string(~c"/enum/description/text()", element)
           |> extract_text
           |> nil_to_empty_string,
         entries: entries
       }}
    end
  end

  @type entry_description :: %{
          value: integer | nil,
          name: atom,
          description: String.t(),
          params: [param_description]
        }

  @spec parse_entry(tuple, String.t()) :: {:ok, entry_description} | {:error, String.t()}
  defp parse_entry(element, enum_name) do
    # Apparently optional in common.xml?
    value_attr = :xmerl_xpath.string(~c"@value", element)
    raw_name = :xmerl_xpath.string(~c"@name", element) |> extract_text
    context = "enum #{enum_name}"

    with {:ok, entry_name} <- required_identifier(raw_name, "enum entry name", context),
         {:ok, value} <-
           optional_integer(value_attr, "enum entry value", "#{context} entry #{entry_name}"),
         {:ok, params} <-
           parse_elements(
             :xmerl_xpath.string(~c"/entry/param", element),
             &parse_param(&1, entry_name)
           ) do
      {:ok,
       %{
         value: value,
         name: entry_name |> downcase |> to_atom,
         description:
           :xmerl_xpath.string(~c"/entry/description/text()", element)
           |> extract_text
           |> nil_to_empty_string,
         params: params
       }}
    end
  end

  @type param_description :: %{
          index: integer,
          description: String.t()
        }

  @spec parse_param(tuple, String.t()) :: {:ok, param_description} | {:error, String.t()}
  defp parse_param(element, entry_name) do
    with {:ok, index} <-
           required_integer(
             :xmerl_xpath.string(~c"@index", element) |> extract_text,
             "param index",
             "entry #{entry_name}"
           ) do
      {:ok,
       %{
         index: index,
         description:
           :xmerl_xpath.string(~c"/param/text()", element)
           |> extract_text
           |> nil_to_empty_string
       }}
    end
  end

  @type message_description :: %{
          id: integer,
          name: String.t(),
          description: String.t(),
          has_ext_fields: boolean,
          fields: [field_description]
        }

  @spec parse_message(tuple, String.t()) :: {:ok, message_description} | {:error, String.t()}
  defp parse_message(element, version) do
    raw_name = :xmerl_xpath.string(~c"@name", element) |> extract_text

    with {:ok, message_id} <-
           required_integer(
             :xmerl_xpath.string(~c"@id", element) |> extract_text,
             "message id",
             "message"
           ),
         {:ok, message_name} <-
           required_identifier(raw_name, "message name", "message id #{message_id}") do
      message_description =
        reduce(
          xmlElement(element, :content),
          %{
            id: message_id,
            name: message_name,
            description:
              :xmerl_xpath.string(~c"/message/description/text()", element)
              |> extract_text
              |> nil_to_empty_string,
            has_ext_fields: false,
            fields: []
          },
          fn
            _next_child, {:error, _message} = error ->
              error

            next_child, acc ->
              case xmlElement(next_child, :name) do
                :field ->
                  case parse_field(next_child, version, acc.has_ext_fields, message_name) do
                    {:ok, field} -> %{acc | fields: [field | acc.fields]}
                    {:error, _message} = error -> error
                  end

                :extensions ->
                  %{acc | has_ext_fields: true}

                _ ->
                  acc
              end
          end
        )

      case message_description do
        {:error, _message} = error ->
          error

        message_description ->
          {:ok, %{message_description | fields: reverse(message_description.fields)}}
      end
    end
  end

  @type field_description :: %{
          type: String.t(),
          ordinality: integer,
          omit_arg: boolean,
          is_extension: boolean,
          constant_val: String.t() | nil,
          name: String.t(),
          enum: String.t(),
          display: :bitmask | nil,
          print_format: String.t() | nil,
          units: atom | nil,
          description: String.t()
        }

  @spec parse_field(tuple, binary(), boolean, String.t()) ::
          {:ok, field_description} | {:error, String.t()}
  defp parse_field(element, version, is_extension_field, message_name) do
    context = "message #{message_name}"

    with {:ok, {type, ordinality, omit_arg, constant_val}} <-
           :xmerl_xpath.string(~c"@type", element)
           |> extract_text
           |> parse_type_ordinality_omit_arg_constant_val(version, context),
         {:ok, field_name} <-
           :xmerl_xpath.string(~c"@name", element)
           |> extract_text
           |> required_identifier("field name", context),
         {:ok, enum} <-
           :xmerl_xpath.string(~c"@enum", element)
           |> extract_text
           |> optional_identifier("field enum", "#{context} field #{field_name}"),
         {:ok, display} <-
           :xmerl_xpath.string(~c"@display", element)
           |> extract_text
           |> optional_display("#{context} field #{field_name}"),
         {:ok, units} <-
           :xmerl_xpath.string(~c"@units", element)
           |> extract_text
           |> optional_unit("#{context} field #{field_name}") do
      {:ok,
       %{
         type: type,
         ordinality: ordinality,
         omit_arg: omit_arg,
         is_extension: is_extension_field,
         constant_val: constant_val,
         # You can't downcase this, wrecks crc_extra calc for POWER_STATUS
         name: field_name,
         enum: enum |> nil_to_empty_string |> downcase,
         display: display,
         print_format: :xmerl_xpath.string(~c"@print_format", element) |> extract_text,
         units: units,
         description:
           :xmerl_xpath.string(~c"/field/text()", element) |> extract_text |> nil_to_empty_string
       }}
    end
  end

  @spec parse_type_ordinality_omit_arg_constant_val(String.t(), String.t(), String.t()) ::
          {:ok, {String.t(), integer, boolean, String.t() | nil}} | {:error, String.t()}
  defp parse_type_ordinality_omit_arg_constant_val(nil, _version, context) do
    {:error, "Missing field type in #{context}"}
  end

  defp parse_type_ordinality_omit_arg_constant_val(type_string, version, context) do
    [type | ordinality] =
      type_string
      |> split(["[", "]"], trim: true)

    case type do
      "uint8_t_mavlink_version" ->
        {:ok, {"uint8_t", 1, true, version}}

      type when type in @scalar_field_types ->
        with {:ok, ordinality} <- parse_ordinality(ordinality, context) do
          {:ok, {type, ordinality, false, nil}}
        end

      _ ->
        {:error, "Invalid field type #{inspect(type_string)} in #{context}"}
    end
  end

  defp parse_ordinality([], _context), do: {:ok, 1}

  defp parse_ordinality([raw_ordinality], context) do
    case required_integer(raw_ordinality, "field array length", context) do
      {:ok, ordinality} when ordinality > 0 ->
        {:ok, ordinality}

      {:ok, _ordinality} ->
        {:error, "Invalid field array length #{inspect(raw_ordinality)} in #{context}"}

      {:error, _message} = error ->
        error
    end
  end

  defp parse_ordinality(_ordinality, context),
    do: {:error, "Invalid field type array declaration in #{context}"}

  defp parse_elements(elements, parser) do
    elements
    |> reduce({:ok, []}, fn
      _element, {:error, _message} = error ->
        error

      element, {:ok, acc} ->
        case parser.(element) do
          {:ok, parsed} -> {:ok, [parsed | acc]}
          {:error, _message} = error -> error
        end
    end)
    |> case do
      {:ok, parsed} -> {:ok, reverse(parsed)}
      {:error, _message} = error -> error
    end
  end

  defp validate_definition(definition) do
    with :ok <- validate_unique_message_ids(definition.messages),
         :ok <- validate_unique_message_modules(definition.messages),
         :ok <- validate_unique_enums(definition.enums),
         :ok <- validate_enum_entries(definition.enums),
         :ok <- validate_message_fields(definition.messages) do
      definition
    end
  end

  defp validate_unique_message_ids(messages) do
    case duplicate_by(messages, & &1.id) do
      nil ->
        :ok

      {id, duplicate_messages} ->
        names = duplicate_messages |> map(& &1.name) |> Enum.join(", ")
        {:error, "Duplicate message id #{id} for #{names}"}
    end
  end

  defp validate_unique_message_modules(messages) do
    case duplicate_by(messages, &generated_message_module_name(&1.name)) do
      nil ->
        :ok

      {module_name, duplicate_messages} ->
        names = duplicate_messages |> map(& &1.name) |> Enum.join(", ")
        {:error, "Duplicate generated message module #{module_name} for #{names}"}
    end
  end

  defp validate_unique_enums(enums) do
    case duplicate_by(enums, & &1.name) do
      nil ->
        :ok

      {name, _duplicate_enums} ->
        {:error, "Duplicate enum #{inspect(name)}"}
    end
  end

  defp validate_enum_entries(enums) do
    reduce(enums, :ok, fn
      _enum, {:error, _message} = error ->
        error

      enum, :ok ->
        with :ok <- validate_unique_enum_entry_names(enum),
             :ok <- validate_unique_enum_entry_values(enum) do
          :ok
        end
    end)
  end

  defp validate_unique_enum_entry_names(enum) do
    case duplicate_by(enum.entries, & &1.name) do
      nil ->
        :ok

      {name, _duplicate_entries} ->
        {:error, "Duplicate enum entry #{inspect(name)} in enum #{inspect(enum.name)}"}
    end
  end

  defp validate_unique_enum_entry_values(enum) do
    resolved_entries = resolve_enum_entry_values(enum.entries)

    case duplicate_by(resolved_entries, & &1.value) do
      nil ->
        :ok

      {value, duplicate_entries} ->
        names = duplicate_entries |> map(&inspect(&1.name)) |> Enum.join(", ")
        {:error, "Duplicate enum value #{value} in enum #{inspect(enum.name)} for #{names}"}
    end
  end

  defp validate_message_fields(messages) do
    reduce(messages, :ok, fn
      _message, {:error, _reason} = error ->
        error

      message, :ok ->
        case duplicate_by(message.fields, &(&1.name |> downcase)) do
          nil ->
            :ok

          {name, _duplicate_fields} ->
            {:error, "Duplicate field #{inspect(name)} in message #{message.name}"}
        end
    end)
  end

  defp resolve_enum_entry_values(entries) do
    entries
    |> Enum.map_reduce(0, fn entry, next_value ->
      value = entry.value || next_value
      {%{entry | value: value}, value + 1}
    end)
    |> elem(0)
  end

  defp duplicate_by(values, fun) do
    values
    |> Enum.group_by(fun)
    |> Enum.find(fn {_key, grouped_values} -> length(grouped_values) > 1 end)
  end

  defp preferred_description(_a, b) when b not in [nil, ""], do: b
  defp preferred_description(a, _b), do: a

  defp generated_message_module_name(message_name) do
    message_name
    |> String.split("_")
    |> map(&String.capitalize/1)
    |> Enum.join("")
  end

  defp required_identifier(nil, kind, context), do: {:error, "Missing #{kind} in #{context}"}
  defp required_identifier("", kind, context), do: {:error, "Missing #{kind} in #{context}"}

  defp required_identifier(value, kind, context) when is_binary(value) do
    if Regex.match?(@identifier_regex, value) do
      {:ok, value}
    else
      {:error, "Invalid #{kind} #{inspect(value)} in #{context}"}
    end
  end

  defp optional_identifier(nil, _kind, _context), do: {:ok, nil}
  defp optional_identifier("", _kind, _context), do: {:ok, nil}
  defp optional_identifier(value, kind, context), do: required_identifier(value, kind, context)

  defp optional_display(nil, _context), do: {:ok, nil}
  defp optional_display("", _context), do: {:ok, nil}

  defp optional_display(value, _context) when value in @valid_display_values do
    {:ok, to_atom(value)}
  end

  defp optional_display(value, context),
    do: {:error, "Invalid field display #{inspect(value)} in #{context}"}

  defp optional_unit(nil, _context), do: {:ok, nil}
  defp optional_unit("", _context), do: {:ok, nil}

  defp optional_unit(value, context) do
    if Regex.match?(@unit_regex, value) do
      {:ok, to_atom(value)}
    else
      {:error, "Invalid field unit #{inspect(value)} in #{context}"}
    end
  end

  defp optional_integer([], _kind, _context), do: {:ok, nil}

  defp optional_integer(value_attr, kind, context) do
    if empty?(value_attr) do
      {:ok, nil}
    else
      value_attr
      |> extract_text
      |> required_integer(kind, context)
    end
  end

  defp required_integer(nil, kind, context), do: {:error, "Missing #{kind} in #{context}"}
  defp required_integer("", kind, context), do: {:error, "Missing #{kind} in #{context}"}

  defp required_integer(value, kind, context) when is_binary(value) do
    {:ok, to_integer(value)}
  rescue
    ArgumentError -> {:error, "Invalid #{kind} #{inspect(value)} in #{context}"}
  end

  # TODO Can't spec this without causing dialyzer "nil can't match binary" - Erlang types?
  defp extract_text([xml]), do: extract_text(xml)
  defp extract_text(xmlText(value: value)), do: clean_string(value)
  defp extract_text(xmlAttribute(value: value)), do: clean_string(value)
  defp extract_text(_), do: nil

  @spec clean_string([char] | binary) :: String.t()
  defp clean_string(s) do
    trimmed = s |> List.to_string() |> String.trim()
    replace(~r/\s+/, trimmed, " ")
  end

  @spec nil_to_empty_string(String.t() | nil) :: String.t()
  defp nil_to_empty_string(nil), do: ""
  defp nil_to_empty_string(value) when is_binary(value), do: value

  @spec nil_to_zero_string(String.t() | nil) :: String.t()
  defp nil_to_zero_string(nil), do: "0"
  defp nil_to_zero_string(value) when is_binary(value), do: value

  defp true_string?("true"), do: true
  defp true_string?(_), do: false
end
