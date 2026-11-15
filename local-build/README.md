# Building Loop on your own Mac

This folder adds two ways to build Loop and upload it to TestFlight on a headless Mac
instead of GitHub's machines. Pick one.

| File | What it is |
| --- | --- |
| `loop-build.sh` | The fully local build script (Option A). Run `loop-build.sh help` for all commands. |
| `loop-build.conf.example` | Settings and secrets template for `~/.config/loop-build/config`. |
| `com.loopbuild.auto.plist` | LaunchDaemon that runs `loop-build.sh auto` weekly with nobody logged in. |
| `patches/` | Patches `loop-build.sh` applies before each build (see below). |
| `com.github.actions-runner.loop.plist` | LaunchDaemon for a GitHub self-hosted runner (Option B only). |

## Option A: fully local (recommended)

`loop-build.sh` runs LoopKit's own fastlane lanes on the Mac, with no GitHub Actions.
Certificates live in an encrypted fastlane match repo on the Mac, and Apple is reached
with an App Store Connect API key, so it works over ssh with nobody logged in.
Fetching code is the only thing that contacts GitHub.

How the pieces fit:

- **What gets built:** LoopKit/LoopWorkspace, straight from LoopKit, so new LoopKit
  releases are picked up without syncing anything.
- **Your changes:** this fork holds the script and `patches/`. The Mac keeps a clone
  of it at `~/loop-build-src` and pulls it before each build, so a patch you push
  here is built on the next scheduled run. Nothing on the fork's `main` is built.
- **Certificates:** `~/loop-build/match-secrets.git` on the Mac, backed up to a
  private repo on your local git server.

### One-time setup

1. Create a non-admin user (the files assume `loopbuilder`), run `brew install ruby`,
   and install the Xcode version LoopKit's workflow uses at
   `/Applications/Xcode_<version>.app`, with the iOS platform. Accept the license
   and first launch once as an admin:
   `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`
   (with `DEVELOPER_DIR` set to that Xcode if it isn't the selected one).
2. As `loopbuilder`, clone this fork's branch and link the script into `~/loop-build`:

   ```sh
   git clone --single-branch -b claude/loop-headless-mac-dexcom-share-s4f8jv \
     https://github.com/backlog-bbq/LoopWorkspace.git ~/loop-build-src
   mkdir -p ~/loop-build && chmod 700 ~/loop-build
   ln -s ~/loop-build-src/local-build/loop-build.sh ~/loop-build/loop-build.sh
   ```

   `~/loop-build` holds what the script creates (`LoopWorkspace/`, `bundle/`, `logs/`,
   `state/`, `artifacts/`, `match-secrets.git/`); `~/loop-build-src` holds only what
   you edit, and its submodules are never downloaded. If you later merge this branch
   into another one, switch the clone to it (`git -C ~/loop-build-src switch <branch>`
   after a fetch of that branch).
3. Copy `loop-build.conf.example` to `~/.config/loop-build/config`, fill it in, and
   `chmod 600` it and your `.p8` key file. Its `TOOLS_REPO` and `PATCH_DIR` lines
   already point at `~/loop-build-src`.
4. `~/loop-build/loop-build.sh setup` (add `--import-match <url>` to reuse an existing
   Match-Secrets repo), then `~/loop-build/loop-build.sh build`.
5. Install `com.loopbuild.auto.plist` (steps in the file) for a weekly check that
   rebuilds when LoopKit changes or every 30 days.

### Back up the certificate repo

`~/loop-build/match-secrets.git` and `MATCH_PASSWORD` are the only copy of your
distribution certificate. Create a dedicated, empty, private repo on your local git
server and set `MATCH_BACKUP_URL` in the config to it. The script then
runs `git push --mirror` to it after `setup`, after every successful certificate check
during a build, after `nuke-certs`, and when you run `loop-build.sh backup`. It never
pushes anywhere else. The repo stays encrypted with `MATCH_PASSWORD`.

Because the push also runs from launchd, it can't prompt for anything:

- Over ssh: add a deploy key with write access to that repo, set
  `MATCH_BACKUP_SSH_KEY` to its private key, and connect once by hand
  (`ssh -i <key> -p <port> git@<forge>`) so the server's host key is known.
- Over https: store a token in git's credential helper for the `loopbuilder` user.

A failed backup stops `setup` and `nuke-certs` (so you notice), but only sends a
`warning` notification during a scheduled build.

### Patches

`loop-build.sh` applies `PATCH_DIR/*.patch` to LoopWorkspace and
`PATCH_DIR/<Submodule>/*.patch` inside that submodule, after resetting everything a
previous build changed. To add, change or remove a patch, commit it to
`local-build/patches/` in this fork and push; the next `auto` run pulls it and,
because the patches changed, rebuilds. A patch that no longer applies to a new
LoopKit release stops the build with the `git apply` error in the log.

- `patches/LoopKit/mock-pump-heartbeat.patch` gives Loop's simulator pump
  (MockPumpManager) a 1-minute simulated BLE heartbeat, so a cloud CGM such as
  Dexcom Share or Nightscout keeps updating when paired with the simulator pump.
  Without it Loop fetches from Share once at launch and then stops, because Loop
  has no timer of its own and relies on the pump to wake it. The timer only runs
  while Loop is in the foreground: iOS suspends background apps, and a timer
  can't wake them the way real Bluetooth traffic does. It's for testing, not
  overnight use. Readings still arrive a minute or two after each 5-minute mark,
  because Share uploads late and Loop skips fetching while the newest reading is
  under 4.5 minutes old. When it works, the device log shows
  "Simulated BLE heartbeat" entries every minute.

  To try it in Xcode without the script, from a LoopWorkspace checkout:
  `git apply --directory=LoopKit local-build/patches/LoopKit/mock-pump-heartbeat.patch`

## Option B: GitHub Actions on a self-hosted runner

The workflows in this fork still run on GitHub's machines by default. To run the Mac
jobs on your own Mac:

1. Register a self-hosted runner for this repository with a custom label, for example
   `loop-mac-mini`, and start it at boot with `com.github.actions-runner.loop.plist`.
2. Set the repository variable `MAC_RUNNER` to that label.
3. Optionally set `SELF_HOSTED_XCODE` if Xcode isn't at the path LoopKit's workflow uses.

On a self-hosted runner the workflows skip their `sudo` steps (Xcode is selected with
`DEVELOPER_DIR` instead) and delete fastlane's temporary keychain after each job.
A self-hosted runner runs whatever the workflows in this repository say, with your
signing secrets, so only use it if you control who can change this repository. The
Mac isn't wiped between jobs, and the weekly upstream sync builds LoopKit's new code
without anyone reviewing it first.
