# XAppSession MCP

`XAppConfiguration(mcpEnabled: true)` opts an app into MCP. Its host calls
`XAppSession.mcpServer`, supplies a renderer capture and redraw callback, and
starts/stops the server with the surface lifecycle. MCP is disabled by default.
The built-in transport listens on `127.0.0.1:47321/mcp` and implements the
2025-11-25 initialization and Streamable HTTP request/response flow. It rejects
requests carrying an Origin header and only accepts loopback Host headers.
Any local process can access the endpoint, so enable it only when local control
is intended. A port can be specified when creating the server; if it is already
in use, starting fails. Currently one server listens on a given port.

`screen_state` returns the last frame's identified controls and logical bounds;
`screen_tap` performs a pointer tap by control ID; `screen_pointer` sends a
pointer phase and logical position; `screen_capture` returns the host-provided
rendered XUI surface as PNG. Captures do not include window chrome or native OS
panels. These tools expose UI state, not arbitrary application model fields.
An operation can trigger asynchronous application work; clients should request
state again after the screen has updated. If no frame or capture is available,
the tool returns an error instead of a stale image.

This transport is available where Darwin or Glibc sockets are available. The
server API is renderer-independent; a host with a different platform transport
or screenshot mechanism can supply its own adapter.
