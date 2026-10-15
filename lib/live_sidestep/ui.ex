defmodule LiveSidestep.UI do
  @moduledoc """
  Conventional constructors for the same native model used by `~V` templates.

      import LiveSidestep.UI

      column([
        text("Native controls"),
        input("draft", "hello", event: "edit", edit_revision: 0),
        button("save", "Save", event: "save", incarnation: 1)
      ], gap: 8)

  Options are maps or name/value pairs with atom or string names. They use the
  native properties directly; `event` is the only alias, mapping to `phx-click`
  on buttons and `phx-change` on inputs. Omit the event property for a control
  that should not dispatch callbacks. Unknown or conflicting options raise
  `ArgumentError` rather than being discarded.
  """

  alias LiveSidestep.Node

  @type options :: Node.attributes()

  @doc "A native text label. Unlike template content, surrounding whitespace is preserved."
  @spec text(String.t(), options()) :: Node.t()
  def text(content, options \\ []) do
    attrs = options |> Node.normalize_attrs!() |> put_required!("text", content)
    Node.new!("text", attrs)
  end

  @doc """
  A native button with an explicit stable ID.

  `event` aliases `phx-click`. `incarnation` is an unsigned 64-bit lifetime token
  and defaults to zero in the host when omitted. `phx-value-*` options become
  scalar callback parameters.
  """
  @spec button(String.t(), String.t(), options()) :: Node.t()
  def button(id, label, options \\ []) do
    control!("button", id, "text", label, options)
  end

  @doc """
  A native editable text field with an explicit stable ID.

  `event` aliases `phx-change`. Echo each accepted edit's `edit_revision` with its
  rendered value so an older application result cannot overwrite a newer native
  draft. Optional properties include `placeholder` and `incarnation`.
  """
  @spec input(String.t(), String.t(), options()) :: Node.t()
  def input(id, value, options \\ []) do
    control!("input", id, "value", value, options)
  end

  @doc "A horizontal group. Options are `id` and an integer `gap` in 0..128."
  @spec row([Node.t()], options()) :: Node.t()
  def row(children, options \\ []), do: Node.new!("row", options, children)

  @doc "A vertical group. Options are `id` and an integer `gap` in 0..128."
  @spec column([Node.t()], options()) :: Node.t()
  def column(children, options \\ []), do: Node.new!("column", options, children)

  @doc """
  A vertical native collection using its children's stable IDs.

  Give changing or reordered children explicit application-derived IDs. Unkeyed
  static descendants are scoped beneath the nearest keyed parent by their
  position. Options are `id` and `gap` in 0..128.
  """
  @spec list([Node.t()], options()) :: Node.t()
  def list(children, options \\ []), do: Node.new!("list", options, children)

  defp control!(kind, id, content_key, content, options) do
    unless is_binary(id),
      do: raise(ArgumentError, "native controls require an explicit stable id")

    Node.validate_id!(id)

    attrs =
      options
      |> Node.normalize_attrs!()
      |> event_alias!(kind)
      |> put_required!("id", id)
      |> put_required!(content_key, content)

    Node.new!(kind, attrs)
  end

  defp event_alias!(attrs, kind) do
    if Map.has_key?(attrs, "event") do
      {event, attrs} = Map.pop(attrs, "event")
      property = if kind == "button", do: "phx-click", else: "phx-change"
      put_required!(attrs, property, event)
    else
      attrs
    end
  end

  defp put_required!(attrs, key, value) do
    if Map.has_key?(attrs, key),
      do: raise(ArgumentError, "conflicting native option #{inspect(key)}")

    Map.put(attrs, key, value)
  end
end
