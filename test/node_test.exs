defmodule LiveSidestep.NodeTest do
  use ExUnit.Case, async: true

  alias LiveSidestep.{Node, Tree, UI}

  @u64_max 18_446_744_073_709_551_615

  test "literal template content is joined and trimmed, then validated" do
    assert Node.new!("button", %{}, ["  Go ", "now  "]).props == %{"text" => "Go now"}
    assert Node.new!("text", %{}, ["   "]).props == %{}
    assert UI.text("  Native text  ").props["text"] == "  Native text  "

    for children <- [["bad\0text"], [<<255>>], [String.duplicate("x", 65_537)]] do
      assert_raise ArgumentError, fn -> Node.new!("text", %{}, children) end
    end

    assert_raise ArgumentError, fn ->
      Node.new!("text", %{text: "property"}, ["content"])
    end
  end

  test "attribute normalization never silently overwrites duplicate names" do
    for attrs <- [
          [{:text, "first"}, {"text", "second"}],
          [{:id, "one"}, {"id", "two"}],
          %{"text" => "second", text: "first"},
          [{:text, "first"}, {:text, "second"}]
        ] do
      assert_raise ArgumentError, fn -> Node.new!("text", attrs) end
    end

    for attrs <- [nil, "text", [:text], [{1, "invalid"}], %Node{kind: "text"}] do
      assert_raise ArgumentError, fn -> Node.new!("text", attrs) end
    end
  end

  test "UI constructors reject conflicting options and absent interactive identities" do
    for constructor <- [
          fn -> UI.button("b", "B", event: "one", "phx-click": "two") end,
          fn -> UI.input("i", "", event: "one", "phx-change": "two") end,
          fn -> UI.text("text", event: "web") end,
          fn -> UI.column([], event: "web") end,
          fn -> UI.button("b", "B", id: "replacement") end,
          fn -> UI.text("text", text: "replacement") end,
          fn -> UI.input("i", "value", value: "replacement") end
        ] do
      assert_raise ArgumentError, constructor
    end

    for id <- [nil, ""] do
      assert_raise ArgumentError, fn -> UI.button(id, "B") end
      assert_raise ArgumentError, fn -> UI.input(id, "") end
    end
  end

  test "IDs, names, property keys, and text obey UTF-8 and byte limits" do
    id = String.duplicate("é", 512)
    text = String.duplicate("é", 32_768)
    key = "phx-value-" <> String.duplicate("k", 1014)
    node = Node.new!("button", %{"id" => id, "text" => text, "phx-click" => id, key => text})
    assert node.id == id
    assert byte_size(node.props["text"]) == 65_536

    for bad <- ["", String.duplicate("é", 513), "nul\0id", <<255>>] do
      assert_raise ArgumentError, fn -> Node.new!("text", id: bad) end
      assert_raise ArgumentError, fn -> Node.new!("button", %{"phx-click" => bad}) end
      assert_raise ArgumentError, fn -> Node.new!("input", %{"phx-change" => bad}) end
    end

    for bad <- [String.duplicate("é", 32_769), "nul\0text", <<255>>],
        {kind, property} <- [
          {"text", "text"},
          {"button", "text"},
          {"input", "value"},
          {"input", "placeholder"},
          {"button", "phx-value-data"}
        ] do
      assert_raise ArgumentError, fn -> Node.new!(kind, %{property => bad}) end
    end

    for bad_key <- [key <> "x", "phx-value-bad\0key", "phx-value-" <> <<255>>, "phx-value-"] do
      assert_raise ArgumentError, fn -> Node.new!("button", %{bad_key => 1}) end
    end
  end

  test "edit revisions and control incarnations are unsigned 64-bit integers" do
    for counter <- [0, @u64_max] do
      assert Node.new!("input", incarnation: counter, edit_revision: counter).props == %{
               "incarnation" => counter,
               "edit_revision" => counter
             }

      assert Node.new!("button", incarnation: counter).props == %{"incarnation" => counter}
    end

    for value <- [-1, @u64_max + 1, 1.0, "1", nil],
        {kind, property} <- [
          {"input", "edit_revision"},
          {"input", "incarnation"},
          {"button", "incarnation"}
        ] do
      assert_raise ArgumentError, fn -> Node.new!(kind, %{property => value}) end
    end
  end

  test "event parameters accept only JSON scalar values" do
    for scalar <- [nil, false, true, 0, -1, 1.5, "value", @u64_max, -9_223_372_036_854_775_808] do
      assert Node.new!("button", %{"phx-value-data" => scalar}).props["phx-value-data"] === scalar
    end

    for value <- [%{}, [], :atom, self(), @u64_max + 1, -9_223_372_036_854_775_809] do
      assert_raise ArgumentError, fn -> Node.new!("input", %{"phx-value-data" => value}) end
    end
  end

  test "closed property and structural invariants reject unknown options" do
    for {kind, attrs, children} <- [
          {"div", %{}, []},
          {:text, %{}, []},
          {"text", %{class: "web"}, []},
          {"button", %{onclick: "web()"}, []},
          {"text", %{incarnation: 0}, []},
          {"row", %{gap: -1}, []},
          {"list", %{gap: 129}, []},
          {"column", %{gap: 1.0}, []},
          {"column", %{}, ["raw"]},
          {"input", %{}, ["child"]},
          {"text", %{}, [%Node{kind: "row"}]},
          {"button", %{"phx-change" => "edit"}, []},
          {"input", %{"phx-click" => "click"}, []}
        ] do
      assert_raise ArgumentError, fn -> Node.new!(kind, attrs, children) end
    end
  end

  test "manual structs cannot bypass render-boundary validation" do
    for node <- [
          %Node{kind: "html"},
          %Node{kind: "text", id: ""},
          %Node{kind: "text", id: "bad\0id"},
          %Node{kind: "text", props: %{text: "atom key"}},
          %Node{kind: "text", props: %{"class" => "web"}},
          %Node{kind: "text", props: %{"text" => <<255>>}},
          %Node{kind: "text", props: %{"text" => String.duplicate("x", 65_537)}},
          %Node{kind: "button", props: %{"incarnation" => @u64_max + 1}},
          %Node{kind: "input", props: %{"edit_revision" => -1}},
          %Node{kind: "text", children: ["unprocessed content"]},
          %Node{kind: "input", children: [%Node{kind: "text"}]},
          %Node{kind: "column", props: []},
          %Node{kind: "column", children: [%{}]},
          %Node{kind: "column", children: nil}
        ] do
      assert_raise ArgumentError, fn -> Tree.flatten(node) end
      assert_raise ArgumentError, fn -> Tree.flatten(%Node{kind: "row", children: [node]}) end
    end

    assert_raise ArgumentError, fn -> Tree.flatten(%{}) end
  end
end
