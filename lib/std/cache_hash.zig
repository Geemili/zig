const Blake3 = @import("crypto.zig").Blake3;
const fs = @import("fs.zig");
const File = fs.File;
const base64 = @import("base64.zig");
const ArrayList = @import("array_list.zig").ArrayList;
const debug = @import("debug.zig");
const testing = @import("testing.zig");
const mem = @import("mem.zig");
const fmt = @import("fmt.zig");
const Allocator = mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const os = @import("os.zig");

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const base64_pad_char = '=';
const encoder = base64.Base64Encoder.init(base64_alphabet, base64_pad_char);
const decoder = base64.Base64Decoder.init(base64_alphabet, base64_pad_char);
const BIN_DIGEST_LEN = 32;

pub const CacheHashFile = struct {
    path: ?[]const u8,
    stat: fs.File.Stat,
    file_handle: os.fd_t,
    bin_digest: [BIN_DIGEST_LEN]u8,
    contents: ?[]const u8,

    pub fn deinit(self: *@This(), alloc: *Allocator) void {
        if (self.path) |owned_slice| {
            alloc.free(owned_slice);
            self.path = null;
        }
        if (self.contents) |owned_slice| {
            alloc.free(owned_slice);
            self.contents = null;
        }
    }
};

pub const CacheHash = struct {
    alloc: *Allocator,
    blake3: Blake3,
    manifest_dir: []const u8,
    manifest_file_path: ?[]const u8,
    manifest_file: ?File,
    manifest_dirty: bool,
    force_check_manifest: bool,
    files: ArrayList(CacheHashFile),
    b64_digest: ArrayList(u8),

    pub fn init(alloc: *Allocator, manifest_dir_path: []const u8) !@This() {
        return CacheHash{
            .alloc = alloc,
            .blake3 = Blake3.init(),
            .manifest_dir = manifest_dir_path,
            .manifest_file_path = null,
            .manifest_file = null,
            .manifest_dirty = false,
            .force_check_manifest = false,
            .files = ArrayList(CacheHashFile).init(alloc),
            .b64_digest = ArrayList(u8).init(alloc),
        };
    }

    pub fn cache_buf(self: *@This(), val: []const u8) !void {
        debug.assert(self.manifest_file_path == null);

        var temp_buffer = try self.alloc.alloc(u8, val.len + 1);
        defer self.alloc.free(temp_buffer);

        mem.copy(u8, temp_buffer, val);
        temp_buffer[val.len] = 0;

        self.blake3.update(temp_buffer);
    }

    pub fn cache_file(self: *@This(), file_path: []const u8) !void {
        debug.assert(self.manifest_file_path == null);

        var cache_hash_file = try self.files.addOne();
        cache_hash_file.path = try fs.path.resolve(self.alloc, &[_][]const u8{file_path});

        try self.cache_buf(cache_hash_file.path.?);
    }

    pub fn hit(self: *@This(), out_digest: *ArrayList(u8)) !bool {
        debug.assert(self.manifest_file_path == null);

        var bin_digest: [BIN_DIGEST_LEN]u8 = undefined;
        self.blake3.final(&bin_digest);

        const OUT_DIGEST_LEN = base64.Base64Encoder.calcSize(BIN_DIGEST_LEN);
        try self.b64_digest.resize(OUT_DIGEST_LEN);
        encoder.encode(self.b64_digest.toSlice(), &bin_digest);

        if (self.files.toSlice().len == 0 and !self.force_check_manifest) {
            try out_digest.resize(OUT_DIGEST_LEN);
            mem.copy(u8, out_digest.toSlice(), self.b64_digest.toSlice());
            return true;
        }

        self.blake3 = Blake3.init();
        self.blake3.update(&bin_digest);

        {
            const manifest_file_path_slice = try fs.path.join(self.alloc, &[_][]const u8{ self.manifest_dir, self.b64_digest.toSlice() });
            var path_buf = ArrayList(u8).fromOwnedSlice(self.alloc, manifest_file_path_slice);
            defer path_buf.deinit();
            try path_buf.appendSlice(".txt");

            self.manifest_file_path = path_buf.toOwnedSlice();
        }

        const cwd = fs.cwd();

        try cwd.makePath(self.manifest_dir);

        // TODO: Open file with a file lock
        self.manifest_file = try cwd.createFile(self.manifest_file_path.?, .{ .read = true, .truncate = false });

        // TODO: Figure out a good max value?
        const file_contents = try self.manifest_file.?.inStream().stream.readAllAlloc(self.alloc, 16 * 1024);
        defer self.alloc.free(file_contents);

        const input_file_count = self.files.len;
        var any_file_changed = false;
        var line_iter = mem.tokenize(file_contents, "\n");
        var idx: usize = 0;
        while (line_iter.next()) |line| {
            defer idx += 1;

            var cache_hash_file: *CacheHashFile = undefined;
            if (idx < input_file_count) {
                cache_hash_file = self.files.ptrAt(idx);
            } else {
                cache_hash_file = try self.files.addOne();
                cache_hash_file.path = null;
            }

            var iter = mem.tokenize(line, " ");
            const file_handle_str = iter.next() orelse return error.InvalidFormat;
            const mtime_nsec_str = iter.next() orelse return error.InvalidFormat;
            const digest_str = iter.next() orelse return error.InvalidFormat;
            const file_path = iter.rest();

            cache_hash_file.file_handle = fmt.parseInt(os.fd_t, file_handle_str, 10) catch return error.InvalidFormat;
            cache_hash_file.stat.mtime = fmt.parseInt(i64, mtime_nsec_str, 10) catch return error.InvalidFormat;
            decoder.decode(&cache_hash_file.bin_digest, digest_str) catch return error.InvalidFormat;

            if (file_path.len == 0) {
                return error.InvalidFormat;
            }
            if (cache_hash_file.path != null and !mem.eql(u8, file_path, cache_hash_file.path.?)) {
                return error.InvalidFormat;
            }
            cache_hash_file.path = try mem.dupe(self.alloc, u8, file_path);

            const this_file = cwd.openFile(cache_hash_file.path.?, .{ .read = true }) catch {
                self.manifest_file.?.close();
                self.manifest_file = null;
                return error.CacheUnavailable;
            };
            defer this_file.close();
            cache_hash_file.stat = try this_file.stat();
            // TODO: check mtime
            if (false) {} else {
                self.manifest_dirty = true;

                // TODO: check for problematic timestamp

                var actual_digest: [32]u8 = undefined;
                try hash_file(self.alloc, &actual_digest, &this_file);

                if (!mem.eql(u8, &cache_hash_file.bin_digest, &actual_digest)) {
                    mem.copy(u8, &cache_hash_file.bin_digest, &actual_digest);
                    // keep going until we have the input file digests
                    any_file_changed = true;
                }
            }

            if (!any_file_changed) {
                self.blake3.update(&cache_hash_file.bin_digest);
            }
        }

        if (any_file_changed) {
            // cache miss
            // keep the manifest file open (TODO: with rw lock)
            // reset the hash
            self.blake3 = Blake3.init();
            self.blake3.update(&bin_digest);
            try self.files.resize(input_file_count);
            for (self.files.toSlice()) |file| {
                self.blake3.update(&file.bin_digest);
            }
            return false;
        }

        if (idx < input_file_count or idx == 0) {
            self.manifest_dirty = true;
            while (idx < input_file_count) : (idx += 1) {
                var cache_hash_file = self.files.ptrAt(idx);
                self.populate_file_hash(cache_hash_file) catch |err| {
                    self.manifest_file.?.close();
                    self.manifest_file = null;
                    return error.CacheUnavailable;
                };
            }
            return false;
        }

        try self.final(out_digest);
        return true;
    }

    pub fn populate_file_hash(self: *@This(), cache_hash_file: *CacheHashFile) !void {
        debug.assert(cache_hash_file.path != null);

        const this_file = try fs.cwd().openFile(cache_hash_file.path.?, .{});
        defer this_file.close();

        cache_hash_file.stat = try this_file.stat();

        // TODO: check for problematic timestamp

        try hash_file(self.alloc, &cache_hash_file.bin_digest, &this_file);
        self.blake3.update(&cache_hash_file.bin_digest);
    }

    pub fn final(self: *@This(), out_digest: *ArrayList(u8)) !void {
        debug.assert(self.manifest_file_path != null);

        var bin_digest: [BIN_DIGEST_LEN]u8 = undefined;
        self.blake3.final(&bin_digest);

        const OUT_DIGEST_LEN = base64.Base64Encoder.calcSize(BIN_DIGEST_LEN);
        try out_digest.resize(OUT_DIGEST_LEN);
        encoder.encode(out_digest.toSlice(), &bin_digest);
    }

    pub fn write_manifest(self: *@This()) !void {
        debug.assert(self.manifest_file_path != null);

        const OUT_DIGEST_LEN = base64.Base64Encoder.calcSize(BIN_DIGEST_LEN);
        var encoded_digest = try Buffer.initSize(self.alloc, OUT_DIGEST_LEN);
        defer encoded_digest.deinit();
        var contents = try Buffer.init(self.alloc, "");
        defer contents.deinit();

        for (self.files.toSlice()) |file| {
            encoder.encode(encoded_digest.toSlice(), &file.bin_digest);
            try contents.print("{} {} {} {}\n", .{ file.file_handle, file.stat.mtime, encoded_digest.toSlice(), file.path });
        }

        try self.manifest_file.?.seekTo(0);
        try self.manifest_file.?.writeAll(contents.toSlice());
    }

    pub fn release(self: *@This()) void {
        debug.assert(self.manifest_file_path != null);

        if (self.manifest_dirty) {
            self.write_manifest() catch |err| {
                debug.warn("Unable to write cache file '{}': {}\n", .{ self.manifest_file_path, err });
            };
        }

        self.manifest_file.?.close();
        if (self.manifest_file_path) |owned_slice| {
            self.alloc.free(owned_slice);
        }
        for (self.files.toSlice()) |*file| {
            file.deinit(self.alloc);
        }
        self.files.deinit();
        self.b64_digest.deinit();
    }
};

fn hash_file(alloc: *Allocator, bin_digest: []u8, handle: *const File) !void {
    var blake3 = Blake3.init();
    var in_stream = handle.inStream().stream;

    const contents = try handle.inStream().stream.readAllAlloc(alloc, 64 * 1024);
    defer alloc.free(contents);

    blake3.update(contents);

    blake3.final(bin_digest);
}

test "see if imported" {
    const cwd = fs.cwd();

    const temp_manifest_dir = "temp_manifest_dir";

    try cwd.writeFile("test.txt", "Hello, world!\n");

    var digest1 = try ArrayList(u8).initCapacity(testing.allocator, 32);
    defer digest1.deinit();
    var digest2 = try ArrayList(u8).initCapacity(testing.allocator, 32);
    defer digest2.deinit();

    {
        var ch = try CacheHash.init(testing.allocator, temp_manifest_dir);
        defer ch.release();

        try ch.cache_buf("1234");
        try ch.cache_file("test.txt");

        // There should be nothing in the cache
        debug.assert((try ch.hit(&digest1)) == false);

        try ch.final(&digest1);
    }
    {
        var ch = try CacheHash.init(testing.allocator, temp_manifest_dir);
        defer ch.release();

        try ch.cache_buf("1234");
        try ch.cache_file("test.txt");

        // Cache hit! We just "built" the same file
        debug.assert((try ch.hit(&digest2)) == true);
    }

    debug.assert(mem.eql(u8, digest1.toSlice(), digest2.toSlice()));

    try cwd.deleteTree(temp_manifest_dir);
}
