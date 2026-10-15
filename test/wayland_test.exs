defmodule LiveSidestep.WaylandTest do
  use ExUnit.Case, async: false

  @moduletag :wayland
  @moduletag timeout: 30_000
  @moduletag capture_log: true

  defmodule View do
    use LiveSidestep.View

    def mount(params, _session, socket) do
      {:ok,
       assign(socket,
         observer: params["observer"],
         count: 0,
         draft: "",
         draft_revision: 0,
         rows: [{"a", "alpha", 0}, {"b", "beta", 0}]
       )}
    end

    def render(assigns) do
      column(
        [
          text("Count: #{assigns.count}", id: "count"),
          row(
            [
              button("increment", "Increment", event: "increment"),
              button("busy", "Five seconds of Elixir work", event: "busy")
            ],
            gap: 12
          ),
          input("draft", assigns.draft, %{
            "phx-change" => "edit",
            "phx-value-key" => "draft",
            "edit_revision" => assigns.draft_revision
          }),
          text("Accepted: #{assigns.draft}", id: "accepted"),
          list(
            Enum.map(assigns.rows, fn {id, value, revision} ->
              input(id, value, %{
                "phx-change" => "edit",
                "phx-value-key" => id,
                "edit_revision" => revision
              })
            end),
            id: "editors",
            gap: 8
          )
        ],
        id: "root",
        gap: 12
      )
    end

    def handle_event("increment", _params, socket),
      do: {:noreply, update(socket, :count, &(&1 + 1))}

    def handle_event("busy", _params, socket) do
      send(socket.assigns.observer, {:busy, self()})
      spin_until(System.monotonic_time(:millisecond) + 5_000)
      {:noreply, socket}
    end

    def handle_event(
          "edit",
          %{"key" => "draft", "value" => value, "edit_revision" => revision},
          socket
        ) do
      send(socket.assigns.observer, {:draft_callback, value, revision})
      if value == "reject", do: exit(:rejected_draft)
      {:noreply, assign(socket, draft: value, draft_revision: revision)}
    end

    def handle_event(
          "edit",
          %{"key" => key, "value" => value, "edit_revision" => revision},
          socket
        ) do
      rows =
        Enum.map(socket.assigns.rows, fn
          {^key, _value, _revision} -> {key, value, revision}
          row -> row
        end)

      {:noreply, assign(socket, :rows, rows)}
    end

    def handle_info(:reverse, socket), do: {:noreply, update(socket, :rows, &Enum.reverse/1)}

    defp spin_until(deadline) do
      if System.monotonic_time(:millisecond) < deadline, do: spin_until(deadline)
    end
  end

  setup_all do
    for name <- ["WAYLAND_DISPLAY", "SWAYSOCK"] do
      assert System.get_env(name), "run this suite through scripts/wayland-check"
    end

    executable = Path.expand("../_build/native/debug/examples/wayland_seat", __DIR__)

    pointer =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [:binary, :exit_status])

    on_exit(fn -> if Port.info(pointer), do: Port.close(pointer) end)
    assert_receive {^pointer, {:data, "WAYLAND_SEAT_READY\n"}}
    :ok
  end

  setup do
    for name <- ["WAYLAND_DISPLAY", "SWAYSOCK"] do
      assert System.get_env(name), "run this suite through scripts/wayland-check"
    end

    refute System.get_env("SIDESTEP_BACKEND") == "null"

    {:ok, session} =
      LiveSidestep.open(View, params: %{"observer" => self()}, title: "Sidestep acceptance")

    on_exit(fn -> if Process.alive?(session), do: LiveSidestep.close(session) end)
    inspect_until(session, &(&1["revision"] > 0))
    %{session: session}
  end

  test "native click round-trip and editing continue during a CPU-bound callback", %{
    session: session
  } do
    click(session, "increment")
    inspect_until(session, &(&1["nodes"]["count"]["text"] == "Count: 1"))
    click(session, "busy")
    assert_receive {:busy, _worker}
    started = System.monotonic_time(:millisecond)
    first = inspect_until(session, &is_integer(&1["frames"]))
    click(session, "draft")
    type(["-d", "5", "Native input stays responsive"])

    editing =
      inspect_until(session, &(&1["nodes"]["draft"]["value"] == "Native input stays responsive"))

    assert System.monotonic_time(:millisecond) - started < 4_000
    field = editing["nodes"]["draft"]
    assert field["edit_revision"] > field["acknowledged_revision"]
    assert editing["frames"] > first["frames"]

    accepted =
      inspect_until(
        session,
        fn state ->
          state["nodes"]["draft"]["acknowledged_revision"] >= field["edit_revision"]
        end,
        8_000
      )

    assert accepted["nodes"]["draft"]["value"] == field["value"]
  end

  test "native selection and keyed control identity survive reorder and view recovery", %{
    session: session
  } do
    click(session, "a")
    type(["X", "-M", "shift", "-k", "Left", "-m", "shift"])

    before =
      inspect_until(session, fn state ->
        field = state["nodes"]["a"]

        field["edit_revision"] > 0 and Enum.at(field["selection"], 1) == 1 and
          field["acknowledged_revision"] >= field["edit_revision"]
      end)

    field = before["nodes"]["a"]
    send(LiveSidestep.view_pid(session), :reverse)
    reordered = inspect_until(session, &(&1["nodes"]["editors"]["children"] == ["b", "a"]))
    assert_editor(reordered["nodes"]["a"], field)
    :ok = LiveSidestep.restart_view(session)
    restored = inspect_until(session, &(&1["generation"] > before["generation"]))
    assert restored["host_pid"] == before["host_pid"]
    assert_editor(restored["nodes"]["a"], field)
  end

  test "a failed input callback is not replayed, but a newer native draft is delivered", %{
    session: session
  } do
    initial = inspect_until(session, &(&1["revision"] > 0))
    click(session, "draft")
    type(["-d", "10", "reject"])
    assert_receive {:draft_callback, "reject", failed_revision}
    recovered = inspect_until(session, &(&1["generation"] > initial["generation"]))
    assert recovered["generation"] == initial["generation"] + 1
    assert recovered["nodes"]["accepted"]["text"] != "Accepted: reject"
    assert recovered["nodes"]["draft"]["value"] == "reject"
    replacement = LiveSidestep.view_pid(session)
    refute_receive {:draft_callback, "reject", ^failed_revision}, 200
    assert Process.alive?(replacement)
    type(["X"])
    assert_receive {:draft_callback, "rejectX", newer_revision}
    assert newer_revision > failed_revision
    accepted = inspect_until(session, &(&1["nodes"]["accepted"]["text"] == "Accepted: rejectX"))
    assert accepted["nodes"]["draft"]["acknowledged_revision"] == newer_revision
  end

  test "compositor window close ends only its session", %{session: session} do
    native = inspect_until(session, &(&1["revision"] > 0))
    await_window(native["host_pid"], System.monotonic_time(:millisecond) + 5_000)
    monitor = Process.monitor(session)
    worker = LiveSidestep.view_pid(session)
    worker_monitor = Process.monitor(worker)
    {output, 0} = System.cmd("swaymsg", ["-r", "[pid=#{native["host_pid"]}] kill"])
    assert Enum.all?(Jason.decode!(output), & &1["success"])
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    assert Process.alive?(Process.whereis(LiveSidestep.Sessions))
    refute File.exists?("/proc/#{native["host_pid"]}")
  end

  defp assert_editor(actual, expected) do
    for key <- ["entity", "value", "selection", "focused"] do
      assert actual[key] == expected[key], "native #{key} changed during keyed reconciliation"
    end
  end

  defp click(session, id) do
    native = inspect_until(session, &Map.has_key?(&1["nodes"], id))
    window = await_window(native["host_pid"], System.monotonic_time(:millisecond) + 5_000)
    [x, y, width, height] = native["nodes"][id]["frame"]
    rect = window["rect"]
    content = window["window_rect"]
    left = round(rect["x"] + content["x"] + x + width / 2)
    top = round(rect["y"] + content["y"] + y + height / 2)

    command =
      "seat seat0 cursor set #{left} #{top}; seat seat0 cursor press button1; seat seat0 cursor release button1"

    {output, 0} = System.cmd("swaymsg", ["-r", command])
    assert Enum.all?(Jason.decode!(output), & &1["success"])
  end

  defp await_window(pid, deadline) do
    {json, 0} = System.cmd("swaymsg", ["-r", "-t", "get_tree"])

    case find_window(Jason.decode!(json), pid) do
      %{
        "visible" => true,
        "focused" => true,
        "window_rect" => %{"width" => 960, "height" => 720}
      } = window ->
        window

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "native window did not map at its configured size with compositor focus"

        receive do
        after
          10 -> await_window(pid, deadline)
        end
    end
  end

  defp find_window(%{"pid" => pid} = node, pid), do: node

  defp find_window(node, pid) do
    Enum.find_value(
      Map.get(node, "nodes", []) ++ Map.get(node, "floating_nodes", []),
      &find_window(&1, pid)
    )
  end

  defp type(arguments) do
    {output, status} = System.cmd("wtype", arguments, stderr_to_stdout: true)
    assert status == 0, "Wayland keyboard injection failed: #{output}"
  end

  defp inspect_until(session, predicate, timeout \\ 5_000) do
    inspect_before(session, predicate, System.monotonic_time(:millisecond) + timeout)
  end

  defp inspect_before(session, predicate, deadline) do
    result = LiveSidestep.inspect_native(session, 1_000)

    case result do
      {:ok, native} ->
        if predicate.(native),
          do: native,
          else: retry_inspection(session, predicate, deadline, result)

      {:error, reason} when reason in [:not_ready, :busy] ->
        retry_inspection(session, predicate, deadline, result)

      unexpected ->
        flunk("native inspection failed: #{inspect(unexpected)}")
    end
  end

  defp retry_inspection(session, predicate, deadline, last_result) do
    assert System.monotonic_time(:millisecond) < deadline,
           "native interaction did not converge: #{inspect(last_result)}"

    receive do
    after
      10 -> inspect_before(session, predicate, deadline)
    end
  end
end
