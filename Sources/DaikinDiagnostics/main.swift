import CelsiusCore
import Darwin
import Foundation

@main
private struct DaikinDiagnostics {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            writeError("Uso: swift run daikin-diagnose <IP_DO_AR>\n")
            exit(EXIT_FAILURE)
        }

        let address = CommandLine.arguments[1]
        guard AppSettings.isValidDaikinAddress(address) else {
            writeError("Endereço IP inválido.\n")
            exit(EXIT_FAILURE)
        }

        guard let key = Keychain.read("daikin-local-key"), !key.isEmpty else {
            writeError("Chave do Daikin não encontrada no Keychain do Celsius. Abra Ajustes, salve a Device Key e tente novamente.\n")
            exit(EXIT_FAILURE)
        }

        do {
            let client = try DaikinClient(address: address, key: key)
            _ = try await client.status(deviceID: "daikin-local")
            print("Sucesso: o Celsius conectou ao Daikin e conseguiu decifrar e interpretar a resposta. A chave não foi exibida.")
        } catch let error as DaikinClientError {
            writeError("Falha na consulta local do Daikin: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        } catch {
            writeError("Falha na consulta local do Daikin (\(String(describing: type(of: error)))). Confirme o IP e se o Mac está na mesma rede. A chave não foi exibida.\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
