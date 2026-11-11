# inferno-runner (private)

Self-updating build loop for the Inferno guest-image build.

- `build.sh` — the build script (kept current remotely).
- `runner.sh` — runs on the Mac: pulls this repo, runs `build.sh`, waits for
  it to finish, collects the logs (Terminal output, guest serial, panic
  snapshots, companion restore log) and pushes them back here, then repeats
  until `~/InfernoMacBuild/InfernoData.zip` exists.
- `state.txt` — one-line status of the latest run (SUCCESS / FAILED /
  NEEDS-HUMAN), written by the runner.
- `logs/` — one set per run, pushed by the runner.
- A file named `STOP` in the repo root stops the runner at its next check.

Private because the logs contain local paths and the machine's username.
