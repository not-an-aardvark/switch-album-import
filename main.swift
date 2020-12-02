import CoreWLAN
import Foundation

private func printUsage() {
    print("""
    Usage: switch-album-import -h|-help|--help
           switch-album-import -ssid <ssid> -password <password> -output_dir <dir>
    """)
}

func main() {
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
        exit(1)
    }

    var output_dir_is_directory: ObjCBool = true
    if !FileManager.default.fileExists(atPath: output_dir, isDirectory: &output_dir_is_directory) {
        print("[ERROR] No such directory: \(output_dir)")
        exit(1)
    }

    print("[INFO] Connecting to \(ssid)...")

    let client = CWWiFiClient.shared()

    guard let interface = client.interface(), let switch_hotspot = (try? interface.scanForNetworks(withName: ssid))?.first else {
        print("[ERROR] Failed to find switch hotspot at \(ssid)")
        exit(1)
    }

    do {
        try interface.associate(to: switch_hotspot, password: password)
    } catch {
        print("[ERROR] Failed to connect to switch hotspot at \(ssid)")
        interface.disassociate()
        exit(1)
    }
    print("[INFO] Successfully connected to \(ssid)")

    let index_contents = Result {
        try Data(contentsOf: URL(string: "http://192.168.0.1/data.json")!)
    }
    let parsed_index = index_contents.flatMap { contents in
        Result { try JSONSerialization.jsonObject(with: contents) }
    }

    if case let .failure(error) = parsed_index {
        print("[ERROR] Failed to download index file from switch: \(error)")
        interface.disassociate()
        exit(1)
    }

    guard let parsed_dict = try! parsed_index.get() as? [String: Any],
          let console_name = parsed_dict["ConsoleName"] as? String,
          let filenames = parsed_dict["FileNames"] as? [String]
    else {
        print("[ERROR] Failed to parse index file from switch: \(parsed_index)")
        interface.disassociate()
        exit(1)
    }

    print("[INFO] Downloading \(filenames.count) file(s) from \(console_name)...")
    let semaphore = DispatchSemaphore(value: 0)
    for filename in filenames {
        // Sanity check to ensure filenames are reasonable and don't contain e.g. path components
        if filename.range(of: #"^\w[\w.-]+$"#, options: .regularExpression) == nil {
            print("Unexpected filename: \(filename)")
            interface.disassociate()
            exit(1)
        }

        let url = URL(string: "http://192.168.0.1/img/\(filename)")!
        print("[INFO] Downloading \(filename)...")
        let task = URLSession.shared.dataTask(with: url) { data, _, error in

            guard let data = data else {
                print("[ERROR] Failed to download \(url): \(String(describing: error))")
                interface.disassociate()
                exit(1)
            }
            let file_url = URL(fileURLWithPath: output_dir).appendingPathComponent(filename)
            do {
                try data.write(to: file_url)
            } catch {
                print("[ERROR] Failed to write to \(file_url)")
                interface.disassociate()
                exit(1)
            }
            semaphore.signal()
        }
        task.resume()
    }
    for _ in filenames {
        semaphore.wait()
    }
    print("[INFO] Successfully downloaded \(filenames.count) file(s) from \(console_name)")

    // Disconnect from the Switch hotspot.
    // It doesn't seem to be possible to reconnect back to the previous network here. However,
    // the OS should do it automatically since it won't be connected to any networks at this
    // point. Note that the OS might try to reconnect to the Switch hotspot instead; to prevent
    // this, the Switch's SSID should be configured to *not* auto-join in System Preferences.
    interface.disassociate()
    print("[INFO] Disconnected from \(ssid)")
}

main()
