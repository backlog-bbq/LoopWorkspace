# Building Loop on your own Mac

`loop-build.sh` builds Loop and uploads it to TestFlight on your Mac mini, over ssh,
with nobody logged in at the screen. It runs LoopKit's own fastlane steps (the same
ones the GitHub "Browser Build" uses) without GitHub Actions:

- **What gets built:** LoopKit/LoopWorkspace, straight from LoopKit, so new LoopKit
  releases are picked up without syncing anything.
- **Your changes:** this fork holds the script and `patches/`. The Mac keeps a clone
  of it at `~/loop-build-src` and pulls it before each build, so a patch you push
  here is built on the next scheduled run. Nothing on the fork's `main` is built.
- **Signing:** Apple is reached with an App Store Connect API key, so no Apple ID has
  to be signed in to Xcode. The distribution certificate lives in an encrypted repo on
  the Mac (`~/loop-build/match-secrets.git`), backed up to your local git server.

| File | What it is |
| --- | --- |
| `install.sh` | Sets up the Mac step by step and starts the first build. Start here. |
| `loop-build.sh` | The build script. `loop-build.sh help` lists its commands. |
| `loop-build.conf.example` | Settings template for `~/.config/loop-build/config`. |
| `com.loopbuild.auto.plist` | Runs `loop-build.sh auto` every Sunday at 3:17 AM. |
| `patches/` | Changes applied to LoopKit's code before each build. |
| `com.github.actions-runner.loop.plist` | Only for the self-hosted runner option at the end. |

## Quick start

Over ssh on the Mac mini, as the user that will run the builds:

```sh
git clone --single-branch -b claude/loop-headless-mac-dexcom-share-s4f8jv \
  https://github.com/backlog-bbq/LoopWorkspace.git ~/loop-build-src
~/loop-build-src/local-build/install.sh
```

`install.sh` does every step below for you and asks only for what it can't find out
itself: your Team ID, the App Store Connect API key, and the backup repo on your git
server. It installs Ruby (and Homebrew if needed), gets the right Xcode ready,
writes the settings file, runs `setup`, installs the weekly schedule and starts the
first build in the background. It asks for your password when a step needs `sudo`.

Have these ready before you start:

- Your **Team ID** (developer.apple.com > Account > Membership details).
- An **App Store Connect API key** with Admin access, its Key ID and Issuer ID
  (step 4 below), with the `.p8` file copied to the Mac, for example into
  `~/Downloads` or `~/.config/loop-build`. `install.sh` finds it there.
- An **empty, private repo** on your git server for the certificate backup.

If anything fails, fix it and run `install.sh` again: it skips what's already done
and offers your earlier answers as defaults.

## First build, step by step

These are the steps `install.sh` performs, if you'd rather do them by hand or need
to see what one of them does.

Do everything over ssh on the Mac mini, as the user that will run the builds. Your
own account is fine. (A separate non-admin user is safer; if you make one, do every
step as that user, except the `sudo` commands, which need an admin.)

### 1. Check the clone and link the script

```sh
ls ~/loop-build-src/local-build/loop-build.sh
```

If that says "No such file", the clone is missing or on the wrong branch (the fork's
`main` doesn't have this folder). Clone it again:

```sh
rm -rf ~/loop-build-src
git clone --single-branch -b claude/loop-headless-mac-dexcom-share-s4f8jv \
  https://github.com/backlog-bbq/LoopWorkspace.git ~/loop-build-src
```

Then link the script into `~/loop-build`, where it keeps everything it creates:

```sh
mkdir -p ~/loop-build && chmod 700 ~/loop-build
ln -sf ~/loop-build-src/local-build/loop-build.sh ~/loop-build/loop-build.sh
~/loop-build/loop-build.sh check
```

`check` lists what's still missing, with the command to fix each item. Run it again
after each step below; you're done when it ends with "Ready for setup".

### 2. Install Ruby

fastlane needs Ruby 3 or newer; macOS's own Ruby is too old.

```sh
brew install ruby
```

The script finds Homebrew's Ruby on its own; you don't need to change your PATH.

### 3. Get the right Xcode ready

See which Xcode LoopKit builds with, and which ones you have:

```sh
grep -o 'Xcode_[0-9.]*' ~/loop-build-src/.github/workflows/build_loop.yml | head -1
for x in /Applications/Xcode*.app; do echo "$x: $("$x/Contents/Developer/usr/bin/xcodebuild" -version | head -1)"; done
```

If one of yours is that version, you'll put its path in `XCODE_APP` in step 5. If
not, install it, for example with `brew install xcodesorg/made/xcodes` and then
`xcodes install <version>` (it asks for your Apple ID once, in the terminal).

Then prepare it. Set `XB` to that Xcode's `xcodebuild`, for example:

```sh
XB=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
sudo "$XB" -license accept
sudo "$XB" -runFirstLaunch
"$XB" -downloadPlatform iOS
"$XB" -downloadPlatform watchOS
```

### 4. Collect your Apple details

- **Team ID:** developer.apple.com > Account > Membership details. 10 characters.
- **API key:** App Store Connect > Users and Access > Integrations > App Store Connect
  API > Team Keys > "+". Give it any name and **Admin** access. Note the **Key ID**
  and the **Issuer ID** shown above the list, and download the `.p8` file. Apple
  lets you download it only once.

Copy the key to the Mac, from the computer you downloaded it on:

```sh
ssh <mac-mini> 'mkdir -p ~/.config/loop-build'
scp ~/Downloads/AuthKey_XXXXXXXXXX.p8 <mac-mini>:.config/loop-build/
```

### 5. Write the settings file

```sh
cp ~/loop-build-src/local-build/loop-build.conf.example ~/.config/loop-build/config
chmod 600 ~/.config/loop-build/config ~/.config/loop-build/AuthKey_*.p8
openssl rand -base64 30     # use this as MATCH_PASSWORD
nano ~/.config/loop-build/config
```

Fill in `TEAMID`, `FASTLANE_KEY_ID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY_PATH` (the
real file name of your `.p8`) and `MATCH_PASSWORD`. Save `MATCH_PASSWORD` in your
password manager: without it the certificate repo and its backup can't be opened.
If you're using an Xcode that isn't at `/Applications/Xcode_<version>.app`, set
`XCODE_APP`, for example `XCODE_APP="/Applications/Xcode.app"`. Leave `TOOLS_REPO`
and `PATCH_DIR` as they are.

### 6. Set up the certificate backup

The certificate repo is the only copy of your distribution certificate, so back it up
to your local git server before creating it:

1. On the git server, create an **empty, private** repo, for example
   `loop-match-backup`. Use it for nothing else: each backup overwrites it.
2. On the Mac, make a key just for it and print the public half:

   ```sh
   ssh-keygen -t ed25519 -N "" -C loop-match-backup -f ~/.ssh/loop_match_backup
   cat ~/.ssh/loop_match_backup.pub
   ```

3. Add that public key to the repo as a deploy key **with write access**
   (repo Settings > Deploy Keys on Gitea, Forgejo and GitLab).
4. Copy the repo's ssh URL and connect once, to accept the server's host key
   (answer "yes"; an error about no shell access is fine):

   ```sh
   ssh -i ~/.ssh/loop_match_backup -p <ssh-port> git@<git-server>
   ```

5. Add to `~/.config/loop-build/config`:

   ```sh
   MATCH_BACKUP_URL="ssh://git@<git-server>:<ssh-port>/<you>/loop-match-backup.git"
   MATCH_BACKUP_SSH_KEY="~/.ssh/loop_match_backup"
   ```

Run `~/loop-build/loop-build.sh check` now. Fix anything marked TODO until it says
"Ready for setup".

### 7. Run setup (once)

```sh
~/loop-build/loop-build.sh setup
```

This downloads LoopWorkspace and its submodules into `~/loop-build/LoopWorkspace`,
installs fastlane, registers Loop's identifiers with Apple, creates a distribution
certificate and profiles in the certificate repo, and backs it up. The first run
takes a while. It ends with "Setup complete".

### 8. Check the app exists in App Store Connect

Open App Store Connect > Apps. If you uploaded Loop to TestFlight before with this
team, it's there already. If not: "+" > New App, platform iOS, any name nobody else
on the App Store uses, bundle ID `com.<TEAMID>.loopkit.Loop` (setup just registered
it), any SKU, Full Access.

### 9. Build and upload

A build can take well over half an hour. Start it so it survives the ssh session
ending and the Mac idling to sleep, then watch the log:

```sh
nohup caffeinate -i ~/loop-build/loop-build.sh build >/dev/null 2>&1 &
sleep 2; tail -f "$(ls -t ~/loop-build/logs/*.log | head -1)"
```

(Ctrl-C stops watching, not the build.) It finishes with "Done. Loop was uploaded to
TestFlight". After Apple processes it, usually within half an hour, it appears in
App Store Connect > TestFlight and in the TestFlight app on your phone. The build
number continues from your last TestFlight upload. The IPA and build log are also
kept in `~/loop-build/artifacts/`.

### 10. Turn on the weekly schedule

The schedule file assumes a user called `loopbuilder`; this installs it for you:

```sh
sed "s#loopbuilder#$(whoami)#g" ~/loop-build-src/local-build/com.loopbuild.auto.plist > /tmp/com.loopbuild.auto.plist
sudo install -o root -g wheel -m 644 /tmp/com.loopbuild.auto.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.loopbuild.auto.plist
```

Every Sunday at 3:17 AM it pulls your fork, checks LoopKit, and builds only if
LoopKit or your patches changed, or the last build is 30 days old (TestFlight builds
expire after 90). To test it right away: `sudo launchctl kickstart system/com.loopbuild.auto`.
`~/loop-build/loop-build.sh status` shows the last build. To get a message when a
build finishes or fails, set `NOTIFY_CMD` in the config.

## When something fails

Each run writes a log to `~/loop-build/logs/`; the last lines say what went wrong.

| Message | What to do |
| --- | --- |
| `Xcode not found at ...` | Set `XCODE_APP` in the config (step 3). LoopKit sometimes moves to a newer Xcode; install it when that happens. |
| `The iOS platform isn't installed` | Run the `-downloadPlatform` commands in step 3. |
| `... is readable by other users` | Run the `chmod 600` command it prints. |
| `fastlane certs failed` / too many certificates | Revoke an unused distribution certificate at developer.apple.com > Certificates, then run `build` again. |
| `distribution certificate is missing or expired` | Run `~/loop-build/loop-build.sh nuke-certs` in a terminal, then `build`. Existing TestFlight builds keep working. |
| Can't find the app / `latest_testflight_build_number` fails | Create the app in App Store Connect (step 8). |
| `Couldn't push the certificate repo` | Check `MATCH_BACKUP_URL`, the deploy key's write access, and that you connected once by hand (step 6). `loop-build.sh backup` retries. |
| `git apply` error on a patch | LoopKit changed the code the patch touches. Update or remove the patch in `local-build/patches/` and push. |
| `Another loop-build run is in progress` | A build is still running; see it with `pgrep -fl loop-build`. |

## Patches

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
