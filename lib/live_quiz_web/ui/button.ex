defmodule LiveQuizWeb.UI.Button do
  @moduledoc """
  Button component for user interactions.

  Provides a versatile button component with various styles, sizes, and states
  to handle user interactions throughout the application.
  """
  use LiveQuizWeb.UI, :component

  @doc """
  Renders a button with configurable styles and behaviors.

  Passing `navigate`, `patch` or `href` renders a `Phoenix.Component.link/1`
  wearing the same clothes, because an action that changes the address deserves
  an anchor: it opens in a new tab on a middle click and reads as a link to a
  screen reader. A `<button>` painted to look like one does neither.

  ## Attributes

  * `:type` - HTML button type attribute (e.g., "button", "submit")
  * `:class` - Additional CSS classes
  * `:variant` - Visual style variant of the button:
      * `"default"` - Primary action button
      * `"secondary"` - Secondary action button
      * `"destructive"` - Buttons for destructive actions
      * `"outline"` - Button with outline style
      * `"ghost"` - Button with minimal styling
      * `"link"` - Button that appears as a link
  * `:size` - Size of the button:
      * `"default"` - Standard size
      * `"sm"` - Small size
      * `"lg"` - Large size
      * `"icon"` - Square button optimized for icons
  * `:rest` - Additional HTML attributes including `disabled`, `form`, `name`,
    `value`, and the `navigate`, `patch`, `href`, `method` and `download`
    attributes of `Phoenix.Component.link/1`

  ## Examples

      <.button>Send</.button>
      <.button variant="destructive" phx-click="delete">Delete</.button>
      <.button variant="outline" size="sm">Cancel</.button>
      <.button variant="ghost" size="icon">
        <.icon name="hero-x-mark" />
      </.button>
      <.button type="submit" phx-disable-with="Saving...">Save Changes</.button>
      <.button navigate={~p"/quizzes"}>Meus quizzes</.button>
  """
  attr :type, :string, default: nil
  attr :class, :any, default: nil

  attr :variant, :string,
    values: ~w(default secondary destructive outline ghost link),
    default: "default",
    doc: "the button variant style"

  attr :size, :string, values: ~w(default sm lg icon), default: "default"

  attr :rest, :global, include: ~w(disabled download form href method name navigate patch value)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :variant_class, button_variant(assigns))

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link
        class={
          classes([
            "phx-submit-loading:opacity-75",
            @variant_class,
            @class
          ])
        }
        {@rest}
      >
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button
        type={@type}
        class={
          classes([
            "phx-submit-loading:opacity-75",
            @variant_class,
            @class
          ])
        }
        {@rest}
      >
        {render_slot(@inner_block)}
      </button>
      """
    end
  end
end
