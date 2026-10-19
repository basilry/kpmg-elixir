defmodule TickmarkWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TickmarkWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :engagement, :map, default: nil
  attr :active, :atom, default: nil
  attr :presence, :list, default: []

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header id="topbar" class="sticky top-0 z-40 h-12 border-b border-base-300 bg-base-100">
      <div class="mx-auto flex h-full max-w-screen-2xl items-center gap-2 px-4 sm:gap-4 sm:px-6 lg:px-8">
        <.link
          id="topbar-brand"
          href={if @current_scope && @current_scope.user, do: ~p"/engagements", else: ~p"/"}
          class="flex shrink-0 items-center gap-2 font-semibold"
        >
          <span class="flex size-6 items-center justify-center rounded-field bg-primary text-primary-content">
            <.icon name="hero-check-mini" class="size-4" />
          </span>
          <span class="sr-only sm:not-sr-only">Tickmark</span>
        </.link>

        <nav
          :if={@engagement}
          aria-label="감사 대상 메뉴"
          class="flex min-w-0 flex-1 items-center gap-2 sm:gap-4"
        >
          <.link
            id="topbar-engagement"
            navigate={~p"/engagements/#{@engagement.id}"}
            aria-current={@active == :engagement && "page"}
            class={[
              "min-w-0 truncate py-1 hover:text-primary",
              @active == :engagement && "font-semibold text-primary"
            ]}
          >
            {@engagement.client_name} FY{@engagement.fiscal_year}
          </.link>
          <.link
            id="topbar-audit"
            navigate={~p"/engagements/#{@engagement.id}/audit"}
            aria-current={@active == :audit && "page"}
            class={[
              "shrink-0 py-1 hover:text-primary",
              @active == :audit && "font-semibold text-primary"
            ]}
          >
            감사 로그
          </.link>
        </nav>

        <div class="ml-auto flex shrink-0 items-center gap-2 sm:gap-3">
          <div :if={@engagement && @presence != []} id="topbar-presence">
            <div class="flex -space-x-2" aria-hidden="true">
              <span
                :for={person <- Enum.take(@presence, 4)}
                data-presence-id={person.id}
                title={person.name}
                class={[
                  "flex size-6 items-center justify-center rounded-full border-2 border-base-100 bg-base-300 text-xs font-medium",
                  @current_scope && @current_scope.user && person.id == @current_scope.user.id &&
                    "avatar-self bg-primary text-primary-content"
                ]}
              >
                {person.name |> String.first() |> String.upcase()}
              </span>
              <span
                :if={length(@presence) > 4}
                id="topbar-presence-overflow"
                class="flex size-6 items-center justify-center rounded-full border-2 border-base-100 bg-base-300 text-xs tabular-nums"
              >
                +{length(@presence) - 4}
              </span>
            </div>
            <span class="sr-only">지금 보는 사람: {Enum.map_join(@presence, ", ", & &1.name)}</span>
          </div>

          <div id="topbar-theme"><.theme_toggle /></div>

          <details
            :if={@current_scope && @current_scope.user}
            id="topbar-user-menu"
            class="dropdown dropdown-end"
          >
            <summary class="flex cursor-pointer list-none items-center gap-1 rounded-field p-1 hover:bg-base-200">
              <.icon name="hero-user-circle" class="size-5 shrink-0" />
              <span class="sr-only max-w-48 truncate lg:not-sr-only">{@current_scope.user.email}</span>
              <.icon name="hero-chevron-down-micro" class="size-3 shrink-0" />
              <span class="sr-only">사용자 메뉴</span>
            </summary>
            <ul class="dropdown-content mt-2 w-44 space-y-1 rounded-box border border-base-300 bg-base-100 p-2 shadow-md">
              <li>
                <.link
                  href={~p"/users/settings"}
                  class="block rounded-field px-3 py-2 hover:bg-base-200"
                >
                  설정
                </.link>
              </li>
              <li>
                <.link
                  href={~p"/users/log-out"}
                  method="delete"
                  class="block rounded-field px-3 py-2 hover:bg-base-200"
                >
                  로그아웃
                </.link>
              </li>
            </ul>
          </details>

          <nav
            :if={!(@current_scope && @current_scope.user)}
            id="topbar-auth"
            aria-label="계정 메뉴"
            class="flex items-center gap-2"
          >
            <.link href={~p"/users/log-in"} class="link link-hover">로그인</.link>
            <.link href={~p"/users/register"} class="link link-hover">회원가입</.link>
          </nav>
        </div>
      </div>
    </header>

    <main id="main-content" class="mx-auto max-w-screen-2xl px-4 sm:px-6 lg:px-8 py-6">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="인터넷 연결을 찾을 수 없습니다"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        다시 연결하는 중 <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="서버에 문제가 생겼습니다"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        다시 연결하는 중 <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      role="group"
      aria-label="테마"
      class="relative flex items-center rounded-full border border-base-300 bg-base-200"
    >
      <div class="pointer-events-none absolute left-0 h-full w-1/3 rounded-full border border-base-300 bg-base-100 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 motion-safe:transition-[left] motion-safe:duration-150" />

      <button
        type="button"
        class="relative flex size-7 cursor-pointer items-center justify-center rounded-full"
        aria-label="시스템 테마"
        title="시스템 테마"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        type="button"
        class="relative flex size-7 cursor-pointer items-center justify-center rounded-full"
        aria-label="라이트 테마"
        title="라이트 테마"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        type="button"
        class="relative flex size-7 cursor-pointer items-center justify-center rounded-full"
        aria-label="다크 테마"
        title="다크 테마"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
