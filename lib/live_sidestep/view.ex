defmodule LiveSidestep.View do
  @moduledoc """
  LiveView-shaped callbacks rendering native Sidestep/AppKit controls.

  `use LiveSidestep.View` imports `assign/2,3`, `update/3`, native UI constructors,
  and `~V`. Templates support `column`, `row`, `list`, `text`, `button`, `input`,
  assigns and brace expressions, `:if`, and keyed `:for`; they are not HEEx or
  HTML. `render/1` may also return a tree built with `LiveSidestep.UI` functions.

  Mount and every callback/render run in an isolated worker, never the session
  or native UI thread. A successful, validated render commits an in-memory
  assigns checkpoint. A crashed callback or invalid render leaves the previous
  checkpoint intact. Remount recreates process-local resources before that
  checkpoint is replayed; it does not replay the failed callback's side effects.

  Native changes carry the complete UTF-8 `"value"` and integer
  `"edit_revision"` in params. Store both and render the revision back on the
  input to acknowledge the edit without overwriting a newer native draft.
  Event params also contain scalar `phx-value-*` attributes with that prefix
  removed. Replacing a button or input under the same ID requires changing its
  `incarnation` to invalidate queued interactions from the old control.

  `handle_info/2` is optional only if no application messages are sent to the
  worker. Unknown messages or event names and unsupported callback return
  shapes fail the worker instead of silently discarding application actions.
  This is callback compatibility, not a Phoenix LiveView runtime; see
  `LiveSidestep.PhoenixAdapter` for the exact boundary.
  """

  alias LiveSidestep.{Node, PhoenixAdapter}

  @callback mount(map(), map(), PhoenixAdapter.socket()) :: {:ok, PhoenixAdapter.socket()}
  @callback render(map()) :: Node.t()
  @callback handle_event(String.t(), map(), PhoenixAdapter.socket()) ::
              {:noreply, PhoenixAdapter.socket()}
  @callback handle_info(term(), PhoenixAdapter.socket()) :: {:noreply, PhoenixAdapter.socket()}
  @optional_callbacks handle_info: 2

  defmacro __using__(_options) do
    quote do
      @behaviour LiveSidestep.View
      import LiveSidestep.PhoenixAdapter, only: [assign: 2, assign: 3, update: 3]
      import LiveSidestep.UI
      import LiveSidestep.View, only: [sigil_V: 2]
    end
  end

  @doc "Compiles the supported native template language, with no HTML fallback."
  defmacro sigil_V({:<<>>, _metadata, [source]}, []) when is_binary(source) do
    LiveSidestep.Template.compile(source, __CALLER__)
  end

  defmacro sigil_V(_source, _modifiers) do
    raise ArgumentError, "~V requires a literal native template and no modifiers"
  end
end
