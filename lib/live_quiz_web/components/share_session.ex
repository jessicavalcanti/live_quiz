defmodule LiveQuizWeb.ShareSession do
  @moduledoc """
  The block a host projects so people can find the room: code, link and QR code.

  The three are the same address said in three ways, because the three ways
  people arrive are different — someone hears the code across a room, someone
  gets the link in a message, someone points a camera at a wall. All of them
  land on `/join?code=CODE`, which fills in the code and asks only for a
  nickname.

  The QR code is drawn here, on the server, with `eqrcode` (AD-33): no external
  service is called, no file is stored and nothing costs anything per room. It
  is inline SVG so it stays sharp at whatever size a projector gives it, and it
  is wrapped in a white frame that is its quiet zone — a QR code printed flush
  against its border is one a camera refuses to read.

  Copying happens in the browser, where the clipboard is, and the buttons also
  announce `"copy_code"` and `"copy_link"` to the LiveView holding the block, so
  the confirmation is a server-rendered message rather than something only the
  hook could have said. A parent that renders this block handles both events.
  """

  use Phoenix.Component

  import LiveQuizWeb.CoreComponents, only: [icon: 1]

  alias LiveQuiz.Games.JoinCode
  alias Phoenix.HTML

  # Four modules of silence around the symbol, as the QR specification asks.
  @quiet_zone 4
  @xml_prolog ~r|\A\s*<\?xml.*?\?>\s*|s

  attr :code, :string, required: true
  attr :url, :string, required: true
  attr :class, :string, default: nil

  @doc """
  Renders the join code, a button that copies the link and the QR code of it.
  """
  def share_session(assigns) do
    assigns = assign(assigns, :qr_code, qr_code_svg(assigns.url))

    ~H"""
    <section
      id="share-session"
      aria-labelledby="share-session-title"
      class={["rounded-2xl border border-base-300 p-8 text-center", @class]}
    >
      <h2
        id="share-session-title"
        class="text-sm font-semibold tracking-[0.35em] text-base-content/70 uppercase"
      >
        Código da sala
      </h2>

      <p
        id="join-code"
        class="mt-4 font-mono text-6xl font-black tracking-[0.25em] break-all sm:text-8xl"
      >
        {@code}
      </p>

      <div class="mt-6 flex flex-col items-center gap-3">
        <p id="join-url" class="max-w-full text-sm break-all text-base-content/70">{@url}</p>

        <div class="flex flex-wrap justify-center gap-2">
          <button
            type="button"
            id="copy-code"
            phx-click="copy_code"
            phx-hook=".CopyToClipboard"
            data-value={@code}
            class="btn btn-soft btn-sm"
          >
            <.icon name="hero-clipboard-document" class="size-4" /> Copiar código
          </button>

          <button
            type="button"
            id="copy-link"
            phx-click="copy_link"
            phx-hook=".CopyToClipboard"
            data-value={@url}
            class="btn btn-soft btn-sm"
          >
            <.icon name="hero-link" class="size-4" /> Copiar link
          </button>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const value = this.el.dataset.value
                if (navigator.clipboard) { navigator.clipboard.writeText(value) }
              })
            }
          }
        </script>
      </div>

      <figure class="mt-8 flex flex-col items-center gap-3">
        <div
          id="join-qr-code"
          role="img"
          aria-label={"QR code com o link de entrada da sala #{@code}"}
          class="w-48 rounded-xl bg-white p-3 sm:w-56"
        >
          {@qr_code}
        </div>

        <figcaption class="text-sm text-base-content/70">
          Aponte a câmera para entrar em {@code}.
        </figcaption>
      </figure>
    </section>
    """
  end

  @doc """
  The address the code, the link and the QR code all point at.

  Absolute, because it is read off a projector and typed into another device.
  """
  @spec join_url(String.t()) :: String.t()
  def join_url(code) when is_binary(code) do
    "#{LiveQuizWeb.Endpoint.url()}/join?code=#{JoinCode.normalize(code)}"
  end

  @doc """
  Draws `url` as an inline SVG QR code, with the quiet zone the readers need.

  `eqrcode` emits a standalone document sized to the symbol itself. The XML
  prolog has to go before the markup can be inlined in HTML, and the viewBox is
  widened by #{@quiet_zone} modules on every side so the frame around the symbol
  is part of the image rather than a hope about the surrounding layout.
  """
  @spec qr_code_svg(String.t()) :: HTML.safe()
  def qr_code_svg(url) when is_binary(url) do
    url
    |> EQRCode.encode()
    |> EQRCode.svg(viewbox: true, color: "#000", background_color: "#FFF")
    |> String.replace(@xml_prolog, "")
    |> add_quiet_zone()
    |> HTML.raw()
  end

  defp add_quiet_zone(svg) do
    case Regex.run(~r/viewBox="0 0 (\d+) (\d+)"/, svg) do
      [match, width, height] ->
        outer_width = String.to_integer(width) + 2 * @quiet_zone
        outer_height = String.to_integer(height) + 2 * @quiet_zone

        String.replace(
          svg,
          match,
          ~s(viewBox="-#{@quiet_zone} -#{@quiet_zone} #{outer_width} #{outer_height}") <>
            ~s( class="h-auto w-full")
        )

      nil ->
        svg
    end
  end
end
