defmodule LiveSidestep do
  @moduledoc """
  Native Sidestep/AppKit windows with isolated, LiveView-shaped Elixir callbacks.

  `open/2` starts a session and returns before the view's `mount/3` or `render/1`
  completes. The session owns the native window; a separate worker owns assigns
  and callbacks. A worker crash remounts and restores the last successfully
  rendered assigns without replacing the window. Closing the window or losing
  the host ends the session permanently.

  Checkpoints are in-memory presentation state, not durable application state.
  A failed callback is not transactional and is not replayed: effects performed
  before a crash cannot be undone. Keep durable writes in ordinary application
  services and make external effects idempotent where appropriate.
  """

  alias LiveSidestep.Session

  @options [:params, :session, :name, :host, :title, :width, :height]
  @max_timeout 4_294_967_295

  @doc """
  Opens one native window for a `LiveSidestep.View` module.

  Options are `:params` and `:session` (maps passed to `mount/3`), `:name`
  (a GenServer name for the session), `:host` (an executable path), `:title`
  (a UTF-8 string of at most 1,024 bytes without NUL), and `:width`/`:height`
  (integers from 200 through 8,192). Defaults are an empty params/session map,
  the packaged host, the title `"LiveSidestep"`, and a 960 by 720 window.

  Invalid modules or options raise `ArgumentError` before any process or host is
  started. Host launch errors are returned unchanged as `{:error, reason}`.
  Window initialization and callback failures after startup are asynchronous;
  monitor the returned session PID to observe its eventual termination.
  """
  @spec open(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def open(view, options \\ []) do
    validate_view!(view)
    validate_options!(options)
    DynamicSupervisor.start_child(LiveSidestep.Sessions, {Session, [{:view, view} | options]})
  end

  @doc "Closes the session normally, including its native host and current worker."
  @spec close(GenServer.server()) :: :ok
  def close(session), do: GenServer.stop(session, :normal)

  @doc "Returns the worker PID without waiting for a running application callback."
  @spec view_pid(GenServer.server()) :: pid()
  def view_pid(session), do: GenServer.call(session, :view_pid)

  @doc """
  Restarts the worker from its latest valid checkpoint, retaining native controls.

  At most three worker restarts are allowed in a rolling five-second interval.
  A fourth terminates the session with `{:shutdown, :view_restart_intensity}`.
  """
  @spec restart_view(GenServer.server()) :: :ok
  def restart_view(session), do: GenServer.call(session, :restart_view)

  @doc """
  Inspects actual native controls, editor selection, and applied protocol state.

  `timeout` must be a positive, finite integer number of milliseconds, at most
  4,294,967,295. Returns `{:ok, inspection}` or `{:error, reason}`. Reasons include
  `:not_ready`, `:busy` (64 inspections are already pending or the native command
  queue is full), `:timeout`, `:closed`, and native submission errors unchanged.
  Pending inspections receive `{:error, :closed}` during orderly session shutdown.
  Untrappable session death can exit the GenServer call instead.
  The inspection's `frames` count is native run-loop ticks, not compositor
  presentation or proof of pixels reaching a display.
  """
  @spec inspect_native(GenServer.server(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def inspect_native(session, timeout \\ 5000)

  def inspect_native(session, timeout)
      when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout do
    GenServer.call(session, {:inspect_native, timeout}, min(timeout + 1000, @max_timeout))
  end

  def inspect_native(_session, _timeout) do
    raise ArgumentError, "inspection timeout must be an integer in 1..#{@max_timeout}"
  end

  defp validate_view!(view) when is_atom(view) and not is_nil(view) do
    Code.ensure_loaded!(view)

    for {callback, arity} <- [mount: 3, render: 1, handle_event: 3] do
      unless function_exported?(view, callback, arity) do
        raise ArgumentError, "#{inspect(view)} must export #{callback}/#{arity}"
      end
    end
  end

  defp validate_view!(_view), do: raise(ArgumentError, "view must be a loaded Elixir module")

  defp validate_options!(options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, "open options must be a keyword list"
    end

    keys = Keyword.keys(options)

    unless length(keys) == MapSet.size(MapSet.new(keys)) do
      raise ArgumentError, "open options must not contain duplicate keys"
    end

    Enum.each(options, fn {key, value} ->
      unless key in @options, do: raise(ArgumentError, "unknown open option #{inspect(key)}")
      validate_option!(key, value)
    end)
  end

  defp validate_option!(key, value) when key in [:params, :session] and is_map(value), do: :ok

  defp validate_option!(:name, name) when is_atom(name) and not is_nil(name), do: :ok
  defp validate_option!(:name, {:global, _name}), do: :ok

  defp validate_option!(:name, {:via, module, _name})
       when is_atom(module) and not is_nil(module),
       do: :ok

  defp validate_option!(:host, path) when is_binary(path) and byte_size(path) > 0 do
    validate_string!(:host, path)
  end

  defp validate_option!(:title, title) when is_binary(title) and byte_size(title) <= 1024 do
    validate_string!(:title, title)
  end

  defp validate_option!(key, value)
       when key in [:width, :height] and is_integer(value) and value in 200..8192,
       do: :ok

  defp validate_option!(key, value) do
    raise ArgumentError, "invalid #{inspect(key)} option: #{inspect(value)}"
  end

  defp validate_string!(key, value) do
    unless String.valid?(value) and not String.contains?(value, <<0>>) do
      raise ArgumentError, "#{inspect(key)} must be valid UTF-8 without NUL"
    end
  end
end
