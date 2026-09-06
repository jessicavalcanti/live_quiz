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

  defp to_local(date_time), do: DateTime.shift_zone!(date_time, @time_zone)

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
