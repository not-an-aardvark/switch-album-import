# switch-album-import

This is a tool for importing screenshots and videos from the Nintendo Switch album. It's a command-line client for the "Send to Smartphone" feature introduced in Switch firmware version 11.0.0 (released 2020-11-30). The idea is that a command-line script might be more convenient than the recommended UX, which involves scanning two separate QR codes and manually downloading images using a smartphone browser.

Currently, only macOS is supported. Since the Switch's export protocol requires connecting to a local wifi hotspot, tools that connect automatically by modifying your wifi settings will inherently be a bit OS-specific.

It would also be possible to create a platform-independent tool where the user manually edits their wifi settings beforehand, but that's not currently implemented. (Since this tool is designed for personal use, it's optimized for convenience over portability.)

## Installation

1. Clone the repository on macOS
1. Run `make all` to generate a binary in `bin/switch-album-import` (and optionally `make install` to symlink the binary into `/usr/local/bin/`).

There are probably some build dependencies omitted here. Unfortunately, at this time I'm not familiar enough with Swift builds to determine what those dependencies are, other than "it seems to work out-of-the-box on my laptop" and "maybe try the XCode Command Line tools". Feel free to send a PR updating this section if you figure anything out.

Alternatively, you can try downloading a precompiled binary from the [releases page](https://github.com/not-an-aardvark/switch-album-import/releases).

## How to use

1. Install on a macOS device that's physically close to the Switch device.
1. On the Switch, go to the Album, and open a screenshot or video that you want to export. Navigate to "Sharing and Editing", then "Send to Smartphone". You can also export a batch of screenshots rather than getting them one at a time.
1. The Switch will display a QR code. Ignore it and press the "+" button to open the "Trouble connecting?" menu. It will display an SSID and a password.
1. Run this tool with `switch-album-import -ssid <the ssid> -password <the password> -output_dir <directory where files should be downloaded>`
1. The files should appear in the specified folder. You can now exit the Switch UI.
1. **Recommended:** After running this the first time, go to Network Preferences > Advanced on the macOS device, and uncheck "Auto-join" for the Switch's SSID in the list. This should smooth out the process of reconnecting to your wifi network after running the script, and only needs to be done once for each Switch that you import from. (The tool auto-disconnects from the Switch hotspot before it exits, but this step prevents your computer from automatically reconnecting to the Switch hotspot afterwards, so that it reconnects to your real wifi network instead.)

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

Incidentally, filenames in the Switch album also encode the time that a screenshot was taken, as well as the game that the screenshot is from, as described [here](https://github.com/RenanGreca/Switch-Screenshots/tree/3958bd3a4444fdf84d1f0c544bd2f9cd39dbc60a#about-the-game-ids).

### Additional protocol quirks

The following is based on observed behavior, with the goal of saving debugging time for anyone else who implements a client.

* The hotspot created by the Switch can connect to exactly one DHCP client at a time, and the HTTP server can handle exactly one request at a time.
* The Switch hotspot appears to have a bug where it honors DHCP leases from previous hotspot instances (possibly due to a stale ARP cache), but refuses to renew those leases.

    When reconnecting to a hotspot, macOS (along with some other operating systems) generally [attempts to reuse a previous DHCP lease it had from that hotspot, as a performance optimization](https://cafbit.com/post/rapid_dhcp_or_how_do/). This allows network traffic to start almost immediately. A few seconds later, macOS asynchronously renews the lease, expecting the renewal to succeed because the lease is still working.

    When using a tool like this, it will often be the case that a client was recently connected to the Switch hotspot, and the Switch hotspot has since been rebooted (e.g. to export another video). In this case, the Switch will accept the new connection and start exchanging traffic, but then reject (i.e. DHCPNAK) the lease renewal a few seconds later, because it no longer remembers the old lease and hasn't offered a new one. The client will interpret this as a termination of the DHCP lease, and will proceed to drop TCP connections and return an application-level "network connection lost" error. This error is consistently reproducible provided that the lease termination happens during an HTTP request.

    Afterwards, the client successfully recreates the lease from scratch and can renew it as needed, so the issue can be consistently worked around by retrying once.
