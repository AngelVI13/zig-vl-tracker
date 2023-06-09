const std = @import("std");
const xml = @import("xml.zig");

const master_xml = "src/master_cleaning.xml";
const megabyte = 1024 * 1024;

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    var file = try std.fs.cwd().openFile(master_xml, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    var buf: [1 * megabyte]u8 = undefined;
    var n = try in_stream.readAll(&buf);

    std.debug.print("Read {d} bytes", .{n});
}

test "parse open tag without attributes" {
    var allocator = std.heap.page_allocator;
    const document = try xml.parse(&allocator, "<revision>13</revision>");
    defer document.deinit();

    const root = document.root;
    std.debug.print("tag: {s}\n", .{root.tag});

    // try std.testing.expect(std.mem.eql(u8, root.name, "hello"));
}
