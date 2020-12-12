import CoreWLAN
import Foundation

enum SwitchImportError: Error {
    case INTERNAL_ASSERTION_FAILURE
    case NO_WIFI_INTERFACE
    case HOTSPOT_NOT_FOUND(String)
    case MALFORMED_INDEX_FILE(Any)
    case BAD_FILENAME_FROM_SWITCH(String)
}

extension URLSession {
    func synchronousFetch(url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(SwitchImportError.INTERNAL_ASSERTION_FAILURE)
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
}

private func printUsage() {
    print("""
    Usage: switch-album-import -h|-help|--help
           switch-album-import -ssid <ssid> -password <password> -output_dir <dir>
    """)
}

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    if (args.contains { arg in arg == "-h" || arg == "-help" || arg == "--help" }) {
        printUsage()
        exit(0)
    }

    let defaults = UserDefaults.standard

    guard let ssid = defaults.string(forKey: "ssid"),
          let password = defaults.string(forKey: "password"),
          let output_dir = defaults.string(forKey: "output_dir")
    else {
        printUsage()
        return 1
    }

    var output_dir_is_directory: ObjCBool = true
    if !FileManager.default.fileExists(atPath: output_dir, isDirectory: &output_dir_is_directory) {
        print("[ERROR] No such directory: \(output_dir)")
        return 1
    }

    do {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw SwitchImportError.NO_WIFI_INTERFACE
        }
        let matching_networks = try interface.scanForNetworks(withName: ssid)
        if matching_networks.count == 0 {
            throw SwitchImportError.HOTSPOT_NOT_FOUND(ssid)
        }

        print("[INFO] Connecting to \(ssid)...")
        try interface.associate(to: matching_networks.first!, password: password)
        defer {
            // Disconnect from the Switch hotspot.
            // It doesn't seem to be possible to reconnect back to the previous network here. However,
            // the OS should do it automatically since it won't be connected to any networks at this
            // point. Note that the OS might try to reconnect to the Switch hotspot instead; to prevent
            // this, the Switch's SSID should be configured to *not* auto-join in System Preferences.
            interface.disassociate()
        }

        let session_config = URLSessionConfiguration.ephemeral
        session_config.waitsForConnectivity = true
        let url_session = URLSession(configuration: session_config)

        let index_contents = try url_session.synchronousFetch(url: URL(string: "http://192.168.0.1/data.json")!)
        let parsed_index = try JSONSerialization.jsonObject(with: index_contents)
        guard let parsed_dict = parsed_index as? [String: Any],
              let console_name = parsed_dict["ConsoleName"] as? String,
              let filenames = parsed_dict["FileNames"] as? [String]
        else {
            throw SwitchImportError.MALFORMED_INDEX_FILE(parsed_index)
        }
        print("[INFO] Downloading \(filenames.count) file(s) from \(console_name)...")
        for filename in filenames {
            // Sanity check to ensure filenames are reasonable and don't contain e.g. path components
            if filename.range(of: #"^\w[\w.-]+$"#, options: .regularExpression) == nil {
                throw SwitchImportError.BAD_FILENAME_FROM_SWITCH(filename)
            }

            print("[INFO] Downloading \(filename)...")
            let url = URL(string: "http://192.168.0.1/img/\(filename)")!
            let data = try url_session.synchronousFetch(url: url)
            let file_url = URL(fileURLWithPath: output_dir).appendingPathComponent(filename)
            try data.write(to: file_url)
        }
        print("[INFO] Successfully downloaded \(filenames.count) file(s) from \(console_name)")
    } catch {
        print("[ERROR] \(error)")
        return 1
    }
    return 0
}

exit(main())
