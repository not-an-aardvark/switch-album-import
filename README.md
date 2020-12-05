# switch-album-import

This is a tool for importing screenshots and videos from the Nintendo Switch album. It's effectively a command-line client for the "Send to Smartphone" feature introduced in Switch firmware version 11.0.0 (released 2020-11-30). The goal is that importing images onto a computer with a command-line script might be more convenient for repeated use than the recommended UX, which involves scanning two separate QR codes and manually downloading images using a smartphone browser.

Currently, only macOS is supported. Since the Switch's export protocol requires connecting to a local wifi hotspot, tools that connect automatically by modifying your wifi settings will inherently be a bit OS-specific.

It would also be possible to create a platform-independent tool where the user manually edits their wifi settings beforehand, but that's not currently implemented. (Since this tool is designed for personal use, it's optimized for convenience over portability.)

## Installation

1. Clone the repository on macOS
1. Run `make all` to generate a binary in `bin/switch-album-import` (or `make install` to also symlink the binary into `/usr/local/bin/`).

There are probably some build dependencies omitted here. Unfortunately, at this time I'm not familiar enough with Swift builds to determine what those dependencies are, other than "it seems to work out-of-the-box on my laptop" and "maybe try the XCode Command Line tools". Feel free to send a PR updating this section if you figure anything out.

Alternatively, you can try downloading a precompiled binary from the [releases page](https://github.com/not-an-aardvark/switch-album-import/releases).

## How to use

1. Install on a macOS device that's physically close to the Switch device.
1. On the Switch, go to the Album, and open a screenshot or video that you want to export. Navigate to "Sharing and Editing", then "Send to Smartphone". You can also export a batch of screenshots rather than getting them one at a time.
1. The Switch will display a QR code. Ignore it and tap the "+" button to open the "Trouble connecting?" menu. It will display an SSID and a password.
1. Run this tool with `switch-album-import -ssid <the ssid> -password <the password> -output_dir <directory where files should be downloaded>`
1. The files should appear in the specified folder. You can now exit the Switch UI.
1. **Recommended:** After running this the first time, go to Network Preferences > Advanced, and uncheck "Auto-join" for the Switch's SSID in the list. The tool will auto-disconnect from the Switch hotspot before it exits, but this step will prevent your computer from automatically reconnecting to the Switch hotspot afterwards, so that it reconnects to your real wifi network instead. This setting only needs to be set once for each Switch that you import from.

## Protocol

The Switch's export protocol works by setting up a wifi hotspot and serving the images over HTTP from `192.168.0.1`. The Switch UI generates two QR codes:

* The first one is a [wifi network config](https://github.com/zxing/zxing/wiki/Barcode-Contents#wi-fi-network-config-android-ios-11) for a WPA2-PSK(AES) network. The SSID is `switch_` followed by an eleven-character sequence, which seems to be constant for any given Switch (it might be a serial number of some kind). The password is a random 8-character sequence that gets regenerated on every export.
* The second QR code is the URL `http://192.168.0.1/index.html`. When connected to the hotspot, the Switch serves a static HTML page at this URL, which pulls data from `http://192.168.0.1/data.json`.

`http://192.168.0.1/data.json` has a JSON file with the following schema:

```ts
{
  ConsoleName: string, // The "Console Nickname" in System Settings
  FileType: "photo" | "movie",
  FileNames: string[], // The names of the files being exported

  DownloadMes: string, // Human-readable page title
  MovieHelpMes: string, // Human-readable instructions on downloading videos from a mobile browser
  PhotoHelpMes: string // Human-readable instructions on downloading images from a mobile browser
}
```

All of the files specified in `FileNames` are served from the Switch at `http://192.168.0.1/img/<filename>`.
