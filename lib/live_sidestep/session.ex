defmodule LiveSidestep.Session do
  @moduledoc false
  use GenServer, restart: :temporary

  require Logger

  alias LiveSidestep.{EventQueue, Native, Tree, ViewServer}

  @max_message_bytes 1_048_576
  @max_revision 18_446_744_073_709_551_615
  @max_timeout 4_294_967_295
  @max_inspections 64
  @publish_timeout 5000

  defstruct [
    :options,
    :native,
    :resource_id,
    :worker,
    :monitor,
    :desired,
    :applied,
    :flight,
    :event,
    :retry,
    generation: 1,
    revision: 0,
    ready: false,
    configured: false,
    checkpoint: %{},
    events: %EventQueue{},
    edit_revisions: %{},
    inspections: %{},
    restart_times: []
  ]

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    resource_id = System.unique_integer([:positive, :monotonic])
    executable = Keyword.get_lazy(options, :host, &Native.host_path/0)

    case Native.open(executable, self(), resource_id) do
      {:ok, native} ->
        state = %__MODULE__{options: options, native: native, resource_id: resource_id}

        case start_worker(state) do
          {:ok, state} ->
            {:ok, state}

          {:error, reason} ->
            Native.close(native)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:view_pid, _from, state), do: {:reply, state.worker, state}

  def handle_call(:restart_view, _from, state) do
    Process.exit(state.worker, :kill)
    {:reply, :ok, state}
  end

  def handle_call(
        {:render, worker, reference, checkpoint, tree},
        {worker, _tag},
        %{worker: worker} = state
      ) do
    state = %{state | checkpoint: checkpoint, desired: tree}
    state = state |> complete_event(reference) |> prune_edit_revisions()

    case publish(state) do
      {:ok, state} ->
        {:reply, :ok, dispatch_event(state)}

      {:error, reason, state} ->
        {:stop, {:shutdown, {:native_update_rejected, reason}}, {:error, reason}, state}
    end
  end

  def handle_call({:render, _worker, _reference, _checkpoint, _tree}, _from, state),
    do: {:reply, {:error, :stale_worker}, state}

  def handle_call({:inspect_native, _timeout}, _from, %{ready: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:inspect_native, _timeout}, _from, state)
      when map_size(state.inspections) >= @max_inspections,
      do: {:reply, {:error, :busy}, state}

  def handle_call({:inspect_native, timeout}, from, state)
      when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout do
    request = System.unique_integer([:positive, :monotonic])

    case submit(state, %{"type" => "inspect", "request" => request}) do
      :ok ->
        timer = Process.send_after(self(), {:inspection_timeout, request}, timeout)
        monitor = Process.monitor(elem(from, 0))
        waiting = %{from: from, timer: timer, monitor: monitor}
        {:noreply, %{state | inspections: Map.put(state.inspections, request, waiting)}}

      {:error, :closed} = error ->
        {:stop, :normal, error, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:inspect_native, _timeout}, _from, state),
    do: {:reply, {:error, :invalid_timeout}, state}

  @impl true
  def handle_info({:live_sidestep_native, id, payload}, %{resource_id: id} = state) do
    # Each delivered message consumes a bridge credit, including invalid,
    # obsolete, and terminal messages. Return it before doing any decoding.
    :ok = Native.ack(state.native)

    if is_binary(payload) and byte_size(payload) <= @max_message_bytes do
      case Jason.decode(payload) do
        {:ok, message} -> native_message(message, state)
        {:error, reason} -> {:stop, {:invalid_native_message, reason}, state}
      end
    else
      {:stop, {:invalid_native_message, :invalid_payload}, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, reason},
        %{monitor: monitor, worker: worker} = state
      ) do
    restart_worker(state, reason)
  end

  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state) do
    case Enum.find(state.inspections, fn {_request, waiting} -> waiting.monitor == monitor end) do
      {request, _waiting} ->
        {:noreply, finish_inspection(state, request, {:error, :closed})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:publish, token}, %{retry: {_timer, token}} = state),
    do: advance(%{state | retry: nil})

  def handle_info({:inspection_timeout, request}, state),
    do: {:noreply, finish_inspection(state, request, {:error, :timeout})}

  def handle_info(
        {:publish_timeout, generation, revision},
        %{generation: generation, flight: %{revision: revision}} = state
      ) do
    {:stop, {:shutdown, :native_publish_timeout}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_flight(state.flight)
    cancel_retry(state)
    if state.worker, do: Process.exit(state.worker, :kill)

    Enum.each(state.inspections, fn {_request, waiting} ->
      Process.cancel_timer(waiting.timer)
      Process.demonitor(waiting.monitor, [:flush])
      GenServer.reply(waiting.from, {:error, :closed})
    end)

    if state.native, do: Native.close(state.native)
    :ok
  end

  defp native_message(%{"type" => "ready", "protocol" => 1, "host_pid" => pid}, state)
       when is_integer(pid) and pid > 0 do
    advance(%{state | ready: true})
  end

  defp native_message(%{"type" => "ready", "protocol" => protocol}, state),
    do: {:stop, {:unsupported_native_protocol, protocol}, state}

  defp native_message(%{"type" => "closed", "reason" => reason}, state) when is_binary(reason) do
    if reason in ["window closed", "window_closed", "closed"] do
      {:stop, :normal, state}
    else
      {:stop, {:shutdown, {:native_closed, reason}}, state}
    end
  end

  defp native_message(%{"type" => "inspection", "request" => request} = message, state)
       when is_integer(request) and request >= 0 and request <= @max_revision do
    {:noreply, finish_inspection(state, request, {:ok, message})}
  end

  defp native_message(
         %{"type" => "inspection_error", "request" => request, "reason" => reason},
         state
       )
       when is_integer(request) and request >= 0 and request <= @max_revision and
              is_binary(reason) do
    {:noreply, finish_inspection(state, request, {:error, {:native, reason}})}
  end

  defp native_message(
         %{"type" => "applied", "generation" => generation, "revision" => revision},
         %{generation: generation, flight: %{revision: revision} = flight} = state
       ) do
    cancel_flight(flight)
    applied = %{tree: flight.tree, revision: revision}
    advance(%{state | applied: applied, flight: nil})
  end

  defp native_message(%{"type" => "applied"}, state), do: {:noreply, state}

  defp native_message(
         %{"type" => "resync", "generation" => generation, "revision" => revision},
         %{generation: generation} = state
       )
       when is_integer(revision) and revision >= 0 and revision <= @max_revision do
    cancel_flight(state.flight)
    state = %{state | applied: nil, flight: nil, revision: max(state.revision, revision)}
    advance(state)
  end

  defp native_message(%{"type" => "resync"}, state), do: {:noreply, state}

  defp native_message(
         %{"type" => "event", "generation" => generation, "revision" => revision} = event,
         %{generation: generation} = state
       )
       when is_integer(revision) and revision > 0 and revision <= @max_revision do
    if revision <= state.revision and
         EventQueue.valid_for?(event, state.desired, state.edit_revisions) do
      case EventQueue.push(state.events, event) do
        {:ok, events} -> {:noreply, dispatch_event(%{state | events: events})}
        {:error, reason} -> {:stop, {:shutdown, reason}, state}
      end
    else
      {:noreply, state}
    end
  end

  defp native_message(%{"type" => "event"}, state), do: {:noreply, state}

  defp native_message(message, state),
    do: {:stop, {:invalid_native_message, message}, state}

  defp start_worker(state) do
    options = Keyword.merge(state.options, owner: self(), checkpoint: state.checkpoint)

    case DynamicSupervisor.start_child(LiveSidestep.Views, {ViewServer, options}) do
      {:ok, worker} -> {:ok, %{state | worker: worker, monitor: Process.monitor(worker)}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:view_supervisor_unavailable, reason}}
  end

  defp restart_worker(state, reason) do
    failed_event = if state.event, do: state.event.event["name"], else: nil

    Logger.warning(
      "LiveSidestep view #{inspect(state.options[:view])} exited: #{inspect(reason)}; " <>
        "failed callback event: #{inspect(failed_event)}; restoring last valid checkpoint"
    )

    now = System.monotonic_time(:millisecond)
    recent = Enum.filter(state.restart_times, &(now - &1 < 5000))

    cond do
      match?([_, _, _ | _], recent) ->
        {:stop, {:shutdown, :view_restart_intensity}, state}

      state.generation == @max_revision ->
        {:stop, {:shutdown, :generation_exhausted}, state}

      true ->
        cancel_flight(state.flight)
        state = cancel_retry(state)
        # A native draft is replayed after remount. Retire an abandoned edit's
        # revision without committing its failed assigns, so replay cannot run
        # the same external effects again; a newer full draft still qualifies.
        state =
          case state.event do
            %{reference: reference} -> complete_event(state, reference)
            nil -> state
          end

        # Accepted, not-yet-dispatched actions survive a worker crash. They are
        # revalidated against the replacement's desired tree before dispatch.
        # The failed in-flight callback is deliberately never replayed.
        state = %{
          state
          | worker: nil,
            monitor: nil,
            generation: state.generation + 1,
            revision: 0,
            desired: nil,
            applied: nil,
            flight: nil,
            event: nil,
            restart_times: [now | recent]
        }

        case start_worker(state) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:stop, {:shutdown, {:view_start_failed, reason}}, state}
        end
    end
  end

  defp complete_event(%{event: %{reference: reference, event: event}} = state, reference) do
    revisions =
      case event do
        %{
          "kind" => "change",
          "node" => id,
          "incarnation" => incarnation,
          "params" => %{"edit_revision" => revision}
        } ->
          Map.put(state.edit_revisions, {id, incarnation}, revision)

        _event ->
          state.edit_revisions
      end

    %{state | event: nil, edit_revisions: revisions}
  end

  defp complete_event(state, _reference), do: state

  defp prune_edit_revisions(state) do
    revisions =
      Map.filter(state.edit_revisions, fn {{id, incarnation}, _revision} ->
        case state.desired["nodes"][id] do
          %{"kind" => "input", "props" => props} ->
            Map.get(props, "incarnation", 0) == incarnation

          _node ->
            false
        end
      end)

    %{state | edit_revisions: revisions}
  end

  defp dispatch_event(%{event: event} = state) when not is_nil(event), do: state
  defp dispatch_event(%{desired: nil} = state), do: state

  defp dispatch_event(state) do
    {event, events} = EventQueue.pop(state.events, state.desired, state.edit_revisions)
    state = %{state | events: events}

    if event do
      reference = make_ref()
      send(state.worker, {:native_event, reference, event})
      %{state | event: %{reference: reference, event: event}}
    else
      state
    end
  end

  defp advance(state) do
    case publish(state) do
      {:ok, state} -> {:noreply, dispatch_event(state)}
      {:error, reason, state} -> {:stop, {:shutdown, {:native_update_rejected, reason}}, state}
    end
  end

  defp publish(%{ready: false} = state), do: {:ok, state}

  defp publish(%{configured: false} = state) do
    configure = %{
      "type" => "configure",
      "title" => Keyword.get(state.options, :title, "LiveSidestep"),
      "width" => Keyword.get(state.options, :width, 960),
      "height" => Keyword.get(state.options, :height, 720)
    }

    case submit(state, configure) do
      :ok ->
        state = cancel_retry(state)
        publish(%{state | configured: true})

      {:error, :busy} ->
        {:ok, schedule_publish(state)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp publish(%{desired: nil} = state), do: {:ok, cancel_retry(state)}
  defp publish(%{flight: flight} = state) when not is_nil(flight), do: {:ok, cancel_retry(state)}
  defp publish(%{desired: tree, applied: %{tree: tree}} = state), do: {:ok, cancel_retry(state)}

  defp publish(%{revision: @max_revision} = state),
    do: {:error, :revision_exhausted, state}

  defp publish(state) do
    {revision, payload} = update_payload(state)

    case Native.submit(state.native, payload) do
      :ok ->
        state = cancel_retry(state)

        timer =
          Process.send_after(
            self(),
            {:publish_timeout, state.generation, revision},
            @publish_timeout
          )

        flight = %{tree: state.desired, revision: revision, timer: timer}
        {:ok, %{state | revision: revision, flight: flight}}

      {:error, :busy} ->
        {:ok, schedule_publish(state)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp update_payload(%{applied: nil} = state), do: snapshot_payload(state)

  defp update_payload(state) do
    command =
      Tree.patch(state.applied.tree, state.desired, state.generation, state.applied.revision)

    payload = Jason.encode!(command)

    # A topology replacement can make a patch larger than its full snapshot.
    # Worker preflight guarantees that the snapshot alternative fits.
    if byte_size(payload) <= @max_message_bytes do
      {command["revision"], payload}
    else
      snapshot_payload(state)
    end
  end

  defp snapshot_payload(state) do
    revision = state.revision + 1
    {revision, state.desired |> Tree.snapshot(state.generation, revision) |> Jason.encode!()}
  end

  defp schedule_publish(%{retry: nil} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:publish, token}, 10)
    %{state | retry: {timer, token}}
  end

  defp schedule_publish(state), do: state

  defp cancel_retry(%{retry: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | retry: nil}
  end

  defp cancel_retry(state), do: state
  defp cancel_flight(nil), do: :ok
  defp cancel_flight(flight), do: Process.cancel_timer(flight.timer)

  defp finish_inspection(state, request, response) do
    {waiting, inspections} = Map.pop(state.inspections, request)

    if waiting do
      Process.cancel_timer(waiting.timer)
      Process.demonitor(waiting.monitor, [:flush])
      GenServer.reply(waiting.from, response)
    end

    %{state | inspections: inspections}
  end

  defp submit(state, command), do: Native.submit(state.native, Jason.encode!(command))
end
