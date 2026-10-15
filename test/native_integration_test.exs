defmodule LiveSidestep.NativeIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag skip: not match?({:unix, :linux}, :os.type())
  @moduletag capture_log: true

  defmodule View do
    use LiveSidestep.View

    def mount(params, _session, socket) do
      send(params["observer"], {:mounted, self()})
      {:ok, assign(socket, count: 0, rows: [{"a", "alpha"}, {"b", "beta"}], invalid: false)}
    end

    def render(%{invalid: true}), do: raise("application render failed")

    def render(assigns) do
      column(
        [
          text("Count: #{assigns.count}", id: "count"),
          list(Enum.map(assigns.rows, fn {id, value} -> input(id, value, event: "edit") end),
            id: "editors"
          )
        ],
        id: "root"
      )
    end

    def handle_event("edit", _params, socket), do: {:noreply, socket}
    def handle_info(:increment, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
    def handle_info(:reverse, socket), do: {:noreply, update(socket, :rows, &Enum.reverse/1)}
    def handle_info(:invalid, socket), do: {:noreply, assign(socket, :invalid, true)}
  end

  defmodule SlowMount do
    use LiveSidestep.View

    def mount(params, _session, socket) do
      send(params["observer"], {:mount_waiting, self()})

      receive do
        :continue_mount -> {:ok, assign(socket, text: "Mounted")}
      end
    end

    def render(assigns), do: text(assigns.text, id: "status")
    def handle_event(_event, _params, socket), do: {:noreply, socket}
  end

  defmodule Topology do
    use LiveSidestep.View

    def mount(_params, _session, socket), do: {:ok, assign(socket, inverted: false)}

    def render(assigns) do
      {root, child} = if assigns.inverted, do: {"b", "a"}, else: {"a", "b"}
      column([column([input("field", "retained")], id: child)], id: root)
    end

    def handle_event(_name, _params, socket), do: {:noreply, socket}
    def handle_info(:invert, socket), do: {:noreply, assign(socket, :inverted, true)}
  end

  defmodule RowLayout do
    use LiveSidestep.View

    def mount(_params, _session, socket), do: {:ok, socket}

    def render(_assigns) do
      row(
        [
          button("increment", "Increment"),
          text("Count: 7", id: "count"),
          button("save", "Save"),
          text("Saved", id: "status")
        ],
        id: "row",
        gap: 10
      )
    end

    def handle_event(_name, _params, socket), do: {:noreply, socket}
  end

  setup do
    previous = System.get_env("SIDESTEP_BACKEND")
    System.put_env("SIDESTEP_BACKEND", "null")

    on_exit(fn ->
      if previous,
        do: System.put_env("SIDESTEP_BACKEND", previous),
        else: System.delete_env("SIDESTEP_BACKEND")
    end)

    :ok
  end

  test "mixed-height controls center independently on each wrapped native row line" do
    {:ok, session} = LiveSidestep.open(RowLayout, width: 200)
    on_exit(fn -> if Process.alive?(session), do: LiveSidestep.close(session) end)
    native = inspect_until(session, &(&1["revision"] > 0))

    for {label, button} <- [{"count", "increment"}, {"status", "save"}] do
      [_, label_y, _, label_height] = native["nodes"][label]["frame"]
      [_, button_y, _, button_height] = native["nodes"][button]["frame"]
      assert label_height < button_height
      assert_in_delta label_y + label_height / 2, button_y + button_height / 2, 0.01
    end

    [_, first_y, _, first_height] = native["nodes"]["increment"]["frame"]
    [_, second_y, _, _] = native["nodes"]["save"]["frame"]
    assert second_y >= first_y + first_height + 10
  end

  test "keyed reorder and view restart retain real AppKit objects and the last rendered checkpoint" do
    session = open(View)
    assert_receive {:mounted, worker}
    initial = inspect_until(session, &(&1["revision"] > 0))
    host = initial["host_pid"]
    editor = initial["nodes"]["a"]["entity"]

    send(worker, :increment)
    inspect_until(session, &(&1["nodes"]["count"]["text"] == "Count: 1"))
    send(worker, :reverse)
    reordered = inspect_until(session, &(&1["nodes"]["editors"]["children"] == ["b", "a"]))
    assert reordered["nodes"]["a"]["entity"] == editor
    assert reordered["nodes"]["a"]["value"] == "alpha"

    :ok = LiveSidestep.restart_view(session)
    assert_receive {:mounted, replacement}
    assert replacement != worker
    restored = inspect_until(session, &(&1["generation"] > initial["generation"]))
    assert restored["host_pid"] == host
    assert restored["nodes"]["a"]["entity"] == editor
    assert restored["nodes"]["count"]["text"] == "Count: 1"
    assert restored["nodes"]["editors"]["children"] == ["b", "a"]
  end

  test "a retained ancestor can become a descendant without a transient native cycle" do
    session = open(Topology)
    initial = inspect_until(session, &(&1["revision"] > 0))
    send(LiveSidestep.view_pid(session), :invert)
    inverted = inspect_until(session, &(&1["root"] == "b"))
    assert inverted["nodes"]["b"]["children"] == ["a"]
    assert inverted["nodes"]["a"]["children"] == ["field"]
    assert inverted["nodes"]["field"]["entity"] == initial["nodes"]["field"]["entity"]
    assert inverted["host_pid"] == initial["host_pid"]
    assert inverted["generation"] == initial["generation"]
  end

  test "a failed render cannot replace the successful checkpoint" do
    session = open(View)
    assert_receive {:mounted, worker}
    inspect_until(session, &(&1["revision"] > 0))
    send(worker, :increment)
    before = inspect_until(session, &(&1["nodes"]["count"]["text"] == "Count: 1"))
    monitor = Process.monitor(worker)
    send(worker, :invalid)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    assert_receive {:mounted, replacement}
    assert replacement != worker
    recovered = inspect_until(session, &(&1["generation"] > before["generation"]))
    assert recovered["nodes"]["count"]["text"] == "Count: 1"
    assert recovered["host_pid"] == before["host_pid"]
  end

  test "slow user mount does not block session inspection or the native loop" do
    session = open(SlowMount)
    assert_receive {:mount_waiting, worker}
    assert LiveSidestep.view_pid(session) == worker
    first = inspect_until(session, &is_integer(&1["frames"]))
    next = inspect_until(session, &(&1["frames"] > first["frames"]))
    assert next["revision"] == 0
    send(worker, :continue_mount)
    mounted = inspect_until(session, &(&1["revision"] > 0))
    assert mounted["nodes"]["status"]["text"] == "Mounted"
  end

  test "explicit close reaps its native child and stops its view" do
    session = open(View)
    assert_receive {:mounted, worker}
    native = inspect_until(session, &(&1["revision"] > 0))
    monitor = Process.monitor(worker)
    assert :ok = LiveSidestep.close(session)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    refute File.exists?("/proc/#{native["host_pid"]}")
  end

  test "session owner death releases the window even when terminate cannot run" do
    session = open(View)
    assert_receive {:mounted, worker}
    native = inspect_until(session, &(&1["revision"] > 0))
    monitor = Process.monitor(worker)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    eventually(fn -> not File.exists?("/proc/#{native["host_pid"]}") end)
  end

  test "native process failure stops the session without opening a replacement window" do
    session = open(View)
    assert_receive {:mounted, worker}
    native = inspect_until(session, &(&1["revision"] > 0))
    session_monitor = Process.monitor(session)
    worker_monitor = Process.monitor(worker)
    {_, 0} = System.cmd("kill", ["-KILL", to_string(native["host_pid"])])
    assert_receive {:DOWN, ^session_monitor, :process, ^session, _reason}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    refute Process.alive?(session)
    refute File.exists?("/proc/#{native["host_pid"]}")
  end

  defp open(module) do
    {:ok, session} = LiveSidestep.open(module, params: %{"observer" => self()})
    on_exit(fn -> if Process.alive?(session), do: LiveSidestep.close(session) end)
    session
  end

  defp inspect_until(session, predicate) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    inspect_until(session, predicate, deadline)
  end

  defp inspect_until(session, predicate, deadline) do
    result = LiveSidestep.inspect_native(session, 1_000)

    case result do
      {:ok, inspection} ->
        if predicate.(inspection),
          do: inspection,
          else: retry_inspection(session, predicate, deadline, result)

      {:error, reason} when reason in [:not_ready, :busy] ->
        retry_inspection(session, predicate, deadline, result)

      unexpected ->
        flunk("native inspection failed: #{inspect(unexpected)}")
    end
  end

  defp retry_inspection(session, predicate, deadline, last_result) do
    assert System.monotonic_time(:millisecond) < deadline,
           "native state did not converge: #{inspect(last_result)}"

    receive do
    after
      10 -> inspect_until(session, predicate, deadline)
    end
  end

  defp eventually(predicate),
    do: eventually(predicate, System.monotonic_time(:millisecond) + 5_000)

  defp eventually(predicate, deadline) do
    unless predicate.() do
      assert System.monotonic_time(:millisecond) < deadline, "native child was not reaped"

      receive do
      after
        10 -> eventually(predicate, deadline)
      end
    end
  end
end
