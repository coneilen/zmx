const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.PathRequired;
    if (args.next() != null) return error.InvalidArguments;

    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only });
    defer file.close(init.io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(init.io, &reader_buffer);
    var buffer: [1024 * 1024]u8 = undefined;
    while (true) {
        const amount = try reader.interface.readSliceShort(&buffer);
        if (amount == 0) break;
        hasher.update(buffer[0..amount]);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try writer.interface.print("{s}  {s}\n", .{
        std.fmt.bytesToHex(digest, .lower),
        path,
    });
    try writer.interface.flush();
}
