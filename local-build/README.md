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

Builds run in a separate **Standard** (non-admin) account, here called `loopbuilder`;
your own account stays the administrator. Only the build account gets Ruby, fastlane,
the settings, the signing keys and the builds. Your account needs none of it; Xcode
in `/Applications` is the one thing they share.

1. Create the build account, if you haven't: System Settings > Users & Groups >
   Add User, type **Standard**, name `loopbuilder`. Or over ssh:
   `sudo sysadminctl -addUser loopbuilder -fullName "Loop Builder" -password '<password>'`.
   Nobody needs to log in to it at the screen.
2. Over ssh, in **your own** account:

   ```sh
   git clone --single-branch -b claude/loop-headless-mac-dexcom-share-s4f8jv \
     https://github.com/backlog-bbq/LoopWorkspace.git ~/loop-build-src
   ~/loop-build-src/local-build/install.sh --admin loopbuilder
   ```

   This does only what needs an administrator, and installs nothing in your account:
   - gets the shared Xcode in `/Applications` ready (license, first-launch setup,
     iOS and watchOS platforms; it offers to download Xcode if the right version is
     missing),
   - clones the fork into `loopbuilder`'s home,
   - moves the API key from your `~/Downloads` into `loopbuilder`'s settings folder,
     readable only by `loopbuilder`,
   - installs the weekly schedule, which runs as `loopbuilder`.
3. It then offers to continue as `loopbuilder` (or later:
   `sudo -iu loopbuilder ~/loop-build-src/local-build/install.sh`). That part runs
   inside `loopbuilder`'s home, with no `sudo`: it builds a private Ruby, asks for
   your Apple details, writes the settings, sets up the certificate backup, runs
   `setup` and starts the first build in the background.

Without `--admin`, an administrator account is asked whether to build there or to
set up a separate build account. To build in a single account, answer yes.

If the first build started from `sudo -iu` fails with a signing or keychain error,
start it from your account the way the weekly run starts it:
`sudo launchctl kickstart system/com.loopbuild.auto`.

### What it installs, and where

Everything except Xcode goes in the build account's home folder. Homebrew isn't used or needed.

| What | Where |
| --- | --- |
| Ruby 3.4 with its own OpenSSL and libyaml, built from source by `ruby-build` (10-20 min, once) | `~/loop-build/ruby` (the build account's home, like everything below except Xcode) |
| `ruby-build` (and `xcodes`, if a single account downloads Xcode with it) | `~/loop-build/tools` |
| fastlane and the other gems | `~/loop-build/bundle` |
| LoopWorkspace, logs, build output, certificate repo | `~/loop-build` |
| Settings and API key | `~/.config/loop-build` |
| Xcode, only if you don't already have the right version | `/Applications` (shared; `~/Applications` for a single account) |
| Backup deploy key | `~/.ssh/loop_match_backup` |

`sudo` is used only in the `--admin` part (or by a single administrator account),
for these:

- Accepting the Xcode license and Xcode's first-launch setup, which Xcode needs before
  it can build anything. If you've already opened that Xcode, both are done and skipped.
- The weekly schedule, `/Library/LaunchDaemons/com.loopbuild.auto.plist`, if you want
  it: a schedule that runs with nobody logged in has to be a system file. Say no and
  build by hand instead.

Downloading the iOS and watchOS platforms, if Xcode doesn't have them yet, is done
by Xcode's own tool without `sudo`.

Have these ready before you start:

- Your **Team ID** (developer.apple.com > Account > Membership details).
- An **App Store Connect API key** with Admin access, its Key ID and Issuer ID
  (step 4 below), with the `.p8` file copied into your `~/Downloads` on the Mac.
  `install.sh --admin` hands it to the build account.
- An **empty, private repo** on your git server for the certificate backup.

If anything fails, fix it and run `install.sh` again: it skips what's already done
and offers your earlier answers as defaults.

## First build, step by step

These are the steps `install.sh` performs, if you'd rather do them by hand or need
to see what one of them does.

Do everything over ssh on the Mac mini, as the user that will run the builds. Your
own account is fine. (A separate non-admin user is safer; if you make one, do every
step as that user. The `sudo` steps then need an admin: do them from your own
account, or let `install.sh --admin <build-account>` do them.)

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

### 2. Get the right Xcode ready

See which Xcode LoopKit builds with, and which ones you have:

```sh
grep -o 'Xcode_[0-9.]*' ~/loop-build-src/.github/workflows/build_loop.yml | head -1
for x in /Applications/Xcode*.app ~/Applications/Xcode*.app; do [ -d "$x" ] && echo "$x: $(defaults read "$x/Contents/Info" CFBundleShortVersionString)"; done
```

If one of yours is that version, you'll put its path in `XCODE_APP` in step 5. If
not, download it from developer.apple.com/download/all and unpack it into
`~/Applications`, or use the `xcodes` tool (github.com/XcodesOrg/xcodes):
`xcodes install <version> --directory ~/Applications`.

Then prepare it. Set `XB` to that Xcode's `xcodebuild`, for example:

```sh
XB=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
sudo "$XB" -license accept
sudo "$XB" -runFirstLaunch
"$XB" -downloadPlatform iOS
"$XB" -downloadPlatform watchOS
```

### 3. Build a private Ruby

fastlane's Bundler needs Ruby 3.2 or newer; macOS's own Ruby (2.6) is too old. Build
one into `~/loop-build/ruby` with `ruby-build`. It compiles OpenSSL itself; libyaml
(needed for YAML) is added in front of the Ruby recipe because macOS doesn't have it:

```sh
mkdir -p ~/loop-build/tools
git clone --depth 1 https://github.com/rbenv/ruby-build.git ~/loop-build/tools/ruby-build
V=$(cd ~/loop-build/tools/ruby-build/share/ruby-build && ls -d 3.4.* | sort -t. -k3,3n | tail -1)
{ echo 'install_package "yaml-0.2.5" "https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz#c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4"'
  cat ~/loop-build/tools/ruby-build/share/ruby-build/$V; } > ~/loop-build/tools/loop-ruby-$V
DEVELOPER_DIR="${XB%/usr/bin/xcodebuild}" \
RUBY_CONFIGURE_OPTS="--with-libyaml-dir=$HOME/loop-build/ruby --disable-install-doc" \
  ~/loop-build/tools/ruby-build/bin/ruby-build ~/loop-build/tools/loop-ruby-$V ~/loop-build/ruby
```

`loop-build.sh` uses `~/loop-build/ruby` automatically; you don't need to change PATH.

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
