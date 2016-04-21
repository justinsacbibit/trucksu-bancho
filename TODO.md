Either enqueue a loginError packet to reset client state,
or maintain server state outside of the application (or both)

Otherwise, when the server restarts, the client and server
states will not be sync'd because the client does not reset
its state when receiving a serverRestart packet.

