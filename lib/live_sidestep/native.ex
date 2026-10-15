defmodule LiveSidestep.Native do
  @moduledoc false

  @external_resource "priv/native/live_sidestep_native.so"
  @external_resource "Cargo.toml"
  @external_resource "Cargo.lock"

  use Rustler,
    otp_app: :live_sidestep,
    crate: :live_sidestep_native,
    skip_compilation?: true

  def open(executable, owner, resource_id) do
    open_native(executable, owner, resource_id, System.get_env())
  end

  defp open_native(_executable, _owner, _resource_id, _environment),
    do: :erlang.nif_error(:nif_not_loaded)

  def submit(_resource, _message), do: :erlang.nif_error(:nif_not_loaded)
  def ack(_resource), do: :erlang.nif_error(:nif_not_loaded)
  def close(_resource), do: :erlang.nif_error(:nif_not_loaded)

  def host_path, do: Application.app_dir(:live_sidestep, "priv/native/live_sidestep_host")
end
