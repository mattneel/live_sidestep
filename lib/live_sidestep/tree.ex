defmodule LiveSidestep.Tree do
  @moduledoc """
  Validated stable-ID trees and deterministic native snapshot/patch commands.

  `flatten/1` returns the compact wire shape:

      %{"root" => id, "nodes" => %{id => %{
        "id" => id, "kind" => kind, "props" => properties, "children" => child_ids
      }}}

  Explicit IDs are global. Static fallback IDs use `parent_id/index`, so static
  descendants of a keyed parent keep their identity when that parent moves.
  Every tree is bounded to 4,096 nodes and 64 levels, counting the root as level
  one. These checks apply to manually built structs and flattened maps as well
  as constructor/template output.

  Commands are maps, not encoded frames. The session additionally preflights
  the complete JSON frame against the protocol's 1 MiB limit before committing
  a rendered checkpoint.
  """

  alias LiveSidestep.Node

  @max_nodes 4096
  @max_depth 64
  @u64_max 18_446_744_073_709_551_615
  @containers ~w(column row list)

  @type flat_node :: %{String.t() => String.t() | Node.props() | [String.t()]}
  @type t :: %{String.t() => String.t() | %{String.t() => flat_node()}}
  @type command :: %{String.t() => term()}

  @doc """
  Flattens one native root, fully revalidating every node.

  Raises `ArgumentError` for invalid properties, malformed children, duplicate
  IDs (including collisions with generated IDs), or excessive depth/count.
  """
  @spec flatten(Node.t()) :: t()
  def flatten(%Node{} = root) do
    {id, nodes} = flatten_node(root, "root", %{}, 1)
    %{"root" => id, "nodes" => nodes}
  end

  def flatten(_), do: invalid!("native render must return exactly one native node")

  @doc """
  Validates an already flattened tree and returns it unchanged.

  Schema, property values, IDs, bounds, and topology are all checked. A valid
  tree has exactly one root, no cycles or multiple parents, no missing children,
  and no unreachable nodes. Unknown wire fields are rejected.
  """
  @spec validate!(t()) :: t()
  def validate!(%{"root" => root, "nodes" => nodes} = tree)
      when map_size(tree) == 2 and is_map(nodes) and not is_struct(nodes) do
    validate_wire_id!(root)

    if map_size(nodes) == 0 or map_size(nodes) > @max_nodes,
      do: invalid!("native tree must contain 1..#{@max_nodes} nodes")

    Enum.each(nodes, fn {id, node} -> validate_flat_node!(id, node) end)
    seen = visit!([{root, 1}], nodes, %{})

    if map_size(seen) != map_size(nodes),
      do: invalid!("native tree contains unreachable nodes")

    tree
  end

  def validate!(_), do: invalid!("native tree must contain only root and nodes fields")

  @doc """
  Builds a full recovery snapshot for positive unsigned 64-bit counters.

  The supplied flattened tree is revalidated, even when it was not produced by
  `flatten/1`. No native or Elixir state is mutated.
  """
  @spec snapshot(t(), pos_integer(), pos_integer()) :: command()
  def snapshot(tree, generation, revision) do
    validate_counter!(generation, "generation", 1, @u64_max)
    validate_counter!(revision, "revision", 1, @u64_max)
    validate!(tree)
    %{"type" => "snapshot", "generation" => generation, "revision" => revision, "tree" => tree}
  end

  @doc """
  Diffs two validated flattened trees against an acknowledged base revision.

  The next revision is exactly `base_revision + 1`. Generation is a positive
  u64, and base revision is in `0..2^64-2`, so incrementing never overflows.
  Upserts and removals are sorted by ID; unchanged keyed nodes are not resent.
  Root, kind, property, child-order, and incarnation changes are all represented.
  """
  @spec patch(t(), t(), pos_integer(), Node.u64()) :: command()
  def patch(previous, next, generation, base_revision) do
    validate_counter!(generation, "generation", 1, @u64_max)
    validate_counter!(base_revision, "base revision", 0, @u64_max - 1)
    validate!(previous)
    validate!(next)

    upsert =
      next["nodes"]
      |> Enum.reject(fn {id, node} -> previous["nodes"][id] === node end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    remove =
      previous["nodes"]
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(next["nodes"], &1))
      |> Enum.sort()

    %{
      "type" => "patch",
      "generation" => generation,
      "base_revision" => base_revision,
      "revision" => base_revision + 1,
      "root" => next["root"],
      "upsert" => upsert,
      "remove" => remove
    }
  end

  defp flatten_node(_node, _fallback, nodes, depth)
       when map_size(nodes) >= @max_nodes or depth > @max_depth do
    invalid!("native tree exceeds #{@max_nodes} nodes or #{@max_depth} levels")
  end

  defp flatten_node(node, fallback, nodes, depth) do
    Node.validate!(node)
    id = node.id || fallback
    validate_wire_id!(id)
    if Map.has_key?(nodes, id), do: invalid!("duplicate native node ID: #{inspect(id)}")
    nodes = Map.put(nodes, id, nil)

    {children, nodes} =
      node.children
      |> Enum.with_index()
      |> Enum.map_reduce(nodes, fn {child, index}, acc ->
        flatten_node(child, id <> "/" <> Integer.to_string(index), acc, depth + 1)
      end)

    flat = %{"id" => id, "kind" => node.kind, "props" => node.props, "children" => children}
    {id, Map.put(nodes, id, flat)}
  end

  defp validate_flat_node!(
         id,
         %{"id" => node_id, "kind" => kind, "props" => props, "children" => children} = node
       )
       when map_size(node) == 4 do
    validate_wire_id!(id)
    if id != node_id, do: invalid!("native node map key differs from its id")
    Node.validate_properties!(kind, props)

    unless kind in @containers or children == [],
      do: invalid!("#{kind} cannot have child nodes")

    validate_child_ids!(children, 0)
  end

  defp validate_flat_node!(_, _),
    do: invalid!("native wire nodes must contain only id, kind, props, and children fields")

  defp validate_child_ids!([], _count), do: :ok

  defp validate_child_ids!([id | rest], count) when count < @max_nodes do
    validate_wire_id!(id)
    validate_child_ids!(rest, count + 1)
  end

  defp validate_child_ids!(_, _),
    do: invalid!("native children must be a bounded list of node IDs")

  @spec visit!([{String.t(), pos_integer()}], %{String.t() => flat_node()}, %{String.t() => true}) ::
          %{String.t() => true}
  defp visit!([], _nodes, seen), do: seen

  defp visit!([{id, depth} | rest], nodes, seen) do
    if depth > @max_depth, do: invalid!("native tree exceeds #{@max_depth} levels")
    if Map.has_key?(seen, id), do: invalid!("native tree contains a cycle or multiple parents")

    node =
      case Map.fetch(nodes, id) do
        {:ok, node} -> node
        :error -> invalid!("native tree references a missing root or child: #{inspect(id)}")
      end

    pending = Enum.reduce(node["children"], rest, fn child, acc -> [{child, depth + 1} | acc] end)
    visit!(pending, nodes, Map.put(seen, id, true))
  end

  defp validate_wire_id!(id) when is_binary(id), do: Node.validate_id!(id)
  defp validate_wire_id!(_), do: invalid!("native wire IDs must be nonempty strings")

  defp validate_counter!(value, name, minimum, maximum) do
    unless is_integer(value) and value >= minimum and value <= maximum,
      do: invalid!("native #{name} must be an integer in #{minimum}..#{maximum}")

    :ok
  end

  defp invalid!(message), do: raise(ArgumentError, message)
end
