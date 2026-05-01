defmodule CounterflowWeb.LoginLive do
  @moduledoc "Email + password login form."

  use CounterflowWeb, :live_view

  alias Counterflow.Accounts
  alias CounterflowWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :form_data, %{"email" => "", "password" => ""}), layout: false}
  end

  @impl true
  def handle_event("submit", %{"login" => %{"email" => email, "password" => password}}, socket) do
    case Accounts.authenticate(email, password) do
      {:ok, _user} ->
        # Phoenix can't set session from inside a LiveView event handler,
        # so we redirect to a controller endpoint that completes the login.
        {:noreply,
         redirect(socket,
           to:
             "/auth/finish?email=#{URI.encode_www_form(email)}&password=#{URI.encode_www_form(password)}"
         )}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid email or password.")
         |> assign(:form_data, %{"email" => email, "password" => ""})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="min-height: 100dvh; display: grid; place-items: center; background: var(--bg);">
      <div class="cf-panel" style="max-width: 380px; width: 100%; padding: 0;">
        <div class="cf-panel-head">
          <span class="title"><span class="marker"></span>Counterflow · Sign in</span>
        </div>
        <form phx-submit="submit" class="cf-panel-body" style="display: flex; flex-direction: column; gap: 12px;">
          <label class="cf-section-title" style="padding: 0;">Email</label>
          <input type="email" name="login[email]" value={@form_data["email"]} required class="cf-input" autocomplete="username" />

          <label class="cf-section-title" style="padding: 0;">Password</label>
          <input type="password" name="login[password]" required class="cf-input" autocomplete="current-password" />

          <button type="submit" class="cf-btn primary justify-center">Sign in</button>
          <p style="font-size: 11px; color: var(--ink-3); text-align: center;">
            No account? Run <span class="mono">mix counterflow.create_user EMAIL PASSWORD</span>
          </p>
        </form>
      </div>
    </div>
    """
  end
end
