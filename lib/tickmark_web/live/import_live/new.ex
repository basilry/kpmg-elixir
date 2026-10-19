defmodule TickmarkWeb.ImportLive.New do
  @moduledoc "S3: upload a CSV or generate a reproducible synthetic GL."
  use TickmarkWeb, :live_view

  import TickmarkWeb.EngagementLive.Components, only: [fiscal_year_label: 1]
  import TickmarkWeb.ImportLive.Components

  alias Tickmark.{Engagements, Ledger}
  alias Tickmark.Ledger.Generator

  # Ledger.create_import/3 checks this same limit again before copying the file.
  @max_file_bytes 20_000_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    engagement = Engagements.get_engagement!(scope, id)
    can_import = match?({:ok, _role}, Engagements.authorize(scope, id, :import_ledger))

    if connected?(socket), do: Engagements.subscribe(scope, engagement.id)

    {:ok,
     socket
     |> assign(
       page_title: "GL 불러오기",
       engagement: engagement,
       can_import: can_import,
       source: "upload",
       ledger_import: nil,
       upload_form: to_form(%{}, as: :upload),
       seed_form: seed_form(""),
       default_seed: Generator.default_seed()
     )
     |> allow_upload(:ledger, accept: ~w(.csv), max_entries: 1, max_file_size: @max_file_bytes)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    source = if params["source"] == "generated", do: "generated", else: "upload"
    {:noreply, assign(socket, :source, source)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :ledger, ref)}

  def handle_event("save", _params, socket) do
    %{current_scope: scope, engagement: engagement} = socket.assigns

    with {:ok, _role} <- Engagements.authorize(scope, engagement.id, :import_ledger),
         {[_entry], []} <- uploaded_entries(socket, :ledger),
         [] <- upload_errors(socket.assigns.uploads.ledger) do
      results =
        consume_uploaded_entries(socket, :ledger, fn %{path: path}, entry ->
          # The context copies the file while the upload's temporary file exists.
          {:ok,
           Ledger.create_import(scope, engagement, %{path: path, filename: entry.client_name})}
        end)

      [result] = results
      {:noreply, show_result(socket, result)}
    else
      {:error, :forbidden} -> {:noreply, show_result(socket, {:error, :forbidden})}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("generate", %{"sample" => %{"seed" => value}}, socket) do
    %{current_scope: scope, engagement: engagement} = socket.assigns

    with {:ok, _role} <- Engagements.authorize(scope, engagement.id, :import_ledger),
         {:ok, seed} <- parse_seed(value) do
      result = Ledger.generate_sample_import(scope, engagement, seed: seed)
      {:noreply, socket |> assign(:seed_form, seed_form(value)) |> show_result(result)}
    else
      {:error, :invalid_seed} ->
        {:noreply, assign(socket, :seed_form, seed_form(value, seed: {"정수로 입력하세요.", []}))}

      {:error, :forbidden} ->
        {:noreply, show_result(socket, {:error, :forbidden})}
    end
  end

  @impl true
  def handle_info({:import_updated, %{import_id: id}}, socket) do
    case socket.assigns.ledger_import do
      %{id: ^id} ->
        {:noreply,
         assign(socket, :ledger_import, Ledger.get_import!(socket.assigns.current_scope, id))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:test_run_updated, _payload}, socket), do: {:noreply, socket}
  def handle_info({:finding_updated, _payload}, socket), do: {:noreply, socket}
  def handle_info({:audit_appended, _payload}, socket), do: {:noreply, socket}

  defp seed_form(value, errors \\ []),
    do: to_form(%{"seed" => value}, as: :sample, errors: errors)

  defp parse_seed(value) do
    case String.trim(value) do
      "" ->
        {:ok, Generator.default_seed()}

      value ->
        case Integer.parse(value) do
          {seed, ""} -> {:ok, seed}
          _ -> {:error, :invalid_seed}
        end
    end
  end

  defp show_result(socket, {:ok, ledger_import}),
    do: assign(socket, :ledger_import, ledger_import)

  defp show_result(socket, {:error, :forbidden}),
    do: put_flash(socket, :error, "GL을 불러올 권한이 없습니다.")

  defp show_result(socket, {:error, :file_too_large}),
    do: put_flash(socket, :error, upload_error(:too_large))

  defp show_result(socket, {:error, _reason}),
    do: put_flash(socket, :error, "파일을 처리하지 못했습니다. 같은 파일을 다시 올려 주세요. 계속 실패하면 관리자에게 알려 주세요.")

  defp upload_error(:too_large), do: "20MB보다 큰 파일은 올릴 수 없습니다."
  defp upload_error(:not_accepted), do: ".csv 파일만 올릴 수 있습니다."
  defp upload_error(:too_many_files), do: "파일은 한 번에 1개만 올릴 수 있습니다."
  defp upload_error(_reason), do: "파일을 올리지 못했습니다. 다시 선택해 주세요."

  defp upload_disabled?(upload), do: upload.entries == [] or upload.errors != []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="s3" class="space-y-6">
        <header id="s3-main-1" class="space-y-1">
          <nav aria-label="이동 경로" class="text-sm text-muted">
            <.link navigate={~p"/engagements"} class="link link-hover">감사 대상</.link>
            <span aria-hidden="true">/</span>
            <.link navigate={~p"/engagements/#{@engagement}"} class="link link-hover">
              {@engagement.client_name} {fiscal_year_label(@engagement.fiscal_year)}
            </.link>
            <span aria-hidden="true">/</span><span>GL 불러오기</span>
          </nav>
          <h1 class="text-xl font-semibold">GL 불러오기</h1>
        </header>

        <div :if={!@can_import} id="s3-forbidden" role="alert" class="alert alert-error">
          <.icon name="hero-lock-closed" /> GL을 불러올 권한이 없습니다.
        </div>

        <div :if={@can_import} id="s3-main" class="space-y-6">
          <nav id="s3-main-2" class="tabs tabs-border" aria-label="적재 방식">
            <.link
              id="s3-tab-upload"
              patch={~p"/engagements/#{@engagement}/imports/new?source=upload"}
              class={["tab", @source == "upload" && "tab-active"]}
              aria-current={@source == "upload" && "page"}
            >
              <.icon name="hero-arrow-up-tray" class="mr-1 size-4" /> CSV 업로드
            </.link>
            <.link
              id="s3-tab-generated"
              patch={~p"/engagements/#{@engagement}/imports/new?source=generated"}
              class={["tab", @source == "generated" && "tab-active"]}
              aria-current={@source == "generated" && "page"}
            >
              <.icon name="hero-document-text" class="mr-1 size-4" /> 합성 GL 생성
            </.link>
          </nav>

          <.form
            hidden={@source != "upload"}
            for={@upload_form}
            id="s3-upload-form"
            phx-change="validate"
            phx-submit="save"
            aria-label="CSV 업로드"
            class="space-y-4 rounded-box border border-base-300 bg-base-100 p-4"
          >
            <div
              id="s3-main-3"
              phx-drop-target={@uploads.ledger.ref}
              class="flex flex-col items-center gap-2 rounded-box border border-dashed border-line-strong p-6"
            >
              <.icon name="hero-arrow-up-tray" class="size-8 text-muted" />
              <label for={@uploads.ledger.ref} class="font-medium">CSV 파일을 끌어 놓거나 선택</label>
              <span class="text-xs text-muted">.csv 1개, 20MB, 100,000행까지</span>
              <.live_file_input
                upload={@uploads.ledger}
                class="file-input file-input-sm w-full max-w-sm"
              />
            </div>
            <p id="s3-main-4" class="text-xs text-muted">
              컬럼 16개는 이름으로 찾으므로 순서는 상관없습니다. UTF-8(BOM 허용), 쉼표 구분, 금액은 원 단위 정수입니다.
            </p>
            <div
              :for={entry <- @uploads.ledger.entries}
              id={"s3-upload-#{entry.ref}"}
              class="space-y-2"
            >
              <div class="flex items-center justify-between gap-2 text-sm">
                <span class="font-mono break-all">{entry.client_name}</span>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  aria-label={"#{entry.client_name} 선택 취소"}
                >
                  <.icon name="hero-x-mark" />
                </button>
              </div>
              <progress
                class="progress progress-primary"
                value={entry.progress}
                max="100"
                aria-label="업로드 진행률"
              >{entry.progress}%</progress>
              <p
                :for={error <- upload_errors(@uploads.ledger, entry)}
                role="alert"
                class="text-sm text-error"
              >
                {upload_error(error)}
              </p>
            </div>
            <p :for={error <- upload_errors(@uploads.ledger)} role="alert" class="text-sm text-error">
              {upload_error(error)}
            </p>
            <div id="s3-main-5" class="flex flex-wrap items-center justify-end gap-2">
              <span :if={upload_disabled?(@uploads.ledger)} id="s3-why" class="text-xs text-muted">
                파일을 선택하면 업로드할 수 있습니다
              </span>
              <.button
                id="s3-upload-button"
                class="btn btn-sm btn-primary"
                disabled={upload_disabled?(@uploads.ledger)}
                aria-describedby={upload_disabled?(@uploads.ledger) && "s3-why"}
                phx-disable-with="업로드 중"
              >
                업로드
              </.button>
            </div>
          </.form>

          <.form
            hidden={@source != "generated"}
            for={@seed_form}
            id="s3-gen"
            phx-submit="generate"
            aria-label="합성 GL 생성"
            class="space-y-4 rounded-box border border-base-300 bg-base-100 p-4"
          >
            <div id="s3-gen-1" class="max-w-60">
              <.input
                field={@seed_form[:seed]}
                type="text"
                label="시드 (정수)"
                inputmode="numeric"
                placeholder={@default_seed}
                aria-describedby="s3-seed-help"
              />
              <p id="s3-seed-help" class="text-xs text-muted">비우면 {@default_seed}</p>
            </div>
            <p id="s3-gen-2" class="text-xs text-muted">
              같은 시드면 같은 GL이 나옵니다. 룰 테스트의 기대 건수는 시드 {@default_seed} 기준입니다.
            </p>
            <.button id="s3-gen-3" class="btn btn-sm" phx-disable-with="생성 중">생성</.button>
          </.form>

          <.import_result
            :if={@ledger_import}
            ledger_import={@ledger_import}
            engagement={@engagement}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
