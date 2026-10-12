defmodule LiveQuizWeb.UI do
  @moduledoc """
  The design system of the application: the shadcn/ui component set, ported to
  LiveView by [SaladUI](https://github.com/bluzky/salad_ui) and copied into this
  project rather than depended on.

  Copied is the point. `mix salad.install` generated these modules once, and
  from then on they are ours to edit — a variant we do not want goes away, a
  state this app needs gets added, and no upstream release can move the
  interface under us. The `salad_ui` dependency stays `only: :dev` for that
  reason: it is a generator, not a runtime.

  ## How a component is put together

  Every module here renders with the design tokens declared in
  `assets/css/app.css` — `bg-background`, `text-muted-foreground`,
  `border-input`, `ring-ring` — and never with a literal colour. That is what
  makes the two themes a palette swap instead of a second stylesheet, and it is
  the rule to follow when adding anything.

  Classes come through `classes/1`, which is `TwMerge.merge/1`: the caller's
  `class` wins against the component's default for the same Tailwind property
  instead of both landing in the attribute and the cascade deciding. So
  `<.button class="w-full">` keeps every default and widens, while
  `<.button class="rounded-none">` replaces only the radius.

  ## Where the behaviour lives

  The interactive components (dialog, select, tabs, popover, accordion,
  collapsible, tooltip, hover card, dropdown menu, slider, switch, radio group)
  render the markup and the ARIA wiring on the server, and a state machine in
  `assets/js/ui/` drives them on the client through a single `SaladUI` hook.
  Both halves are required: a component whose JS is not imported in
  `assets/js/app.js` renders correctly and then does nothing.

  ## What is deliberately not here

  `input/1`, `table/1`, `icon/1`, `modal/1` and the flashes stay in
  `LiveQuizWeb.CoreComponents`, which is what Phoenix and this project's
  guidelines point every template at. Those keep their generated contract — a
  `Phoenix.HTML.FormField`, a `LiveStream`, `hero-*` names — and reach for the
  primitives in here for appearance. `use LiveQuizWeb.UI` therefore leaves out
  `UI.Input` entirely and brings `UI.Table` in without its `table/1`, so a
  template never has two components answering to the same name.
  """

  def component do
    quote do
      use Phoenix.Component

      import LiveQuizWeb.UI.Helpers

      alias Phoenix.LiveView.JS

      defp classes(input) do
        TwMerge.merge(List.flatten(input))
      end
    end
  end

  @doc """
  When used, dispatch to the appropriate macro.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  defmacro __using__(_) do
    quote do
      import LiveQuizWeb.UI.Accordion
      import LiveQuizWeb.UI.Alert
      import LiveQuizWeb.UI.AlertDialog
      import LiveQuizWeb.UI.Avatar
      import LiveQuizWeb.UI.Badge
      import LiveQuizWeb.UI.Breadcrumb
      import LiveQuizWeb.UI.Button
      import LiveQuizWeb.UI.Card
      import LiveQuizWeb.UI.Checkbox
      import LiveQuizWeb.UI.Collapsible
      import LiveQuizWeb.UI.Dialog
      import LiveQuizWeb.UI.DropdownMenu
      import LiveQuizWeb.UI.Form
      import LiveQuizWeb.UI.Helpers
      import LiveQuizWeb.UI.HoverCard
      import LiveQuizWeb.UI.Label
      import LiveQuizWeb.UI.Menu
      import LiveQuizWeb.UI.Pagination
      import LiveQuizWeb.UI.Popover
      import LiveQuizWeb.UI.Progress
      import LiveQuizWeb.UI.RadioGroup
      import LiveQuizWeb.UI.ScrollArea
      import LiveQuizWeb.UI.Select
      import LiveQuizWeb.UI.Separator
      import LiveQuizWeb.UI.Sheet
      import LiveQuizWeb.UI.Skeleton
      import LiveQuizWeb.UI.Slider
      import LiveQuizWeb.UI.Switch
      import LiveQuizWeb.UI.Textarea
      import LiveQuizWeb.UI.Tabs
      # `table/1` belongs to `LiveQuizWeb.CoreComponents`, which renders a whole
      # table from `:col` slots and knows about streams. The primitives below are
      # what it builds with.
      import LiveQuizWeb.UI.Table, except: [table: 1]
      import LiveQuizWeb.UI.Toggle
      import LiveQuizWeb.UI.ToggleGroup
      import LiveQuizWeb.UI.Tooltip
    end
  end
end
