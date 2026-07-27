# *Unofficial* Conductor.build iOS app

A native-iOS app prototype for [Conductor.build](https://conductor.build).

## Screenshots

|||||
|--|--|--|--|
|<img src="docs/resources/showcase-home.png" width=200>|<img src="docs/resources/showcase-chat.png" width=200>|<img src="docs/resources/showcase-chat-menu.png" width=200>|<img src="docs/resources/showcase-new-workspace.png" width=200>|

## Installation

### Prerequites

Install [Homebrew](https://brew.sh/), then run:

```bash
brew install mise xcodegen xcbeautify
```

(`xcbeautify` is only needed for development / building from the command line)

### iOS

Steps:
1. Install Xcode 26

    a. I recommend installing it through https://www.xcodes.app/ for convenience. Any Xcode 26 version will do

    b. Otherwise, you can download it from the [Mac App Store](https://apps.apple.com/us/app/xcode/id497799835?mt=12)
  
2. Clone the repo & run `mise run xcode` to generate the Xcode project + open it.
3. In Xcode, click on the `ConductorMobile` project, then go to Signing & Capabilities -> Team -> Select your developer team

4. In the top-center bar select the left button and change it to `ConductorMobile`. Then choose your physical device

    a. If you haven't connected it to your Mac before, you'll need to plug it in with a cable. After this initial pairing you can deploy it over Wi-Fi.

6. Press Run (Cmd+R)

### Desktop Companion

In order to read and write to local workspaces, as well as support features the Conductor Cloud API doesn't support yet (like GitHub PR status & in-progress status for Cloud workspaces), you can install our macOS companion app. You can grab it from [Releases](https://github.com/gannonprudhomme/conductor-mobile-unofficial/releases), or build it yourself with `mise run desktop`.

## Setup

#### UI Hook

After downloading & launching the macOS app, you must install the "UI hook" into the Conductor macOS app to actually _control_ local workspaces:
1. Press `Copy Loader` in the `Conductor Mobile Companion` (aka "Desktop Companion")
2. In Conductor, press `⌘+⌥+I` to display the Web Inspector
3. Go to the `Sources` tab
4. Press the `+` button in the bottom left, and select `Console Snippet`

<img src="docs/resources/01-create-snippet.png" width=400>

5. Paste the loader script, name it whatever (e.g. `"Conductor Mobile"`).
6. In the `Console Snippet` section, hover over the script you added and press the Run button:

<img src="docs/resources/02-run-snippet.png" width=400>

7. Back in the desktop app, it should say "Connected" on the UI Hook row.

## How does it work?

### Reading data

For the most part all of the data we get is from Conductor's SQLite database. Assuming the iOS app is connected, we poll `PRAGMA data_version` very rapidly - every 3 ms - and if there are any changes to the tables/IDs we're monitoring we send them to the app over a web socket.

### Writing data through the UI hook

While Conductor does use SQLite to persist pretty much all of it's data, writing to the database doesn't actually propagated the changes to the UI. It also

just writing to the database does not mean you will see the changes propagated in Conductor - at least not when it's open. (if you write to the SQLite database then restart, you will see them)

As a result of this, we install a "UI Hook" where instead of writing the data to the database, we install a script in Tauri's Web Inspector which connects to the desktop companion using Server Sent Events (SSEs). This means whenever we do (local Conductor/non-Conductor-Cloud) actions, we are performing the same functions that the Conductor UI itself performs.

Though note the `Copy loader` button isn't actually the UI hook itself. It instead retrieves & executes the UI hook from the desktop companion web server. This is mostly so it automatically updates itself during development.

## Development

Your agent can probably figure it out, but I'll leave this in here in case you want to read. For the most part the `mise` scripts is what my agent uses. I also recommend installing [Xcodebuildmcp](https://github.com/getsentry/XcodeBuildMCP) as it gives easy access for your agent to "see", among other things, though it's not strictly necessary.

Generate both native projects and open them in Xcode with:

```sh
mise run xcode
```

Build the iOS app with:

```sh
mise -C ios run build
# or
cd ios && mise run build
```

Deploy to the simulator with
```sh
mise -C ios run deploy
```

Build and run the native macOS companion with:

```sh
mise run desktop
```
