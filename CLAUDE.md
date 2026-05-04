# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build System

UnrealIRCd uses a two-step build process:

```sh
# Step 1: Run interactive configuration (creates config.settings)
./Config

# Step 2: Quick reconfigure using existing config.settings
./Config -quick

# Step 3: Build
make -j4

# Install to ~/unrealircd (as configured)
make install
```

For CI/test builds, use the helper scripts:
```sh
# Build (copies extras/build-tests/nix/configs/default to config.settings)
extras/build-tests/nix/build

# Run the full test suite (clones unrealircd-tests repo and runs it)
extras/build-tests/nix/run-tests
```

The test suite lives in a separate repo (`unrealircd-tests`, cloned at runtime). There is no in-tree test runner. Tests require a built and installed UnrealIRCd. The CI sets `NOSERVICES=1` and `RUNTESTFLAGS="-slightlyfast"` to skip services-dependent tests.

Special compile-time flags used during testing (set via `CPPFLAGS`):
- `-DFAKELAG_CONFIGURABLE` — allows fakelag to be configured for tests
- `-DTESTSUITE` — enables test-only code paths in some modules
- `-DNOREMOVETMP` — keeps temporary files after exit

To build a standalone (third-party) module without touching the main tree:
```sh
make custommodule MODULEFILE=mymodule
```

### Windows

Windows builds use `Makefile.windows` and Visual Studio (see `doc/compiling_win32.txt`).

## Architecture

### Core vs Modules

The daemon is split into a small core (`src/*.c`) and a large collection of dynamically loaded modules (`src/modules/**/*.so`). Almost all IRC commands, channel modes, user modes, and extended bans are modules.

**Core** (`src/`):
- `ircd.c` — startup, main loop, signal handlers
- `parse.c` — IRC message parsing and dispatch
- `send.c` — outgoing message routing
- `channel.c`, `user.c`, `serv.c` — client/channel/server state management
- `conf.c`, `conf_preprocessor.c` — configuration file parsing
- `modules.c` — module loading/unloading
- `tls.c` — TLS via OpenSSL/LibreSSL
- `socket.c`, `dispatch.c`, `fdlist.c` — I/O event loop
- `tkl.c` — TKL (ban) system (*Lines, spamfilters, etc.)
- `log.c` — structured logging

**Module subdirectories**:
- `src/modules/` — IRC commands and server features (one file per command/feature)
- `src/modules/chanmodes/` — channel mode letters (+k, +l, +m, etc.)
- `src/modules/usermodes/` — user mode letters (+o, +i, etc.)
- `src/modules/extbans/` — extended ban types (~a:, ~c:, etc.)
- `src/modules/rpc/` — JSON-RPC handlers

### Key Data Structures

Defined in `include/struct.h` and `include/modules.h`:

- `Client` — represents any connection: user, server, or `&me`. Always accessed via pointer.
  - `client->local` (`LocalClient *`) — non-NULL only for directly connected clients
  - `client->user` (`User *`) — non-NULL only for users
  - `client->server` (`Server *`) — non-NULL only for servers
  - `client->flags`, `client->umodes` — bitfield state
- `Channel` — IRC channel with modes, members, topic
- `Member` / `Membership` — per-(channel,user) pair storing channel membership state and modes

Important predicates (defined in `include/struct.h`):
- `IsUser(client)` / `IsServer(client)` / `IsMe(client)` — client type
- `MyConnect(client)` — directly connected (local) client
- `MyUser(client)` — locally connected user
- `IsOper(client)` / `IsTLS(client)` / `IsULine(client)`

### Module API

Every module exports four lifecycle functions and a `ModuleHeader`:

```c
ModuleHeader MOD_HEADER = { "name", "version", "description", "author", "unrealircd-6" };

MOD_TEST()   { /* register EFunctions/hooks for config checking; return MOD_SUCCESS */ }
MOD_INIT()   { /* register commands, hooks, moddata, modes; return MOD_SUCCESS */ }
MOD_LOAD()   { /* post-load init (all modules loaded); return MOD_SUCCESS */ }
MOD_UNLOAD() { /* cleanup; return MOD_SUCCESS */ }
```

**Commands** — add an IRC command handler:
```c
CommandAdd(modinfo->handle, "KICK", cmd_kick, MAXPARAMS, CMD_USER|CMD_SERVER);
// Handler signature:
CMD_FUNC(cmd_kick) { /* client, recv_mtags, parc, parv[] */ }
```

**Hooks** — subscribe to events:
```c
HookAdd(modinfo->handle, HOOKTYPE_LOCAL_CONNECT, 0, my_connect_hook);
HookAddVoid(modinfo->handle, HOOKTYPE_LOCAL_QUIT, 0, my_quit_hook);
```
Hook types are defined as `HOOKTYPE_*` constants in `include/modules.h` (there are ~100+).

**EFunctions** — replaceable core functions (e.g., `kick_user`, `do_join`):
```c
EfunctionAddVoid(modinfo->handle, EFUNC_KICK_USER, _kick_user);
```

**ModData** — attach arbitrary data to clients, channels, or members:
```c
ModDataInfo *my_md = ModDataAdd(modinfo->handle, mreq); // MODDATATYPE_CLIENT, etc.
moddata_client(client, my_md).ptr = mydata;
```

**Configuration** — hook `HOOKTYPE_CONFIGTEST` and `HOOKTYPE_CONFIGRUN` (or `HOOKTYPE_CONFIGRUN_EX`) to parse custom config blocks.

### Memory Management

**Never use** `malloc`, `calloc`, `strdup`, `free` directly. Use:
- `safe_alloc(size)` — allocates and zeroes (aborts on OOM)
- `safe_free(ptr)` — frees and NULLs
- `safe_strdup(dst, src)` — frees dst if set, then strduplicates src into dst
- `safe_strdup_sensitive()` / `safe_free_sensitive()` — for passwords/secrets (uses libsodium)

### String Functions

Use `strlcpy`/`strlcat` instead of `strcpy`/`strcat`. Use `snprintf` (or the faster `ircsnprintf` for simple formats) instead of `sprintf`.

### Logging

```c
unreal_log(ULOG_INFO, "subsystem", "EVENT_ID", client,
           "Human readable: $variable", log_data_string("variable", value));
```
Log levels: `ULOG_DEBUG`, `ULOG_INFO`, `ULOG_WARNING`, `ULOG_ERROR`, `ULOG_FATAL`.

### Sending Messages

```c
sendnumeric(client, ERR_NOPRIVILEGES);           // send a numeric reply
sendnumeric(client, ERR_NEEDMOREPARAMS, "CMD");  // numeric with args
sendto_server(client, 0, 0, mtags, "...");       // relay to servers
sendto_channel(channel, from, skip, 0, 0, SEND_ALL, mtags, "..."); // channel msg
```

### IRCv3 Message Tags

All command handlers receive `recv_mtags` (incoming tags). When generating new events, always call `new_message(client, recv_mtags, &mtags)` first to create a fresh outgoing tag set, then pass `mtags` to send functions, and `free_message_tags(mtags)` afterwards.

## Code Style

From `doc/coding-guidelines`:
- **Tabs** for indentation (tabsize 8), never spaces
- Brace style: opening brace on its own line
  ```c
  if (condition)
  {
  	body;
  }
  ```
- Use `/* block comments */`, not `// line comments`
- Use enums instead of `#define` constants where possible
- All modules must call `MARK_AS_OFFICIAL_MODULE(modinfo)` in `MOD_INIT()` (for official modules only)

## Nix Build

A `flake.nix` is included for reproducible builds:

```sh
nix build --builders ''    # build the package
nix develop --builders ''  # enter dev shell (adds gdb)
```

**Output layout:**
- `result/bin/unrealircd` — management wrapper script (start/stop/restart/rehash/…)
- `result/bin/unrealircdctl` — symlink to the RPC control utility
- `result/lib/unrealircd/unrealircd` — actual daemon binary
- `result/lib/unrealircd/modules/` — loadable `.so` modules
- `result/etc/unrealircd/` — example/default configuration files

The compiled-in runtime paths (confdir, logdir, etc.) point into the Nix store and are read-only; override them in `unrealircd.conf` or via a NixOS service module for actual deployments.

**Non-obvious packaging facts:**
- `--enable-dynamic-linking` must be passed to bypass the "please use ./Config" guard in `configure`
- `CHECK_SSL` in `autoconf/m4/unreal.m4` defaults to `enable_ssl=no`; must pass `--enable-ssl=${openssl.dev}` to get `CRYPTOLIB="-lssl -lcrypto"` set
- `--with-tmpdir` sets `$TMPDIR` mid-configure (before `config.guess` runs); pre-creating the output directories in `preConfigure` is required to avoid a sandbox write failure
- `scriptdir` (for the management wrapper) and `bindir` (for the daemon) must be different paths or the script overwrites the binary during `make install`

## Key Files for Module Development

- `include/unrealircd.h` — top-level include (include this in all modules)
- `include/modules.h` — full module API: hooks, efunctions, moddata, commands
- `include/struct.h` — all main data structures (`Client`, `Channel`, etc.)
- `include/h.h` — function prototypes, safe_* macros, helper macros
- `include/numeric.h` — IRC numeric reply constants
- `doc/technical/` — server protocol documentation
