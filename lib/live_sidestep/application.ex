defmodule LiveSidestep.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _arguments) do
    children = [
      Supervisor.child_spec(
        {DynamicSupervisor, name: LiveSidestep.Views, strategy: :one_for_one},
        id: LiveSidestep.Views
      ),
      Supervisor.child_spec(
        {DynamicSupervisor, name: LiveSidestep.Sessions, strategy: :one_for_one},
        id: LiveSidestep.Sessions
      )
    ]

    # Sessions depend on the worker supervisor. Losing it closes their windows;
    # temporary session children are never recreated behind the user's back.
    Supervisor.start_link(children, strategy: :rest_for_one, name: LiveSidestep.Supervisor)
  end
end
