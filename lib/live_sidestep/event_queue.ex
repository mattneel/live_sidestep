defmodule LiveSidestep.EventQueue do
  @moduledoc false

  @max_revision 18_446_744_073_709_551_615
  @max_text_bytes 65_536

  defstruct queue: :queue.new(), size: 0, limit: 64

  def push(state, event) do
    case :queue.out_r(state.queue) do
      {{:value, previous}, rest} -> enqueue(state, event, previous, rest)
      {:empty, _queue} -> append(state, event)
    end
  end

  def pop(state) do
    case :queue.out(state.queue) do
      {{:value, event}, rest} -> {event, %{state | queue: rest, size: state.size - 1}}
      {:empty, _queue} -> {nil, state}
    end
  end

  # Intake validation alone is insufficient: a callback ahead of this event may
  # remove the control, replace its incarnation, or change its event binding.
  def pop(state, desired, committed_revisions) do
    case pop(state) do
      {nil, state} ->
        {nil, state}

      {event, state} ->
        if valid_for?(event, desired, committed_revisions) do
          {event, state}
        else
          pop(state, desired, committed_revisions)
        end
    end
  end

  def valid_for?(
        %{
          "node" => id,
          "incarnation" => incarnation,
          "kind" => kind,
          "name" => name,
          "params" => params
        },
        %{"nodes" => nodes},
        committed_revisions
      )
      when is_binary(id) and is_integer(incarnation) and incarnation >= 0 and
             incarnation <= @max_revision and is_binary(name) and is_map(params) do
    with %{"kind" => node_kind, "props" => props} when is_map(props) <- Map.get(nodes, id),
         true <- Map.get(props, "incarnation", 0) == incarnation,
         true <- Enum.all?(params, &scalar_parameter?/1) do
      matches_binding?(kind, node_kind, name, params, props, id, incarnation, committed_revisions)
    else
      _ -> false
    end
  end

  def valid_for?(_event, _desired, _committed_revisions), do: false

  defp enqueue(
         state,
         %{
           "kind" => "change",
           "generation" => generation,
           "node" => id,
           "incarnation" => incarnation,
           "name" => name,
           "params" => %{"edit_revision" => revision}
         } = event,
         %{
           "kind" => "change",
           "generation" => generation,
           "node" => id,
           "incarnation" => incarnation,
           "name" => name,
           "params" => %{"edit_revision" => previous}
         },
         rest
       )
       when is_integer(revision) and is_integer(previous) and previous >= 0 and
              revision >= previous and revision <= @max_revision do
    {:ok, %{state | queue: :queue.in(event, rest)}}
  end

  defp enqueue(state, event, _previous, _rest), do: append(state, event)

  defp append(%{size: size, limit: limit}, _event) when size >= limit,
    do: {:error, :event_overflow}

  defp append(state, event),
    do: {:ok, %{state | queue: :queue.in(event, state.queue), size: state.size + 1}}

  defp matches_binding?("click", "button", name, _params, props, _id, _incarnation, _revisions),
    do: Map.get(props, "phx-click") == name

  defp matches_binding?(
         "change",
         "input",
         name,
         %{"value" => value, "edit_revision" => revision},
         props,
         id,
         incarnation,
         committed_revisions
       )
       when is_binary(value) and byte_size(value) <= @max_text_bytes and
              is_integer(revision) and revision >= 0 and revision <= @max_revision do
    acknowledged = Map.get(props, "edit_revision", 0)
    committed = Map.get(committed_revisions, {id, incarnation}, 0)

    Map.get(props, "phx-change") == name and String.valid?(value) and
      revision > max(acknowledged, committed)
  end

  defp matches_binding?(_kind, _node_kind, _name, _params, _props, _id, _incarnation, _revisions),
    do: false

  defp scalar_parameter?({key, value}) when is_binary(key),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp scalar_parameter?(_parameter), do: false
end
