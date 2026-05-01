defmodule CounterflowWeb.Plugs.BasicAuth do
  @moduledoc """
  Optional HTTP Basic Auth gate for the browser pipeline. Activates only
  when both COUNTERFLOW_USER and COUNTERFLOW_PASSWORD env vars are set,
  so localhost dev runs unauthenticated by default and a public deploy
  is gated automatically once the env vars land.

  Implementation uses Plug.BasicAuth with constant-time comparison.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    case credentials() do
      {user, pass} ->
        Plug.BasicAuth.basic_auth(conn, username: user, password: pass, realm: "Counterflow")

      :disabled ->
        conn
    end
  end

  defp credentials do
    user =
      Application.get_env(:counterflow, :auth_user) ||
        System.get_env("COUNTERFLOW_USER")

    pass =
      Application.get_env(:counterflow, :auth_password) ||
        System.get_env("COUNTERFLOW_PASSWORD")

    cond do
      is_binary(user) and user != "" and is_binary(pass) and pass != "" -> {user, pass}
      true -> :disabled
    end
  end
end
