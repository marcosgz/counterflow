defmodule Mix.Tasks.Counterflow.CreateUser do
  @shortdoc "Create a Counterflow user from the command line."
  @moduledoc """
  Usage: `mix counterflow.create_user EMAIL PASSWORD [--admin]`

  Creates a user record in the local DB. The first user becomes the
  default owner (Counterflow.Accounts.owner/0). Re-runs are idempotent
  by email; existing users are reported and skipped.
  """

  use Mix.Task
  alias Counterflow.Accounts

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: [admin: :boolean])

    case positional do
      [email, password] ->
        Mix.Task.run("app.start")

        case Accounts.register_user(email, password, is_admin: !!opts[:admin]) do
          {:ok, user} ->
            Mix.shell().info("✓ User #{user.email} (id=#{user.id}) created")

          {:error, changeset} ->
            Mix.shell().error("Failed: #{inspect(changeset.errors)}")
            exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error("usage: mix counterflow.create_user EMAIL PASSWORD [--admin]")
        exit({:shutdown, 1})
    end
  end
end
