defmodule Counterflow.Repo do
  use Ecto.Repo,
    otp_app: :counterflow,
    adapter: Ecto.Adapters.Postgres
end
