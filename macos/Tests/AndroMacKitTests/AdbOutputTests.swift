import Testing
@testable import AndroMacKit

struct AdbOutputTests {

    @Test func parsesDevicesAndSkipsTheChatter() {
        let out = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        emulator-5554\tdevice
        192.168.1.42:37831\tdevice
        R58N12ABCDE\tunauthorized

        """
        #expect(AdbOutput.devices(out) == [
            .init(serial: "emulator-5554", state: "device"),
            .init(serial: "192.168.1.42:37831", state: "device"),
            .init(serial: "R58N12ABCDE", state: "unauthorized"),
        ])
    }

    @Test func parsesMdnsServices() {
        let out = """
        List of discovered mdns services
        adb-26011FDH2003ZX-tI8x5W\t_adb-tls-connect._tcp\t192.168.1.42:37831
        adb-26011FDH2003ZX-tI8x5W\t_adb-tls-pairing._tcp.\t192.168.1.42:41005
        """
        let services = AdbOutput.services(out)
        #expect(services.map(\.type) == ["_adb-tls-connect._tcp", "_adb-tls-pairing._tcp"])
        #expect(services.allSatisfy { $0.host == "192.168.1.42" })
    }

    @Test func findsThePhoneByAddressOrByItsMdnsName() {
        let services = AdbOutput.services("adb-ABC-1\t_adb-tls-connect._tcp\t192.168.1.42:37831")
        let byName = [AdbOutput.Device(serial: "adb-ABC-1._adb-tls-connect._tcp", state: "device")]
        #expect(AdbOutput.ready(byName, at: "192.168.1.42", services: services) == "adb-ABC-1._adb-tls-connect._tcp")

        let byAddress = [AdbOutput.Device(serial: "192.168.1.42:5555", state: "device")]
        #expect(AdbOutput.ready(byAddress, at: "192.168.1.42", services: []) == "192.168.1.42:5555")
        // 192.168.1.4 is a prefix of 192.168.1.42 as text, not as an address.
        #expect(AdbOutput.ready(byAddress, at: "192.168.1.4", services: []) == nil)
        #expect(AdbOutput.ready([.init(serial: "192.168.1.42:5555", state: "offline")], at: "192.168.1.42", services: []) == nil)
    }
}
