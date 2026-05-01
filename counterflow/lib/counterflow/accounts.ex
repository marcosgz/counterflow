defmodule Counterflow.Accounts do
  @moduledoc """
  User account management. Single-owner deployments are the common case;
  the `owner/0` helper returns the first registered user (creating one
  from `COUNTERFLOW_OWNER_EMAIL` + `COUNTERFLOW_OWNER_PASSWORD` env vars
  on boot if none exist), so the rest of the app can treat data as
  belonging to "the owner" without per-LiveView session plumbing.

  Multi-user is supported at the data layer (every per-user table has
  user_id FK), so scope-by-current_user is a wiring exercise away.
  """

  import Ecto.Query
  alias Counterflow.{Repo, Accounts.User}

  @spec register_user(String.t(), String.t(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(email, password, opts \\ []) do
    %User{}
    |> User.registration_changeset(%{
      email: email,
      password: password,
      is_admin: Keyword.get(opts, :is_admin, false)
    })
    |> Repo.insert()
  end

  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid}
  def authenticate(email, password) do
    case Repo.get_by(User, email: email) do
      nil ->
        User.valid_password?(nil, password)
        {:error, :invalid}

      user ->
        if User.valid_password?(user, password), do: {:ok, user}, else: {:error, :invalid}
    end
  end

  @spec get_user(integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from u in User, order_by: [asc: u.id])

  @doc """
  Returns the owner user, auto-creating one from env vars on first boot.
  Used as the default scope for non-multi-user code paths.
  """
  @spec owner() :: User.t() | nil
  def owner do
    case Repo.one(from u in User, order_by: [asc: u.id], limit: 1) do
      %User{} = u ->
        u

      nil ->
        with email when is_binary(email) and email != "" <- System.get_env("COUNTERFLOW_OWNER_EMAIL"),
             pass when is_binary(pass) and byte_size(pass) >= 8 <- System.get_env("COUNTERFLOW_OWNER_PASSWORD"),
             {:ok, user} <- register_user(email, pass, is_admin: true) do
          user
        else
          _ -> nil
        end
    end
  end

  @doc "Convenience: owner user_id, or nil if no owner exists yet."
  def owner_id do
    case owner() do
      %User{id: id} -> id
      _ -> nil
    end
  end
end
