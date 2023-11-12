import CoreWLAN
import Foundation

enum SwitchImportError: Error {
    case internalAssertionFailure
    case noWifiInterface
    case hotspotNotFound(String)
    case malformedIndexFile(Any)
    case badFilenameFromSwitch(String)
}

extension URLSession {
    private func synchronousFetchWithoutRetry(url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(SwitchImportError.internalAssertionFailure)
        let semaphore = DispatchSemaphore(value: 0)
        let task = dataTask(with: url) { data, _, error in
            if let data = data {
                result = .success(data)
            } else {
                result = .failure(error!)
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }

    // Fetch the given URL, and retry exactly once if network connection is
    // lost. This is a workaround for the Switch's DHCP lease bug described in
    // the readme.
    func synchronousFetch(url: URL) throws -> Data {
        do {
            return try synchronousFetchWithoutRetry(url: url)
        } catch let err as NSError where err.domain == NSURLErrorDomain && err.code == NSURLErrorNetworkConnectionLost {
            return try synchronousFetchWithoutRetry(url: url)
        }
    }
}

extension FileManager {
    func directoryExists(atPath: String) -> Bool {
        var fileIsDirectory: ObjCBool = false
        return fileExists(atPath: atPath, isDirectory: &fileIsDirectory) &&
            fileIsDirectory.boolValue
    }
}

private func printUsage() {
    print("""
        Usage: switch-album-import -h|-help|--help
           switch-album-import -ssid <ssid> -password <password> -output_dir <dir>
    """)
}

private func getSessionConfig() -> URLSessionConfiguration {
    let sessionConfig = URLSessionConfiguration.ephemeral

    // Due to the DHCP lease bug described in the readme, the wifi network will
    // disconnect once, and then reconnect, during normal operation. As a result,
    // it's necessary for requests to wait for network connectivity rather than
    // immediately throwing an error. (It's also necessary for requests to handle
    // a single connection-lost error, as implemented in `synchronousFetch`, in
    // case this disconnect happens in the middle of a request.)
    sessionConfig.waitsForConnectivity = true

    // However, if the network connection was lost for a long time, it's likely that
    // the user has closed the switch UI, or something else has gone wrong. In this case
    // it's better to time out after a minute or so rather than leaving the script running
    // for the default timeout of 7 days.
    //
    // `timeoutIntervalForResource` is a timeout for the whole request, so this timeout
    // could incorrectly halt a download that is just proceeding very slowly. Unfortunately,
    // there doesn't seem to be a good way to set a timeout specifically for a network connection
    // (`timeoutIntervalForRequest` only starts counting when a connection has been established).
    sessionConfig.timeoutIntervalForResource = 60

    return sessionConfig
}

private func tryReconnectToNormalWifiOrLogWarning(interface: CWInterface) {
    // So this task ("reconnect to the wifi network that the user was connect to before
    // the script was running") is surprisingly difficult.
    // * We can record the SSID before we connect to the Switch hotspot, but there's no way
    //   to access the saved password, or to tell macOS to just use the saved password.
    // * If we just disconnect from the Switch hotspot and exit the script, macOS Big Sur
    //   will leave the wifi in a disconnected state. (Previous versions would attempt to
    //   reconnect to a network according to the user's default settings, but this seems to
    //   no longer happen.)
    // * However, if also reboot the wifi interface before exiting, macOS will go through its
    //   normal process of auto-joining a network.
    // * macOS might attempt to reconnect to the Switch hotspot, which will typically still
    //   be active and will be auto-remembered. Users can prevent this from happening by
    //   configuring the Switch's SSID to *not* auto-join in System Preferences. (If the script
    //   is running as root, it would also be possible to force-remove the Switch from the
    //   network list, but this seems like it's not worth the risks of telling people to run
    //   the script as root.)
    interface.disassociate()
    do {
        try interface.setPower(false)
        try interface.setPower(true)
    } catch {
        print("[WARNING] Failed to reset wifi connection: \(error)")
    }
}

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    if (args.contains { arg in arg == "-h" || arg == "-help" || arg == "--help" }) {
        printUsage()
        exit(0)
    }

    guard let ssid = UserDefaults.standard.string(forKey: "ssid"),
          let password = UserDefaults.standard.string(forKey: "password"),
          let outputDir = UserDefaults.standard.string(forKey: "output_dir")
    else {
        printUsage()
        return 1
    }

    if !FileManager.default.directoryExists(atPath: outputDir) {
        print("[ERROR] No such directory: \(outputDir)")
        return 1
    }

    do {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw SwitchImportError.noWifiInterface
        }
        // For baffling reasons, on macOS Sonoma, the first call to `scanForNetworks` returns a `CWNetwork` with .ssid = nil.
        // The second call returns a `CWNetwork` with the proper SSID that can actually be connected to.
        try interface.scanForNetworks(withName: ssid)
        guard let switchHotspot = try interface.scanForNetworks(withName: ssid).first else {
            throw SwitchImportError.hotspotNotFound(ssid)
        }
        print("[INFO] Connecting to \(ssid)...")
        try interface.associate(to: switchHotspot, password: password)
        defer {
            tryReconnectToNormalWifiOrLogWarning(interface: interface)
        }

        let urlSession = URLSession(configuration: getSessionConfig())

        let indexContents = try urlSession.synchronousFetch(url: URL(string: "http://192.168.0.1/data.json")!)
        let parsedIndex = try JSONSerialization.jsonObject(with: indexContents)
        guard let parsedDict = parsedIndex as? [String: Any],
              let consoleName = parsedDict["ConsoleName"] as? String,
              let filenames = parsedDict["FileNames"] as? [String]
        else {
            throw SwitchImportError.malformedIndexFile(parsedIndex)
        }
        for filename in filenames {
            // Sanity check to ensure filenames are reasonable and don't contain e.g. path components
            if filename.range(of: #"^\w[\w.-]+$"#, options: .regularExpression) == nil {
                throw SwitchImportError.badFilenameFromSwitch(filename)
            }

            let sourceUrl = URL(string: "http://192.168.0.1/img/\(filename)")!
            let destinationUrl = URL(fileURLWithPath: outputDir).appendingPathComponent(filename)

            print("[INFO] Downloading \(filename)...")
            try urlSession.synchronousFetch(url: sourceUrl).write(to: destinationUrl)
        }
        print("[INFO] Successfully downloaded \(filenames.count) file(s) from \(consoleName)")
    } catch {
        print("[ERROR] \(error)")
        return 1
    }
    return 0
}

exit(main())
