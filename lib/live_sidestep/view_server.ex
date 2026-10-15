defmodule LiveSidestep.ViewServer do
  @moduledoc false
  use GenServer, restart: :temporary, shutdown: :brutal_kill

  alias LiveSidestep.{PhoenixAdapter, Tree}

  @max_message_bytes 1_048_576
  @max_revision 18_446_744_073_709_551_615

  defstruct [:module, :owner, :monitor, :socket, :params, :session, :checkpoint]

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    owner = Keyword.fetch!(options, :owner)
    monitor = Process.monitor(owner)

    # The monitor handles a normal owner exit. The link also interrupts a busy
    # callback if the owner is killed, rather than leaving a CPU-bound orphan.
    Process.link(owner)

    state = %__MODULE__{
      module: Keyword.fetch!(options, :view),
      owner: owner,
      monitor: monitor,
      socket: PhoenixAdapter.build_socket(owner),
      params: Keyword.get(options, :params, %{}),
      session: Keyword.get(options, :session, %{}),
      checkpoint: Keyword.get(options, :checkpoint, %{})
    }

    # No application code runs during start_link: even mount may block for an
    # arbitrary amount of time without blocking the session or its supervisor.
    {:ok, state, {:continue, :mount}}
  end

  @impl true
  def handle_continue(:mount, state) do
    socket =
      state.module.mount(state.params, state.session, state.socket)
      |> callback_socket!(:mount)
      |> PhoenixAdapter.replay_checkpoint(state.checkpoint)

    state = %{state | socket: socket, params: nil, session: nil, checkpoint: nil}
    {:noreply, commit(state, nil)}
  end

  @impl true
  def handle_info({:native_event, reference, event}, state) when is_reference(reference) do
    socket =
      state.module.handle_event(event["name"], event["params"], state.socket)
      |> callback_socket!(:handle_event)

    {:noreply, commit(%{state | socket: socket}, reference)}
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{monitor: monitor, owner: owner} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    # Intentionally no catch-all application callback: an unhandled message is a
    # view bug, not an action the runtime may silently discard.
    socket = state.module.handle_info(message, state.socket) |> callback_socket!(:handle_info)
    {:noreply, commit(%{state | socket: socket}, nil)}
  end

  defp callback_socket!({:ok, socket}, :mount), do: PhoenixAdapter.validate!(socket)

  defp callback_socket!({:noreply, socket}, callback)
       when callback in [:handle_event, :handle_info],
       do: PhoenixAdapter.validate!(socket)

  defp callback_socket!(result, callback) do
    raise ArgumentError, "unsupported #{callback} callback return: #{inspect(result)}"
  end

  defp commit(state, event_reference) do
    tree = state.socket |> PhoenixAdapter.assigns() |> state.module.render() |> Tree.flatten()

    # Reserve the largest possible generation/revision envelope, so a valid
    # checkpoint remains publishable even after future worker generations.
    frame = tree |> Tree.snapshot(@max_revision, @max_revision) |> Jason.encode!()

    if byte_size(frame) > @max_message_bytes do
      raise ArgumentError, "native snapshot exceeds #{@max_message_bytes} bytes"
    end

    checkpoint = PhoenixAdapter.checkpoint(state.socket)
    :ok = GenServer.call(state.owner, {:render, self(), event_reference, checkpoint, tree})
    %{state | socket: PhoenixAdapter.reset_changes(state.socket)}
  end
end
