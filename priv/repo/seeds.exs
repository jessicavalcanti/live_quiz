# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# The work itself lives in `LiveQuiz.DemoSeed`, a compiled module: an assembled
# release has no Mix, so a script gated on `Mix.env()` could not run there at
# all. Asking for the seeds is already an explicit request, so this runs them
# whatever the environment — the `DEMO_SEED` gate is for the release, where
# nobody typed the command.

LiveQuiz.DemoSeed.run!()
