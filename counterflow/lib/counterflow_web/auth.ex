defmodule CounterflowWeb.Auth do
  @moduledoc """
  Session-based auth helpers. log_in_user/2 writes user_id into the session;
  fetch_current_user/2 reads it back; require_authenticated_user/2 redirects
  to /login when missing.

  Uses Counterflow.Accounts for the actual identity check + bcrypt verify.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Counterflow.Accounts

  def log_in_user(conn, user) do
    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
  end

  def log_out_user(conn) do
    conn
    |> configure_session(drop: true)
  end

  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :user_id)
    user = user_id && Accounts.get_user(user_id)
    assign(conn, :current_user, user)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> redirect(to: "/login")
      |> halt()
    end
  end

  # LiveView mount-time hook: looks up the current user from the session
  # and assigns it on the socket. Pages use `on_mount {Auth, :ensure_authenticated}`
  def on_mount(:ensure_authenticated, _params, session, socket) do
    user = session["user_id"] && Accounts.get_user(session["user_id"])

    if user do
      {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Please sign in.")
       |> Phoenix.LiveView.redirect(to: "/login")}
    end
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
