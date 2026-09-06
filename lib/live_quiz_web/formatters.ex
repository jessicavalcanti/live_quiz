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

  defp questions(1), do: "1 pergunta"
  defp questions(count), do: "#{count} perguntas"

  defp to_local(date_time), do: DateTime.shift_zone!(date_time, @time_zone)

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
