# AGENTS.md

This document provides instructions for AI agents and human developers to understand, build, test, and contribute to the bareiron project.

---

## Project Overview

**bareiron** is a minimalist Minecraft server designed to run on memory-constrained systems, such as the ESP32 microcontroller. The project's priorities are, in order: **memory usage**, **performance**, and **features**.

- [cite\_start]**Target Minecraft Version**: `1.21.8` [cite: 2732]
- **Tech Stack**: The project is a hybrid of **C** and **Zig**. The long-term goal is to incrementally port the performance-critical and logical components from C to Zig to leverage Zig's safety, performance, and compile-time features.
- **Build System**: The primary build system is the **Zig Build System** (`build.zig`). [cite\_start]The project also supports being built as a Cosmopolitan APE (Actually Portable Executable) for maximum cross-platform compatibility, as seen in the GitHub Actions workflow[cite: 2732].

---

## Getting Started & Build Instructions

Follow these steps to set up the development environment and build the project.

### 1\. Dependencies

You will need the following tools installed:

- [cite\_start]**Zig**: Version `0.15.1` or compatible[cite: 2732].
- **A C Compiler**: Such as GCC or Clang.
- [cite\_start]**Java Development Kit (JDK)**: Version 21 or newer is required to dump Minecraft's data registries[cite: 2732].
- [cite\_start]**A JavaScript Runtime**: Node.js, Bun, or Deno is needed to process the dumped registry data[cite: 2732].

### 2\. Generate Game Registries

This is a **mandatory first step**. The server relies on pre-computed data from the official Minecraft server.

1.  [cite\_start]Download the vanilla Minecraft server `.jar` file for version `1.21.8`[cite: 2732].
2.  Run the `extract_registries.sh` script. [cite\_start]It will use the server `.jar` to dump game data into a `notchian` directory and then process it into C header files (`registries.h`, `registries.c`) using the `build_registries.js` script[cite: 2732].

### 3\. Build and Run Commands

- **Build the executable using the Zig Build System**:

  ```sh
  zig build
  ```

  The output binary will be located at `zig-out/bin/bareiron-zig`.

- **Run the server**:

  ```sh
  zig build run
  ```

- **Run Zig tests**:
  Zig's testing framework is used for unit tests. Run tests for a specific file like this:

  ```sh
  zig test src/crafting.zig
  ```

---

## Code Style & Architectural Guidelines

### Code Style

- [cite\_start]**Zig**: Follow the official Zig Style Guide[cite: 2524]. [cite\_start]Key conventions include `TitleCase` for types, `camelCase` for functions, and `snake_case` for variables[cite: 2541]. [cite\_start]Use 4-space indentation[cite: 2539].
- **C**: Match the existing C code style. It is a K\&R-like style with braces on the same line as function and control flow statements.

### C and Zig Interoperability

The project relies heavily on Zig's C interoperability.

- [cite\_start]**Accessing C from Zig**: The `src/c_api.zig` file uses `@cImport` to import all necessary C headers and make C functions and types available within Zig code[cite: 2732].
- [cite\_start]**Accessing Zig from C**: Zig functions intended to be called by C are marked with `export`[cite: 2484]. Their C-compatible function signatures are declared in `include/zig_exports.h`.

### Common Zig Patterns & Pitfalls for C Interop

When porting C code to Zig, several common issues and patterns emerge. Keep these in mind to avoid bugs.

#### 1. C Primitive Types

When using C types imported via `@cImport`, primitive types like `int` or `short` are not accessed through the `c` import struct. Instead, use the built-in `c_` prefixed types.

- **Wrong**: `var my_int: c.int;`
- **Correct**: `var my_int: c_int;`

#### 2. Iterating Over C Arrays

When iterating over a fixed-size C array from Zig, you often need a pointer to each element, not a copy. To do this, you must first create a slice from the array.

- **Wrong (gets a copy)**: `for (c_array) |item| { ... }`
- **Wrong (compile error)**: `for (c_array) |*item| { ... }`
- **Correct (gets a pointer)**: `for (c_array[0..]) |*item| { ... }`

#### 3. Casting Pointers (const)

Zig's type system is stricter about `const` than C. To cast a `*const T` to a `*T`, you must explicitly use `@constCast` before using `@ptrCast`.

- **Wrong (compile error)**: `@ptrCast(my_const_ptr)`
- **Correct**: `@ptrCast(@constCast(my_const_ptr))`

This is common when passing Zig string literals (which are `[]const u8`) to C functions expecting a mutable `char *`.

#### 4. Integer Casting

The `@intCast` builtin is the safest way to convert between integer types. However, the compiler must be able to infer the target type. If it can't (e.g., inside a generic block or a complex expression), you must be explicit.

- **Ambiguous (may fail)**: `break :blk @intCast(my_c_int);`
- **Explicit and Safe**:
  ```zig
  const my_usize: usize = @intCast(my_c_int);
  break :blk my_usize;
  ```
Or, if you are sure the value fits:
- **Explicit (less safe)**: `break :blk @as(usize, my_c_int);`

#### 5. Handling Errors

The compiler may be configured to disallow discarding errors with `_ = err;`. A more robust pattern is to log the error.

- **May Fail**: `myFunc() catch |err| _ = err;`
- **Better**: `myFunc() catch |err| std.log.warn("myFunc failed: {s}", .{@errorName(err)});`

### Architecture

- **State Management**: All global server state is consolidated into a single `ServerContext` struct, defined in both `include/context.h` and `src/state.zig`. This context is passed explicitly to functions that need it, avoiding global variables.
- **Packet Handling**: The main event loop is in `src/main.zig`. The central packet router is `handlePacket` in `src/dispatch.c`, which delegates to state-specific handlers (e.g., `handlePlayPacket`). These sub-handlers are being incrementally ported to Zig (e.g., `src/dispatch_play_chat.zig`).
- **Porting Strategy**: The active goal is to migrate logic from `.c` files to `.zig` files. A good contribution is to pick a function from a file like `procedures.c`, port it to `procedures.zig`, and update the C code to call the new Zig version. **Always ensure the project compiles successfully after porting each function.**

---

## Testing

- **Unit Tests**: Write unit tests in Zig for any new or ported logic. [cite\_start]Use `std.testing.expect` and place tests inside a `test "description" { ... }` block[cite: 111].
- **Manual Testing**: To test the server, run the executable and connect using a Minecraft Java Edition client, version **1.21.8**.

---

## Contribution Guidelines

- **Commit Messages**: Use conventional commit messages (e.g., `feat:`, `fix:`, `refactor(c-port):`). This helps maintain a clear project history.
- **Incremental Changes**: Keep pull requests small and focused on a single task, such as porting a single C function or fixing one bug.
- **Porting C Code**: When porting a C function to Zig:
  1.  Create the idiomatic Zig version in the corresponding `.zig` file (e.g., `procedures.zig`).
  2.  Create an `export`ed, C-compatible wrapper function in Zig.
  3.  Declare the wrapper in `include/zig_exports.h`.
  4.  Replace the C function's body with a call to the Zig wrapper.
  5.  Verify that the project compiles and runs as expected before submitting.
