# FoundryFabric FoundationDB Binaries

Pre-built native FoundationDB binaries for platforms not covered by the official releases.

## What's here

The [official FDB releases](https://github.com/apple/foundationdb/releases) already provide Linux binaries for both `amd64` and `aarch64` (as `.deb`, `.rpm`, and standalone binaries). **This repo fills the macOS gap** — specifically native `arm64` (Apple Silicon) builds of `libfdb_c.dylib` and the server/CLI tools, needed for CGO-based Go projects running natively on macOS.

## Releases

| Tag | Platform | Notes |
|-----|----------|-------|
| [7.4.6](https://github.com/FoundryFabric/foundationdb/releases/tag/7.4.6) | darwin-arm64 | Latest |
| [7.3.73](https://github.com/FoundryFabric/foundationdb/releases/tag/7.3.73) | darwin-arm64 | |

### Release assets (per version)

| File | Description |
|------|-------------|
| `libfdb_c-darwin-arm64.dylib` | C client library for CGO |
| `fdbserver-darwin-arm64` | FDB server process |
| `fdbcli-darwin-arm64` | FDB CLI client |
| `fdbmonitor` | FDB process monitor |
| `fdb_c.h` | C client header |
| `fdb_c_types.h` | C types header |
| `fdb_c_apiversion.g.h` | API version header (generated) |
| `fdb_c_options.g.h` | Options header (generated) |

### Linux binaries

Use the official FDB releases directly — they already cover `aarch64` and `amd64`:
- Standalone: `fdbserver.aarch64`, `libfdb_c.aarch64.so`, etc.
- Packages: `foundationdb-server_X.Y.Z-1_aarch64.deb`, etc.

## Building a new macOS arm64 release

See [`build-macos-arm64.sh`](./build-macos-arm64.sh) for the full automated build and publish process.

### Prerequisites

```bash
brew install cmake ninja openssl@3 lz4 mono python@3
# Boost 1.86.0 is compiled from source automatically by cmake — no need to install it
```

### Usage

```bash
# Clone this repo to get the build script
git clone https://github.com/FoundryFabric/foundationdb.git foundrydb-scripts
cd foundrydb-scripts

# Run the build script with the FDB version you want
./build-macos-arm64.sh 7.4.6
```

The script will:
1. Clone `apple/foundationdb` at the given tag into a temp directory
2. Apply source patches for macOS arm64 compatibility
3. Configure and build with cmake + ninja (~45 min on Apple Silicon)
4. Create a GitHub release on this repo with all artifacts

### Known build issues (handled automatically by the script)

**1. toml11 incompatibility with CMake 4.x**

toml11 v3.4.0 uses `cmake_minimum_required` syntax removed in CMake 4.x. The script patches the generated cache file after the first configure pass.

**2. Apple ld 1230+ pointer alignment (macOS 15 / Xcode 16+)**

`StringRef` uses `#pragma pack(push, 4)` which reduces struct alignment to 4 bytes despite containing an 8-byte pointer. The new Apple linker enforces 8-byte alignment for globals. The script adds `alignas(8)` to all `const StringRef` / `const KeyRef` global variable definitions (201 instances across 15 source files) before compiling.
