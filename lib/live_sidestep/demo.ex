defmodule LiveSidestep.Demo do
  @moduledoc """
  Native controls demonstrating revisioned edits, keyed identity, and view recovery.

      {:ok, session} = LiveSidestep.open(LiveSidestep.Demo)

  Start the five-second CPU callback, then continue typing. Reverse the keyed
  editors while one has a selection, or restart the worker without replacing
  its native window. Assigns are presentation checkpoints, not durable storage.
  """
  use LiveSidestep.View

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       count: 0,
       draft: "",
       draft_revision: 0,
       completed: 0,
       next_id: 4,
       rows: [
         %{id: 1, value: "First keyed editor", revision: 0},
         %{id: 2, value: "Second keyed editor", revision: 0},
         %{id: 3, value: "Third keyed editor", revision: 0}
       ]
     )}
  end

  @impl true
  def render(assigns) do
    ~V"""
    <column id="demo" gap={14}>
      <text>LiveSidestep — native AppKit controls, Elixir-owned views</text>
      <text>The native event loop and editor remain independent of Elixir callbacks. Type during the five-second CPU job, then reorder editors or restart the view: stable keys retain the native control, caret, selection, and draft.</text>
      <row gap={10}>
        <button id="increment" phx-click="increment">Increment</button>
        <text id="count">Count: {@count}</text>
        <button id="busy" phx-click="busy">Run CPU callback (5 seconds)</button>
        <button id="restart" phx-click="restart">Restart view</button>
      </row>
      <text id="completed">Completed CPU callbacks: {@completed}</text>
      <input id="draft" value={@draft} edit_revision={@draft_revision}
        placeholder="Type here while Elixir is busy" phx-change="draft" />
      <text id="draft-value">Accepted draft: {@draft}</text>
      <row gap={10}>
        <button id="reverse" phx-click="reverse">Reverse editors</button>
        <button id="add" phx-click="add">Add editor</button>
        <button id="remove" phx-click="remove">Remove first editor</button>
      </row>
      <list id="editors" gap={10}>
        <input :for={row <- @rows} id={"editor-#{row.id}"} value={row.value}
          edit_revision={row.revision} incarnation={1} phx-change="edit"
          phx-value-key={row.id} />
      </list>
    </column>
    """
  end

  @impl true
  def handle_event("increment", _params, socket),
    do: {:noreply, update(socket, :count, &(&1 + 1))}

  def handle_event("draft", %{"value" => value, "edit_revision" => revision}, socket),
    do: {:noreply, assign(socket, draft: value, draft_revision: revision)}

  def handle_event("edit", %{"key" => id, "value" => value, "edit_revision" => revision}, socket) do
    rows =
      Enum.map(socket.assigns.rows, fn
        %{id: ^id} = row -> %{row | value: value, revision: revision}
        row -> row
      end)

    {:noreply, assign(socket, :rows, rows)}
  end

  def handle_event("reverse", _params, socket),
    do: {:noreply, update(socket, :rows, &Enum.reverse/1)}

  def handle_event("add", _params, socket) do
    id = socket.assigns.next_id
    row = %{id: id, value: "Editor #{id}", revision: 0}
    {:noreply, assign(socket, rows: [row | socket.assigns.rows], next_id: id + 1)}
  end

  def handle_event("remove", _params, socket),
    do: {:noreply, update(socket, :rows, &Enum.drop(&1, 1))}

  def handle_event("busy", _params, socket) do
    spin_until(System.monotonic_time(:millisecond) + 5_000)
    {:noreply, update(socket, :completed, &(&1 + 1))}
  end

  def handle_event("restart", _params, _socket), do: exit(:demo_restart)

  defp spin_until(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: spin_until(deadline)
  end
end
