defmodule LiveQuizWeb.Telemetry.Alerts do
  @moduledoc """
  The events that must reach the log even when no collector is listening.

  Metrics need a reporter, and which reporter is a deployment's decision — so
  until one is configured, `LiveQuizWeb.Telemetry.metrics/0` describes numbers
  that nobody reads. For most of them that is fine: nobody is paged because a
  match took 4ms.

  Two are not fine, because they are silent by construction and they mean
  somebody is not getting something they asked for:

    * **a message dropped for expiring** — the link it carried died before the
      message went out, so a person never received their confirmation or their
      reset, and the outbox row is gone. `exhausted` already logs; this one had
      nothing at all.
    * **the rate limiter overflowing** — it stopped limiting, deliberately, so
      that memory pressure would not become an outage. That decision is only
      defensible if somebody finds out it happened.

  A third is a misconfiguration worth shouting about rather than a failure:
  forwarded headers that do not match the declared topology, which
  `LiveQuizWeb.RateLimit` already logs at the point of decision and which is
  counted here so the volume is visible.

  Nothing here logs a body, an address or a token: what identifies the event is
  the flow it belongs to, and that is all that is written.
  """

  require Logger

  @handler "live-quiz-telemetry-alerts"

  @events [
    [:live_quiz, :mail, :expired],
    [:live_quiz, :rate_limit, :overflow]
  ]

  @doc """
  Attaches the handler. Idempotent, so a restart of the supervisor is harmless.
  """
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler)
    :telemetry.attach_many(@handler, @events, &__MODULE__.handle/4, nil)
  end

  @doc "The events this module escalates to the log."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc false
  def handle([:live_quiz, :mail, :expired], _measurements, %{kind: kind}, _config) do
    Logger.error(
      "a #{kind} email was dropped: the link it carried expired before it was delivered. " <>
        "Nobody received it, and nothing will retry."
    )
  end

  def handle([:live_quiz, :rate_limit, :overflow], _measurements, %{bucket: bucket}, _config) do
    Logger.error(
      "the rate limiter stopped counting #{bucket}: it is holding as many keys as it will. " <>
        "Requests are being let through on purpose — a limiter that turns memory pressure " <>
        "into an outage has become the attack — but nothing is being limited right now."
    )
  end
end
