- If handling a login for a user that is already in the state, reset that state and remove the user from any channels that they're in
- Add REST API or Phoenix channel(s) for retrieving server state

- Either enqueue a loginError packet to reset client state,
or maintain server state outside of the application (or both)
Otherwise, when the server restarts, the client and server
states will not be sync'd because the client does not reset
its state when receiving a serverRestart packet.
