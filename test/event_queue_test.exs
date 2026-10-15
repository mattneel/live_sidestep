defmodule LiveSidestep.EventQueueTest do
  use ExUnit.Case, async: true

  alias LiveSidestep.EventQueue

  test "discrete actions remain FIFO and overflow is explicit" do
    first = click("first")
    second = click("second")
    third = click("third")
    assert {:ok, queue} = EventQueue.push(%EventQueue{limit: 2}, first)
    assert {:ok, queue} = EventQueue.push(queue, second)
    assert {:error, :event_overflow} = EventQueue.push(queue, third)
    assert {^first, queue} = EventQueue.pop(queue)
    assert {^second, queue} = EventQueue.pop(queue)
    assert queue.size == 0
    assert {nil, ^queue} = EventQueue.pop(queue)
  end

  test "only adjacent changes with the same semantic identity coalesce, even at capacity" do
    assert {:ok, queue} = EventQueue.push(%EventQueue{limit: 1}, change(1, "a"))
    assert {:ok, queue} = EventQueue.push(queue, change(2, "ab"))
    assert {:ok, queue} = EventQueue.push(queue, change(2, "AB"))
    assert queue.size == 1

    assert {%{"params" => %{"value" => "AB", "edit_revision" => 2}}, queue} =
             EventQueue.pop(queue)

    assert queue.size == 0
  end

  test "a click is an ordering barrier between changes" do
    before = change(1, "before")
    action = click("save")
    after_action = change(2, "after")
    assert {:ok, queue} = EventQueue.push(%EventQueue{}, before)
    assert {:ok, queue} = EventQueue.push(queue, action)
    assert {:ok, queue} = EventQueue.push(queue, after_action)
    assert queue.size == 3
    assert {^before, queue} = EventQueue.pop(queue)
    assert {^action, queue} = EventQueue.pop(queue)
    assert {^after_action, _queue} = EventQueue.pop(queue)
  end

  test "node, incarnation, event name, generation and kind are coalescing boundaries" do
    first = change(1, "first")

    variants = [
      Map.put(change(2, "second"), "node", "other"),
      Map.put(change(2, "second"), "incarnation", 2),
      Map.put(change(2, "second"), "name", "renamed"),
      Map.put(change(2, "second"), "generation", 2),
      Map.put(change(2, "second"), "kind", "click")
    ]

    for second <- variants do
      assert {:ok, queue} = EventQueue.push(%EventQueue{}, first)
      assert {:ok, queue} = EventQueue.push(queue, second)
      assert queue.size == 2
      assert {^first, queue} = EventQueue.pop(queue)
      assert {^second, _queue} = EventQueue.pop(queue)
    end
  end

  test "decreasing or invalid edit revisions never replace a queued action" do
    first = change(5, "newer")

    for revision <- [4, -1, "6", nil] do
      second = change(revision, "older or malformed")
      assert {:ok, queue} = EventQueue.push(%EventQueue{limit: 1}, first)
      assert {:error, :event_overflow} = EventQueue.push(queue, second)
      assert {^first, _queue} = EventQueue.pop(queue)
    end
  end

  test "dispatch revalidates queued actions against the latest desired declaration" do
    action = click("save")
    assert {:ok, queue} = EventQueue.push(%EventQueue{}, action)
    assert {nil, _queue} = EventQueue.pop(queue, tree(%{}), %{})

    invalid_nodes = [
      node("input", %{"phx-change" => "save", "incarnation" => 1}),
      node("button", %{"phx-click" => "renamed", "incarnation" => 1}),
      node("button", %{"phx-click" => "save", "incarnation" => 2})
    ]

    for invalid <- invalid_nodes do
      assert {nil, _queue} = EventQueue.pop(queue, tree(%{"action" => invalid}), %{})
    end

    valid = node("button", %{"phx-click" => "save", "incarnation" => 1})
    assert {^action, _queue} = EventQueue.pop(queue, tree(%{"action" => valid}), %{})
  end

  test "dispatch skips obsolete drafts using declaration and committed callback revisions" do
    older = change(3, "older")
    newer = change(4, "newer")
    action = click("save")
    assert {:ok, queue} = EventQueue.push(%EventQueue{}, older)
    assert {:ok, queue} = EventQueue.push(queue, action)
    assert {:ok, queue} = EventQueue.push(queue, newer)

    desired =
      tree(%{
        "editor" =>
          node("input", %{"phx-change" => "edit", "incarnation" => 1, "edit_revision" => 2}),
        "action" => node("button", %{"phx-click" => "save", "incarnation" => 1})
      })

    committed = %{{"editor", 1} => 3}
    assert {^action, queue} = EventQueue.pop(queue, desired, committed)
    assert {^newer, queue} = EventQueue.pop(queue, desired, committed)
    assert {nil, _queue} = EventQueue.pop(queue, desired, committed)

    acknowledged = put_in(desired, ["nodes", "editor", "props", "edit_revision"], 4)
    assert {:ok, queue} = EventQueue.push(%EventQueue{}, newer)
    assert {nil, _queue} = EventQueue.pop(queue, acknowledged, %{})
  end

  test "a replacement incarnation has its own draft sequence" do
    event = Map.put(change(1, "replacement"), "incarnation", 2)
    desired = tree(%{"editor" => node("input", %{"phx-change" => "edit", "incarnation" => 2})})
    assert {:ok, queue} = EventQueue.push(%EventQueue{}, event)
    assert {^event, _queue} = EventQueue.pop(queue, desired, %{{"editor", 1} => 99})
  end

  test "malformed draft parameters cannot reach an application callback" do
    desired = tree(%{"editor" => node("input", %{"phx-change" => "edit", "incarnation" => 1})})

    for event <- [change(-1, "bad"), change("1", "bad"), change(1, nil), change(1, <<255>>)] do
      assert {:ok, queue} = EventQueue.push(%EventQueue{}, event)
      assert {nil, _queue} = EventQueue.pop(queue, desired, %{})
    end
  end

  defp click(name) do
    %{
      "generation" => 1,
      "revision" => 1,
      "node" => "action",
      "incarnation" => 1,
      "kind" => "click",
      "name" => name,
      "params" => %{}
    }
  end

  defp change(revision, value) do
    %{
      "generation" => 1,
      "revision" => 1,
      "node" => "editor",
      "incarnation" => 1,
      "kind" => "change",
      "name" => "edit",
      "params" => %{"edit_revision" => revision, "value" => value}
    }
  end

  defp node(kind, props), do: %{"kind" => kind, "props" => props, "children" => []}
  defp tree(nodes), do: %{"root" => "root", "nodes" => nodes}
end
