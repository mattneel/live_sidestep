defmodule LiveSidestep.PhoenixAdapter do
  @moduledoc """
  The boundary between native view callbacks and Phoenix assign management.

  The socket is a hand-built `Phoenix.LiveView.Socket`, not a mounted LiveView:
  there is no endpoint, router, channel, browser transport, HTML, or LiveView
  diff engine. Only assigns and the `mount/3`, `render/1`, `handle_event/3`, and
  optional `handle_info/2` callback shape are supported. Navigation, streams,
  components, slots, flash, and LiveView push APIs are not implemented.

  A checkpoint contains assigns only, excluding `:__changed__`. On a worker
  restart, `mount/3` runs again and the last valid checkpoint is replayed over
  its defaults before rendering. Private socket data and process resources
  such as subscriptions must be recreated by `mount/3`.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView.Socket

  @type socket :: %Socket{assigns: map(), private: map()}

  @doc false
  @spec build_socket(pid()) :: socket()
  def build_socket(owner) when is_pid(owner) do
    %Socket{
      assigns: %{__changed__: %{}},
      private: %{live_sidestep_session: owner}
    }
  end

  @doc "Assigns a map or keyword list using Phoenix change tracking."
  @spec assign(socket(), map() | keyword()) :: socket()
  def assign(socket, assigns), do: Component.assign(socket, assigns)

  @doc "Assigns one key using Phoenix change tracking."
  @spec assign(socket(), atom(), term()) :: socket()
  def assign(socket, key, value), do: Component.assign(socket, key, value)

  @doc "Updates an assigned key using Phoenix change tracking."
  @spec update(socket(), atom(), (term() -> term())) :: socket()
  def update(socket, key, function), do: Component.update(socket, key, function)

  @doc false
  @spec validate!(term()) :: socket()
  def validate!(%Socket{assigns: %{__changed__: changed} = assigns, private: private} = socket)
      when is_map(changed) and is_map(private) do
    unless Enum.all?(Map.keys(assigns), &is_atom/1) do
      raise ArgumentError, "native view socket assigns must have atom keys"
    end

    socket
  end

  def validate!(socket) do
    raise ArgumentError,
          "callback must return a Phoenix assign-capable socket, got: #{inspect(socket)}"
  end

  @doc false
  @spec replay_checkpoint(socket(), map()) :: socket()
  def replay_checkpoint(socket, checkpoint) when is_map(checkpoint) do
    assign(socket, Map.delete(checkpoint, :__changed__))
  end

  @doc false
  @spec checkpoint(socket()) :: map()
  def checkpoint(socket), do: Map.delete(socket.assigns, :__changed__)

  @doc false
  @spec assigns(socket()) :: map()
  def assigns(socket), do: socket.assigns

  @doc false
  @spec reset_changes(socket()) :: socket()
  def reset_changes(socket), do: %{socket | assigns: Map.put(socket.assigns, :__changed__, %{})}

  @doc false
  @spec private(socket(), atom()) :: term()
  def private(socket, key), do: Map.get(socket.private, key)
end
