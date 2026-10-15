defmodule LiveSidestep.TreeTest do
  use ExUnit.Case, async: true

  alias LiveSidestep.{Node, Tree, UI}

  @u64_max 18_446_744_073_709_551_615

  test "reordering keyed controls only upserts the parent's child order" do
    a = UI.input("a", "alpha")
    b = UI.input("b", "bravo")
    before = UI.list([a, b], id: "list") |> Tree.flatten()
    after_tree = UI.list([b, a], id: "list") |> Tree.flatten()
    patch = Tree.patch(before, after_tree, 7, 12)

    assert patch == %{
             "type" => "patch",
             "generation" => 7,
             "base_revision" => 12,
             "revision" => 13,
             "root" => "list",
             "remove" => [],
             "upsert" => [
               %{"id" => "list", "kind" => "list", "props" => %{}, "children" => ["b", "a"]}
             ]
           }
  end

  test "static descendants remain rooted under keyed parents after reorder and reparenting" do
    row = fn id -> UI.row([UI.input(id <> "-input", id), UI.text(id)], id: id) end
    a = row.("a")
    b = row.("b")
    before = UI.list([a, b]) |> Tree.flatten()
    after_tree = UI.list([b, a]) |> Tree.flatten()
    assert before["nodes"]["a/1"] == after_tree["nodes"]["a/1"]
    assert after_tree["nodes"]["a"]["children"] == ["a-input", "a/1"]
    assert after_tree["nodes"]["b"]["children"] == ["b-input", "b/1"]

    nested = UI.column([UI.row([a], id: "group"), b]) |> Tree.flatten()
    patch = Tree.patch(before, nested, 1, 1)
    assert patch["remove"] == []

    refute Enum.any?(
             patch["upsert"],
             &(&1["id"] in ["a", "a-input", "a/1", "b", "b-input", "b/1"])
           )
  end

  test "removals, kind replacements, incarnation changes, and root changes are explicit" do
    before =
      UI.column([
        UI.text("gone", id: "z"),
        UI.input("same", "old"),
        UI.text("also gone", id: "a")
      ])
      |> Tree.flatten()

    after_tree =
      UI.row([UI.button("same", "new", incarnation: 3)], id: "new-root") |> Tree.flatten()

    patch = Tree.patch(before, after_tree, 2, 4)

    assert patch["root"] == "new-root"
    assert patch["remove"] == ["a", "root", "z"]
    assert Enum.map(patch["upsert"], & &1["id"]) == ["new-root", "same"]
    assert List.last(patch["upsert"])["kind"] == "button"

    recreated =
      UI.row([UI.button("same", "new", incarnation: 4)], id: "new-root") |> Tree.flatten()

    assert [%{"id" => "same", "props" => %{"incarnation" => 4}}] =
             Tree.patch(after_tree, recreated, 2, 5)["upsert"]
  end

  test "an unchanged tree still has a deterministic next revision with no node operations" do
    tree = UI.text("unchanged") |> Tree.flatten()
    assert %{"upsert" => [], "remove" => [], "revision" => 9} = Tree.patch(tree, tree, 1, 8)

    assert Tree.snapshot(tree, 3, 7) == %{
             "type" => "snapshot",
             "generation" => 3,
             "revision" => 7,
             "tree" => tree
           }
  end

  test "scalar numeric type changes are not discarded by loose equality" do
    before = UI.button("button", "Count", "phx-value-count": 1) |> Tree.flatten()
    after_tree = UI.button("button", "Count", "phx-value-count": 1.0) |> Tree.flatten()

    assert [%{"id" => "button", "props" => %{"phx-value-count" => 1.0}}] =
             Tree.patch(before, after_tree, 1, 1)["upsert"]
  end

  test "duplicate explicit and generated IDs are rejected globally" do
    for root <- [
          UI.column([UI.text("collision", id: "root")]),
          UI.column([UI.text("first"), UI.text("collision", id: "root/0")]),
          UI.column([UI.row([UI.text("one", id: "same")]), UI.row([UI.text("two", id: "same")])])
        ] do
      assert_raise ArgumentError, fn -> Tree.flatten(root) end
    end
  end

  test "generated identities are also subject to the ID byte limit" do
    assert_raise ArgumentError, fn ->
      UI.column([UI.text("child")], id: String.duplicate("x", 1024)) |> Tree.flatten()
    end
  end

  test "tree depth and count accept the exact bounds and reject one extra node or level" do
    leaf = %Node{kind: "text"}

    at_depth =
      Enum.reduce(1..63, leaf, fn _, child -> %Node{kind: "column", children: [child]} end)

    assert map_size(Tree.flatten(at_depth)["nodes"]) == 64
    assert_raise ArgumentError, fn -> Tree.flatten(%Node{kind: "row", children: [at_depth]}) end

    children = for index <- 1..4095, do: %Node{id: "n-#{index}", kind: "text"}
    at_count = %Node{kind: "list", children: children}
    assert map_size(Tree.flatten(at_count)["nodes"]) == 4096

    assert_raise ArgumentError, fn ->
      Tree.flatten(%{at_count | children: [%Node{kind: "text"} | children]})
    end
  end

  test "snapshot and patch counters cannot cross the unsigned 64-bit boundary" do
    tree = UI.text("valid") |> Tree.flatten()
    assert Tree.snapshot(tree, @u64_max, @u64_max)["revision"] == @u64_max
    assert Tree.patch(tree, tree, @u64_max, @u64_max - 1)["revision"] == @u64_max
    assert Tree.patch(tree, tree, 1, 0)["revision"] == 1

    for invalid <- [0, -1, 1.0, "1", @u64_max + 1] do
      assert_raise ArgumentError, fn -> Tree.snapshot(tree, invalid, 1) end
      assert_raise ArgumentError, fn -> Tree.snapshot(tree, 1, invalid) end
      assert_raise ArgumentError, fn -> Tree.patch(tree, tree, invalid, 0) end
    end

    for invalid <- [-1, 1.0, "1", @u64_max, @u64_max + 1] do
      assert_raise ArgumentError, fn -> Tree.patch(tree, tree, 1, invalid) end
    end
  end

  test "already flattened maps receive full schema and topology validation at every boundary" do
    valid = UI.column([UI.text("child", id: "child")]) |> Tree.flatten()
    root = valid["nodes"]["root"]
    child = valid["nodes"]["child"]

    invalid_trees = [
      %{},
      Map.put(valid, "unknown", true),
      %{valid | "root" => "missing"},
      %{valid | "nodes" => %{}},
      put_in(valid, ["nodes", "child", "id"], "different"),
      put_in(valid, ["nodes", "child", "kind"], "html"),
      put_in(valid, ["nodes", "child", "props"], %{"text" => "bad\0value"}),
      put_in(valid, ["nodes", "root", "children"], ["child", "child"]),
      put_in(valid, ["nodes", "child", "children"], ["root"]),
      put_in(valid, ["nodes", "root", "children"], ["missing"]),
      put_in(valid, ["nodes", "root", "children"], []),
      put_in(valid, ["nodes", "child"], Map.put(child, "unknown", nil)),
      %{
        valid
        | "nodes" => %{
            "root" => root,
            "child" => %{child | "kind" => "row", "children" => ["root"]}
          }
      },
      %{
        "root" => "root",
        "nodes" => %{
          "root" => %{root | "children" => ["left", "right"]},
          "left" => %{root | "id" => "left"},
          "right" => %{root | "id" => "right"},
          "child" => child
        }
      }
    ]

    for invalid <- invalid_trees do
      assert_raise ArgumentError, fn -> Tree.snapshot(invalid, 1, 1) end
      assert_raise ArgumentError, fn -> Tree.patch(invalid, valid, 1, 1) end
      assert_raise ArgumentError, fn -> Tree.patch(valid, invalid, 1, 1) end
    end
  end
end
