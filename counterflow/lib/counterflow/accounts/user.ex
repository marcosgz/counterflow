defmodule Counterflow.Accounts.User do
  @moduledoc "User schema with bcrypt password hashing."

  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :is_admin, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :is_admin])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/, message: "must be a valid email")
    |> validate_length(:password, min: 8, max: 200)
    |> unique_constraint(:email)
    |> hash_password()
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 200)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end

  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hash)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
