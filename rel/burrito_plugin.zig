//! Fermix's Burrito plugin, which both Burrito releases build into their
//! wrapper (`burrito: [plugin: ...]` in mix.exs). The wrapper calls it on every
//! run but `fermix maintenance`, before it unpacks its payload or starts the
//! VM.
//!
//! It refuses to start in a working directory the account running it cannot
//! search. Burrito's launcher hands erlexec "-mode embedded" as one argument,
//! which the runtime reads as a flag of that whole name, so the VM boots in
//! interactive mode, whose code path starts with the working directory. When
//! that directory cannot be searched, the code server's start fails to read
//! it, the runtime reports the failure to a logger whose handler is not loaded
//! yet, loading it needs the code server that is still starting, and the VM
//! stops with a crash dump before any Fermix code runs. So the wrapper stops
//! first, with one sentence. It changes no directory itself: a relative path
//! in the command would then name another file.
const std = @import("std");

pub fn burrito_plugin_entry(install_dir: []const u8, program_manifest_json: []const u8) void {
    _ = program_manifest_json;
    // Resolving "." searches the working directory, as the code server's read
    // of it does. Any other answer is not the one that stops the VM, so the
    // VM starts and meets it as it would.
    std.posix.access(".", std.posix.F_OK) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => refuse(install_dir),
        else => {},
    };
}

fn refuse(install_dir: []const u8) noreturn {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = std.posix.getcwd(&buffer) catch "the directory it was run from";
    std.debug.print(
        "fermix: Fermix cannot start in {s}, because the account running it cannot open that directory. Run the command from one it can open, such as /.\n",
        .{directory},
    );
    // The wrapper made the payload's directory just before this call. Before
    // its first unpack it is empty and goes, so a refused run leaves nothing
    // that another release's wrapper would read as an install without its
    // metadata; an unpacked payload is not empty and stays.
    std.fs.deleteDirAbsolute(install_dir) catch |err| switch (err) {
        error.DirNotEmpty, error.FileNotFound => {},
        else => std.debug.print("fermix: the empty directory {s} stays: {t}\n", .{ install_dir, err }),
    };
    std.process.exit(1);
}
