defmodule LiveQuizWeb.Formatters do
  @moduledoc """
  Formats timestamps for the screens.

  Everything is stored in UTC; the conversion to `America/Sao_Paulo` happens
  here, at the presentation edge, and nowhere else. The JSON API keeps
  answering in ISO 8601 UTC and must not use these helpers.
  """

  @time_zone "America/Sao_Paulo"

  @doc """
  Formats a UTC `DateTime` as `dd/mm/yyyy` in São Paulo time.

  ## Examples

      iex> LiveQuizWeb.Formatters.format_date(~U[2026-08-30 02:00:00Z])
      "29/08/2026"

  """
  @spec format_date(DateTime.t()) :: String.t()
  def format_date(%DateTime{} = date_time) do
    local = to_local(date_time)

    "#{pad(local.day)}/#{pad(local.month)}/#{local.year}"
  end

  @doc """
  Formats a UTC `DateTime` as `dd/mm/yyyy hh:mm` in São Paulo time.

  ## Examples

      iex> LiveQuizWeb.Formatters.format_datetime(~U[2026-08-29 22:32:00Z])
      "29/08/2026 19:32"

  """
  @spec format_datetime(DateTime.t()) :: String.t()
  def format_datetime(%DateTime{} = date_time) do
    local = to_local(date_time)

    "#{format_date(date_time)} #{pad(local.hour)}:#{pad(local.minute)}"
  end

  @doc """
  Writes the one line both lobbies show about what is about to be played.

  How many questions there are and how long each one lasts are the only two
  things a room promises before it starts, and they are shown to the host and to
  the participants alike (F3-07). The plural of "pergunta" is the detail worth
  spelling out; the durations on offer are all plural, so "segundos" is not.

  ## Examples

      iex> LiveQuizWeb.Formatters.format_match_setup(10, 30)
      "10 perguntas · 30 segundos por pergunta"

      iex> LiveQuizWeb.Formatters.format_match_setup(1, 60)
      "1 pergunta · 60 segundos por pergunta"

  """
  @spec format_match_setup(non_neg_integer(), pos_integer()) :: String.t()
  def format_match_setup(question_count, duration_seconds)
      when is_integer(question_count) and is_integer(duration_seconds) do
    "#{questions(question_count)} · #{duration_seconds} segundos por pergunta"
  end

  @doc """
  Writes a number of seconds as the `m:ss` the host reads off the projection.

  It draws the first frame of the countdown and nothing else: the number comes
  from `seconds_left`, which ages the instant it is rendered (AD-39), and from
  there on the hook redraws the same element against the absolute deadline.

  ## Examples

      iex> LiveQuizWeb.Formatters.format_countdown(22)
      "0:22"

      iex> LiveQuizWeb.Formatters.format_countdown(60)
      "1:00"

      iex> LiveQuizWeb.Formatters.format_countdown(0)
      "0:00"

  """
  @spec format_countdown(non_neg_integer()) :: String.t()
  def format_countdown(seconds) when is_integer(seconds) and seconds >= 0 do
    "#{div(seconds, 60)}:#{pad(rem(seconds, 60))}"
  end

  @doc """
  The letter an alternative is shown with, from its position.

  Position `1` is `A`, and the four alternatives of a question never go past
  `D`. Three screens label the same alternatives — the host's, the player's and
  the reveal — and a letter that disagreed between them would be a room reading
  out an answer nobody else can see.
  """
  @spec option_letter(pos_integer()) :: String.t()
  def option_letter(position) when is_integer(position) and position > 0,
    do: <<?A + position - 1>>

  @doc "Formats a score with the pt-BR thousands separator."
  @spec format_score(non_neg_integer()) :: String.t()
  def format_score(score) when is_integer(score) and score >= 0 do
    score
    |> Integer.to_string()
    |> String.replace(~r/(?<=\d)(?=(\d{3})+$)/, ".")
    |> then(&"#{&1} pontos")
  end

  @doc "Formats the number of correct answers in a ranking row."
  @spec format_correct_answers(non_neg_integer()) :: String.t()
  def format_correct_answers(answers) when is_integer(answers) and answers >= 0 do
    "#{answers} #{if answers == 1, do: "acerto", else: "acertos"}"
  end

  @doc "Formats a response time in milliseconds for the final result."
  @spec format_response_time(non_neg_integer()) :: String.t()
  def format_response_time(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    seconds = milliseconds / 1000
    :erlang.float_to_binary(seconds, decimals: 1) <> " s"
  end

  @doc """
  Writes how many people let a question go by without answering.

  It is only ever shown when there is somebody to count (F3-10): the absence of
  absences is not news, and a screen saying "0 pessoas não responderam" would
  make the reader look for a number that means nothing.

  ## Examples

      iex> LiveQuizWeb.Formatters.format_absences(3)
      "3 pessoas não responderam"

      iex> LiveQuizWeb.Formatters.format_absences(1)
      "1 pessoa não respondeu"

  """
  @spec format_absences(non_neg_integer()) :: String.t()
  def format_absences(1), do: "1 pessoa não respondeu"

  def format_absences(count) when is_integer(count) and count >= 0,
    do: "#{count} pessoas não responderam"

  @doc """
  The share of the answers an alternative took, as a whole percentage.

  The denominator is who answered, never who was in the room (AD-43): mixing the
  absences in would make the most voted alternative look less voted than it was.
  A question nobody answered has no share to speak of and answers zero, which is
  also what keeps the bar from dividing by zero.

  ## Examples

      iex> LiveQuizWeb.Formatters.answer_share(15, 22)
      68

      iex> LiveQuizWeb.Formatters.answer_share(0, 0)
      0

  """
  @spec answer_share(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def answer_share(_count, 0), do: 0

  def answer_share(count, total) when is_integer(count) and is_integer(total) and total > 0,
    do: round(count / total * 100)

  @doc """
  Writes the count and the share of an alternative, for the bar to be read aloud.

  A bar drawn only with a width in CSS says nothing to a screen reader, so the
  same value it draws is written next to it, in words a person hears.

  ## Examples

      iex> LiveQuizWeb.Formatters.format_answer_share(15, 22)
      "15 respostas · 68%"

      iex> LiveQuizWeb.Formatters.format_answer_share(1, 22)
      "1 resposta · 5%"

      iex> LiveQuizWeb.Formatters.format_answer_share(0, 0)
      "0 respostas · 0%"

  """
  @spec format_answer_share(non_neg_integer(), non_neg_integer()) :: String.t()
  def format_answer_share(count, total) do
    "#{answers(count)} · #{answer_share(count, total)}%"
  end

  @doc """
  Writes how much of the match was actually played, for the ending screen.

  A match finished on question 4 of 10 applied four questions, and that is the
  whole of what the ending screen has to say about the numbers: score, position
  and ranking are phase 4.

  ## Examples

      iex> LiveQuizWeb.Formatters.format_questions_played(4, 10)
      "Perguntas aplicadas: 4 de 10"

      iex> LiveQuizWeb.Formatters.format_questions_played(10, 10)
      "Perguntas aplicadas: 10 de 10"

  """
  @spec format_questions_played(non_neg_integer(), non_neg_integer()) :: String.t()
  def format_questions_played(played, total)
      when is_integer(played) and is_integer(total) do
    "Perguntas aplicadas: #{played} de #{total}"
  end

  defp answers(1), do: "1 resposta"
  defp answers(count), do: "#{count} respostas"

  defp questions(1), do: "1 pergunta"
  defp questions(count), do: "#{count} perguntas"

  defp to_local(date_time), do: DateTime.shift_zone!(date_time, @time_zone)

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
