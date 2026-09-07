defmodule LiveQuiz.Games.Telemetry do
  @moduledoc """
  What a match tells whoever is watching it from outside.

  The domain already logged failures, and a log is where an incident is
  reconstructed *afterwards*. What was missing is the part that lets somebody
  notice while it is happening: a question closed and never scored, a
  reconciliation that keeps finding work, a closing that arrives a minute after
  its deadline (R44). Those are events, not sentences.

  Every event here carries **bounded** metadata. A room id or an account id as a
  metric dimension is a new time series per room, which is how a metrics backend
  is taken down by a busy afternoon; ids belong in the structured log next to
  the event, and this module never puts a token or a nickname in either.

  ## Events

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:live_quiz, :games, :transition, :stop]` | `duration` | `command`, `result`, `reason` |
  | `[:live_quiz, :games, :consolidation, :stop]` | `duration` | `result`, `reason`, `scored` |
  | `[:live_quiz, :games, :question, :closed]` | `delay_ms` | `origin` |
  | `[:live_quiz, :games, :reconciliation, :stop]` | `duration`, plus the pass's own counts | `kind`, `result` |

  `delay_ms` is how late a question was closed against the deadline it carried,
  which is the number that says whether the timers are keeping up. `command`,
  `origin` and `kind` come from fixed sets named in this module, so the label
  cardinality of the whole domain is a constant.

  Nothing here decides anything. A consumer — the LiveDashboard, a reporter, a
  collector the team picks — attaches to these names; the domain only says what
  happened.
  """

  @prefix [:live_quiz, :games]

  @commands ~w(start advance close finish cancel expire answer join rejoin leave)a
  @origins ~w(host timeout everybody_answered advance finish)a
  @kinds ~w(question_timer host_absence expiration)a

  @doc "The commands `transition/3` labels, as a fixed set."
  @spec commands() :: [atom()]
  def commands, do: @commands

  @doc "The ways a question can be closed, as a fixed set."
  @spec origins() :: [atom()]
  def origins, do: @origins

  @doc "The periodic passes `reconciliation/3` labels, as a fixed set."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Times a command that moves a match and reports how it ended.

  The result travels as `:ok` or `:error` with the reason, so a dashboard can
  separate "the host clicked twice" from "the database refused the write"
  without a dimension per room.
  """
  @spec transition(atom(), (-> result)) :: result when result: term()
  def transition(command, fun) when command in @commands and is_function(fun, 0) do
    span([:transition], %{command: command}, fun)
  end

  @doc """
  Times the consolidation of one question.

  `scored` tells apart the call that did the writing from the ones that read the
  same standing back: a room where nothing is ever scored and everything is read
  back is a room whose questions are being consolidated somewhere else.
  """
  @spec consolidation((-> result)) :: result when result: term()
  def consolidation(fun) when is_function(fun, 0) do
    span([:consolidation], %{}, fun, &consolidation_metadata/1)
  end

  @doc """
  Reports how late a question was closed against its own deadline.

  Zero is the deadline met exactly; a growing number is the timers falling
  behind, which is the failure R19 exists to bound and the one nothing was
  measuring. A question closed by the host before its deadline reports no delay
  at all — being early is not lateness.
  """
  @spec question_closed(atom(), DateTime.t() | nil, DateTime.t() | nil) :: :ok
  def question_closed(origin, ends_at, closed_at) when origin in @origins do
    :telemetry.execute(
      @prefix ++ [:question, :closed],
      %{delay_ms: delay_ms(ends_at, closed_at)},
      %{origin: origin}
    )
  end

  @doc """
  Times one pass of a periodic reconciliation and carries what it settled.

  The counts are the measurements, so "this pass repaired eleven rooms" is a
  number somebody can alert on rather than a line somebody has to read.
  """
  @spec reconciliation(atom(), (-> map())) :: map()
  def reconciliation(kind, fun) when kind in @kinds and is_function(fun, 0) do
    span([:reconciliation], %{kind: kind}, fun, &reconciliation_metadata/1)
  end

  defp span(suffix, metadata, fun, extra \\ &default_metadata/1) do
    start = System.monotonic_time()
    result = fun.()

    :telemetry.execute(
      @prefix ++ suffix ++ [:stop],
      measurements(System.monotonic_time() - start, result),
      Map.merge(metadata, extra.(result))
    )

    result
  end

  defp measurements(duration, %{} = counts) do
    counts
    |> Map.take([:closed, :armed, :opened, :cleared, :expired])
    |> Map.put(:duration, duration)
  end

  defp measurements(duration, _result), do: %{duration: duration}

  defp default_metadata({:ok, _value}), do: %{result: :ok, reason: nil}
  defp default_metadata(:ok), do: %{result: :ok, reason: nil}

  defp default_metadata({:error, reason}) when is_atom(reason),
    do: %{result: :error, reason: reason}

  # A changeset, a struct, anything that is not one of the domain's atoms: the
  # dimension stays bounded and the detail stays in the log.
  defp default_metadata({:error, _other}), do: %{result: :error, reason: :invalid}
  defp default_metadata(_other), do: %{result: :ok, reason: nil}

  defp consolidation_metadata({:ok, %{scored?: scored?}}) do
    %{result: :ok, reason: nil, scored: scored?}
  end

  defp consolidation_metadata(other), do: Map.put(default_metadata(other), :scored, false)

  defp reconciliation_metadata(%{}), do: %{result: :ok, reason: nil}

  defp delay_ms(%DateTime{} = ends_at, %DateTime{} = closed_at) do
    closed_at |> DateTime.diff(ends_at, :millisecond) |> max(0)
  end

  defp delay_ms(_ends_at, _closed_at), do: 0
end
