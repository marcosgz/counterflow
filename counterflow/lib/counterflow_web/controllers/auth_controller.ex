defmodule CounterflowWeb.AuthController do
  @moduledoc """
  Session login/logout endpoints. /auth/finish is the post-LiveView
  hop that actually writes the session cookie (LiveView event handlers
  can't set sessions directly).
  """

  use CounterflowWeb, :controller

  alias Counterflow.Accounts
  alias CounterflowWeb.Auth

  def finish(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate(email, password) do
      {:ok, user} ->
        conn
        |> Auth.log_in_user(user)
        |> redirect(to: "/")

      _ ->
        conn
        |> put_flash(:error, "Invalid email or password.")
        |> redirect(to: "/login")
    end
  end

  def logout(conn, _params) do
    conn
    |> Auth.log_out_user()
    |> redirect(to: "/login")
  end
end
