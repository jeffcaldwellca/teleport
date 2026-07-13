import TeleportKit

/// Runs `body` against `client`, guaranteeing `disconnect()` is awaited
/// before returning on every exit path — success or thrown error. Replaces
/// `defer { Task { await client.disconnect() } }`, which spawns a detached,
/// unawaited Task that can race the process exiting before it's ever
/// scheduled, skipping FTP's QUIT courtesy and SFTP's clean channel close.
func withConnectedClient<T>(
    _ client: RemoteClient,
    _ body: (RemoteClient) async throws -> T
) async throws -> T {
    try await client.connect()
    do {
        let result = try await body(client)
        await client.disconnect()
        return result
    } catch {
        await client.disconnect()
        throw error
    }
}
