defmodule LiveSidestep.Node do
  @moduledoc """
  A declaration in the closed native vocabulary, never an HTML element.

  Supported kinds are `column`, `row`, `list`, `text`, `button`, and `input`.
  Attribute names may be atoms or strings in constructors and are normalized to
  strings without creating atoms. Containers accept native nodes; text and
  buttons accept string content, which is joined and trimmed. Use the `text`
  property to preserve surrounding whitespace.

  IDs are global within a tree. An omitted ID receives a parent-scoped static
  identity when flattened. Repeated nodes must instead use application keys.
  Interactive identity includes `incarnation` (defaulting to zero in the host);
  increment it when replacing a removed control under the same ID.

  Constructors validate their inputs. `LiveSidestep.Tree.flatten/1` also
  revalidates manually constructed structs before they cross the native boundary.
  """

  @enforce_keys [:kind]
  defstruct [:id, :kind, props: %{}, children: []]

  @type scalar :: String.t() | number() | boolean() | nil
  @type props :: %{optional(String.t()) => scalar()}
  @type attributes :: map() | [{atom() | String.t(), term()}]
  @type u64 :: 0..18_446_744_073_709_551_615
  @type t :: %__MODULE__{id: String.t() | nil, kind: String.t(), props: props(), children: [t()]}

  @kinds ~w(column row list text button input)
  @containers ~w(column row list)
  @max_id_bytes 1024
  @max_text_bytes 65_536
  @max_nodes 4096
  @u64_max 18_446_744_073_709_551_615
  @i64_min -9_223_372_036_854_775_808

  @doc """
  Builds a validated native node, raising `ArgumentError` for invalid data.

  Attributes are a map or a list of name/value pairs. Duplicate names after
  normalization, unknown properties, invalid UTF-8, NUL bytes, oversized strings,
  and counters outside unsigned 64-bit range are rejected. `event` is a
  convenience option on `LiveSidestep.UI`, not a native property.

  IDs, event names, and property names are limited to 1,024 bytes. Text,
  values, placeholders, and string event parameters are limited to 65,536 bytes.
  Event names must be nonempty. Scalar event parameters accept null, booleans,
  finite floats, and exact integers in `-2^63..2^64-1`, never maps or arrays.
  """
  @spec new!(String.t(), attributes(), [t() | String.t()]) :: t()
  def new!(kind, attrs \\ %{}, children \\ []) do
    validate_kind!(kind)
    attrs = normalize_attrs!(attrs)
    {id, props} = Map.pop(attrs, "id")
    validate_id!(id)
    {props, children} = normalize_children!(kind, props, children)
    validate_properties!(kind, props)
    %__MODULE__{id: id, kind: kind, props: props, children: children}
  end

  @doc """
  Validates a canonical node's own fields without changing it.

  Leaf nodes must already have their content in properties and have no children.
  Recursive identity, depth, and count checks belong to `LiveSidestep.Tree`.
  """
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{id: id, kind: kind, props: props, children: children} = node)
      when map_size(node) == 5 do
    validate_id!(id)
    validate_properties!(kind, props)
    validate_children!(kind, children)
    node
  end

  def validate!(_), do: invalid!("expected a native node with canonical fields")

  @doc "Returns whether a property name belongs to the specified native kind."
  @spec allowed_property?(String.t(), term()) :: boolean()
  def allowed_property?(kind, key) do
    case {kind, key} do
      {kind, "gap"} when kind in @containers -> true
      {kind, "text"} when kind in ["text", "button"] -> true
      {"button", "phx-click"} -> true
      {"input", key} when key in ["value", "placeholder", "edit_revision", "phx-change"] -> true
      {kind, "incarnation"} when kind in ["button", "input"] -> true
      {kind, "phx-value-" <> suffix} when kind in ["button", "input"] -> suffix != ""
      _ -> false
    end
  end

  @doc "Checks an optional declaration ID (1–1024 UTF-8 bytes, without NUL)."
  @spec validate_id!(String.t() | nil) :: :ok
  def validate_id!(nil), do: :ok

  def validate_id!(id) do
    unless valid_string?(id, 1, @max_id_bytes),
      do: invalid!("node id must contain 1..#{@max_id_bytes} UTF-8 bytes without NUL")

    :ok
  end

  @doc false
  @spec validate_text!(term()) :: :ok
  def validate_text!(text) do
    unless valid_string?(text, 0, @max_text_bytes),
      do: invalid!("native text must contain at most #{@max_text_bytes} UTF-8 bytes without NUL")

    :ok
  end

  @doc false
  @spec normalize_attrs!(attributes()) :: map()
  def normalize_attrs!(attrs) when is_map(attrs) and not is_struct(attrs),
    do: Enum.reduce(attrs, %{}, &normalize_attribute!/2)

  def normalize_attrs!(attrs) when is_list(attrs), do: normalize_pairs!(attrs, %{})
  def normalize_attrs!(_), do: invalid!("native attributes must be a map or name/value pairs")

  @doc false
  @spec validate_properties!(String.t(), props()) :: props()
  def validate_properties!(kind, props) when is_map(props) and not is_struct(props) do
    validate_kind!(kind)
    Enum.each(props, fn {key, value} -> validate_property!(kind, key, value) end)
    props
  end

  def validate_properties!(_, _), do: invalid!("native properties must be a map with string keys")

  defp normalize_pairs!([], attrs), do: attrs

  defp normalize_pairs!([pair | rest], attrs),
    do: normalize_pairs!(rest, normalize_attribute!(pair, attrs))

  defp normalize_pairs!(_, _), do: invalid!("native attributes must be name/value pairs")

  defp normalize_attribute!({key, value}, attrs) when is_atom(key),
    do: normalize_attribute!({Atom.to_string(key), value}, attrs)

  defp normalize_attribute!({key, value}, attrs) when is_binary(key) do
    if Map.has_key?(attrs, key), do: invalid!("duplicate native attribute #{inspect(key)}")
    Map.put(attrs, key, value)
  end

  defp normalize_attribute!(_, _), do: invalid!("native attribute names must be atoms or strings")

  defp normalize_children!(kind, props, children) when kind in @containers do
    validate_children!(kind, children)
    {props, children}
  end

  defp normalize_children!("input", props, []), do: {props, []}
  defp normalize_children!("input", _, _), do: invalid!("input cannot have children")

  defp normalize_children!(_kind, props, children) do
    text = content!(children, [], 0)

    props =
      case {text, Map.has_key?(props, "text")} do
        {"", _} -> props
        {_, true} -> invalid!("text must be supplied as either content or a property")
        _ -> Map.put(props, "text", text)
      end

    {props, []}
  end

  defp content!([], parts, _bytes),
    do: parts |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()

  defp content!([part | rest], parts, bytes) when is_binary(part) do
    validate_text!(part)
    bytes = bytes + byte_size(part)
    if bytes > @max_text_bytes, do: invalid!("native text exceeds #{@max_text_bytes} bytes")
    content!(rest, [part | parts], bytes)
  end

  defp content!(_, _, _), do: invalid!("text and button content must be a list of strings")

  defp validate_children!(kind, children) when kind in @containers,
    do: validate_node_children!(children, 0)

  defp validate_children!(_kind, []), do: :ok
  defp validate_children!(kind, _), do: invalid!("#{kind} cannot have child nodes")

  defp validate_node_children!([], _count), do: :ok

  defp validate_node_children!([%__MODULE__{} | rest], count) when count < @max_nodes,
    do: validate_node_children!(rest, count + 1)

  defp validate_node_children!(_, _),
    do: invalid!("native containers require a bounded list of native child nodes")

  defp validate_kind!(kind) do
    unless kind in @kinds, do: invalid!("unsupported native kind #{inspect(kind)}")
    :ok
  end

  defp validate_property!(kind, key, value) do
    unless valid_string?(key, 1, @max_id_bytes) and allowed_property?(kind, key),
      do: invalid!("unsupported #{kind} property #{inspect(key)}")

    unless valid_property_value?(key, value),
      do: invalid!("invalid #{kind} property #{inspect(key)}: #{inspect(value)}")
  end

  defp valid_property_value?("gap", value), do: is_integer(value) and value in 0..128

  defp valid_property_value?(key, value) when key in ["edit_revision", "incarnation"],
    do: is_integer(value) and value >= 0 and value <= @u64_max

  defp valid_property_value?(key, value) when key in ["phx-click", "phx-change"],
    do: valid_string?(value, 1, @max_id_bytes)

  defp valid_property_value?("phx-value-" <> _, value) when is_integer(value),
    do: value >= @i64_min and value <= @u64_max

  # BEAM floats cannot represent NaN or infinity.
  defp valid_property_value?("phx-value-" <> _, value)
       when is_float(value) or is_boolean(value) or is_nil(value),
       do: true

  defp valid_property_value?(_key, value), do: valid_string?(value, 0, @max_text_bytes)

  defp valid_string?(value, min_bytes, max_bytes) do
    is_binary(value) and byte_size(value) >= min_bytes and byte_size(value) <= max_bytes and
      String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp invalid!(message), do: raise(ArgumentError, message)
end
