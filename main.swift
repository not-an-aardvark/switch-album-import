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
        guard let switchHotspot = try interface.scanForNetworks(withName: ssid).first else {
            throw SwitchImportError.hotspotNotFound(ssid)
        }
        print("[INFO] Connecting to \(ssid)...")
        try interface.associate(to: switchHotspot, password: password)
        defer {
            // Disconnect from the Switch hotspot.
            // It doesn't seem to be possible to reconnect back to the previous network here. However,
            // the OS should do it automatically since it won't be connected to any networks at this
            // point. Note that the OS might try to reconnect to the Switch hotspot instead; to prevent
            // this, the Switch's SSID should be configured to *not* auto-join in System Preferences.
            interface.disassociate()
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
