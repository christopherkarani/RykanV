//! Portable declarations for the Linux FUSE kernel/userspace protocol.
//!
//! This module deliberately has no Linux syscall imports so its ABI and codec
//! tests can run on non-Linux development hosts.

pub const kernel_version: u32 = 7;
pub const kernel_minor_version: u32 = 31;
pub const root_id: u64 = 1;
pub const min_read_buffer: usize = 8192;
pub const max_name_len: usize = 255;
pub const max_errno: u16 = 4095;

pub const errno_perm: u16 = 1;
pub const errno_noent: u16 = 2;
pub const errno_io: u16 = 5;
pub const errno_access: u16 = 13;
pub const errno_exist: u16 = 17;
pub const errno_notdir: u16 = 20;
pub const errno_isdir: u16 = 21;
pub const errno_inval: u16 = 22;
pub const errno_nosys: u16 = 38;
pub const errno_notempty: u16 = 39;

pub const Opcode = enum(u32) {
    lookup = 1,
    forget = 2,
    getattr = 3,
    setattr = 4,
    readlink = 5,
    symlink = 6,
    mknod = 8,
    mkdir = 9,
    unlink = 10,
    rmdir = 11,
    rename = 12,
    link = 13,
    open = 14,
    read = 15,
    write = 16,
    statfs = 17,
    release = 18,
    fsync = 20,
    setxattr = 21,
    getxattr = 22,
    listxattr = 23,
    removexattr = 24,
    flush = 25,
    init = 26,
    opendir = 27,
    readdir = 28,
    releasedir = 29,
    fsyncdir = 30,
    getlk = 31,
    setlk = 32,
    setlkw = 33,
    access = 34,
    create = 35,
    interrupt = 36,
    bmap = 37,
    destroy = 38,
    ioctl = 39,
    poll = 40,
    notify_reply = 41,
    batch_forget = 42,
    fallocate = 43,
    readdirplus = 44,
    rename2 = 45,
    lseek = 46,
    copy_file_range = 47,
    setupmapping = 48,
    removemapping = 49,
};

pub const InHeader = extern struct {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    padding: u32,
};

pub const OutHeader = extern struct {
    len: u32,
    err: i32,
    unique: u64,
};

pub const Attr = extern struct {
    ino: u64,
    size: u64,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u32,
    blksize: u32,
    padding: u32,
};

pub const Kstatfs = extern struct {
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    bsize: u32,
    namelen: u32,
    frsize: u32,
    padding: u32,
    spare: [6]u32,
};

pub const FileLock = extern struct {
    start: u64,
    end: u64,
    kind: u32,
    pid: u32,
};

pub const EntryOut = extern struct {
    nodeid: u64,
    generation: u64,
    entry_valid: u64,
    attr_valid: u64,
    entry_valid_nsec: u32,
    attr_valid_nsec: u32,
    attr: Attr,
};

pub const ForgetIn = extern struct {
    nlookup: u64,
};

pub const ForgetOne = extern struct {
    nodeid: u64,
    nlookup: u64,
};

pub const BatchForgetIn = extern struct {
    count: u32,
    dummy: u32,
};

pub const GetattrIn = extern struct {
    getattr_flags: u32,
    dummy: u32,
    fh: u64,
};

pub const AttrOut = extern struct {
    attr_valid: u64,
    attr_valid_nsec: u32,
    dummy: u32,
    attr: Attr,
};

pub const MknodIn = extern struct {
    mode: u32,
    rdev: u32,
    umask: u32,
    padding: u32,
};

pub const MkdirIn = extern struct {
    mode: u32,
    umask: u32,
};

pub const RenameIn = extern struct {
    newdir: u64,
};

pub const Rename2In = extern struct {
    newdir: u64,
    flags: u32,
    padding: u32,
};

pub const LinkIn = extern struct {
    oldnodeid: u64,
};

pub const SetattrIn = extern struct {
    valid: u32,
    padding: u32,
    fh: u64,
    size: u64,
    lock_owner: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    unused4: u32,
    uid: u32,
    gid: u32,
    unused5: u32,
};

pub const OpenIn = extern struct {
    flags: u32,
    unused: u32,
};

pub const CreateIn = extern struct {
    flags: u32,
    mode: u32,
    umask: u32,
    padding: u32,
};

pub const OpenOut = extern struct {
    fh: u64,
    open_flags: u32,
    padding: u32,
};

pub const ReleaseIn = extern struct {
    fh: u64,
    flags: u32,
    release_flags: u32,
    lock_owner: u64,
};

pub const FlushIn = extern struct {
    fh: u64,
    unused: u32,
    padding: u32,
    lock_owner: u64,
};

pub const ReadIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    read_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

pub const WriteIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    write_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

pub const WriteOut = extern struct {
    size: u32,
    padding: u32,
};

pub const StatfsOut = extern struct {
    st: Kstatfs,
};

pub const FsyncIn = extern struct {
    fh: u64,
    fsync_flags: u32,
    padding: u32,
};

pub const SetxattrIn = extern struct {
    size: u32,
    flags: u32,
};

pub const GetxattrIn = extern struct {
    size: u32,
    padding: u32,
};

pub const GetxattrOut = extern struct {
    size: u32,
    padding: u32,
};

pub const LkIn = extern struct {
    fh: u64,
    owner: u64,
    lk: FileLock,
    lk_flags: u32,
    padding: u32,
};

pub const LkOut = extern struct {
    lk: FileLock,
};

pub const AccessIn = extern struct {
    mask: u32,
    padding: u32,
};

pub const InitIn = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
};

pub const InitVersionOut = extern struct {
    major: u32,
    minor: u32,
};

pub const InitOut = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
    max_background: u16,
    congestion_threshold: u16,
    max_write: u32,
    time_gran: u32,
    max_pages: u16,
    map_alignment: u16,
    unused: [8]u32,
};

pub const InterruptIn = extern struct {
    unique: u64,
};

pub const BmapIn = extern struct {
    block: u64,
    blocksize: u32,
    padding: u32,
};

pub const BmapOut = extern struct {
    block: u64,
};

pub const IoctlIn = extern struct {
    fh: u64,
    flags: u32,
    cmd: u32,
    arg: u64,
    in_size: u32,
    out_size: u32,
};

pub const IoctlIovec = extern struct {
    base: u64,
    len: u64,
};

pub const IoctlOut = extern struct {
    result: i32,
    flags: u32,
    in_iovs: u32,
    out_iovs: u32,
};

pub const PollIn = extern struct {
    fh: u64,
    kh: u64,
    flags: u32,
    events: u32,
};

pub const PollOut = extern struct {
    revents: u32,
    padding: u32,
};

pub const FallocateIn = extern struct {
    fh: u64,
    offset: u64,
    length: u64,
    mode: u32,
    padding: u32,
};

pub const Dirent = extern struct {
    ino: u64,
    off: u64,
    namelen: u32,
    kind: u32,
};

pub const LseekIn = extern struct {
    fh: u64,
    offset: u64,
    whence: u32,
    padding: u32,
};

pub const LseekOut = extern struct {
    offset: u64,
};

pub const CopyFileRangeIn = extern struct {
    fh_in: u64,
    off_in: u64,
    nodeid_out: u64,
    fh_out: u64,
    off_out: u64,
    len: u64,
    flags: u64,
};

pub const init_async_read: u32 = 1 << 0;
pub const init_big_writes: u32 = 1 << 5;
pub const init_auto_inval_data: u32 = 1 << 12;
pub const init_writeback_cache: u32 = 1 << 16;
pub const init_parallel_dirops: u32 = 1 << 18;
pub const init_handle_killpriv: u32 = 1 << 19;
pub const init_max_pages: u32 = 1 << 22;
pub const init_map_alignment: u32 = 1 << 26;

pub const open_direct_io: u32 = 1 << 0;
pub const open_keep_cache: u32 = 1 << 1;
pub const open_nonseekable: u32 = 1 << 2;
pub const open_cache_dir: u32 = 1 << 3;
pub const open_stream: u32 = 1 << 4;

pub const dirent_unknown: u32 = 0;
pub const dirent_fifo: u32 = 1;
pub const dirent_char: u32 = 2;
pub const dirent_dir: u32 = 4;
pub const dirent_block: u32 = 6;
pub const dirent_file: u32 = 8;
pub const dirent_symlink: u32 = 10;
pub const dirent_socket: u32 = 12;

comptime {
    if (@sizeOf(InHeader) != 40 or @alignOf(InHeader) != 8) @compileError("invalid FUSE in header ABI");
    if (@sizeOf(OutHeader) != 16 or @alignOf(OutHeader) != 8) @compileError("invalid FUSE out header ABI");
    if (@sizeOf(Attr) != 88 or @alignOf(Attr) != 8) @compileError("invalid FUSE attr ABI");
    if (@sizeOf(Kstatfs) != 80 or @sizeOf(FileLock) != 24) @compileError("invalid FUSE support ABI");
    if (@sizeOf(EntryOut) != 128) @compileError("invalid FUSE entry ABI");
    if (@sizeOf(AttrOut) != 104) @compileError("invalid FUSE attr reply ABI");
    if (@sizeOf(SetattrIn) != 88) @compileError("invalid FUSE setattr ABI");
    if (@sizeOf(ReadIn) != 40 or @sizeOf(WriteIn) != 40) @compileError("invalid FUSE read/write ABI");
    if (@sizeOf(LkIn) != 48 or @sizeOf(IoctlIn) != 32) @compileError("invalid FUSE extended operation ABI");
    if (@sizeOf(InitIn) != 16 or @sizeOf(InitVersionOut) != 8) @compileError("invalid FUSE init input ABI");
    if (@sizeOf(InitOut) != 64) @compileError("invalid FUSE init output ABI");
    if (@sizeOf(Dirent) != 24) @compileError("invalid FUSE directory entry ABI");
    if (@sizeOf(LseekIn) != 24 or @sizeOf(LseekOut) != 8) @compileError("invalid FUSE lseek ABI");
    if (@sizeOf(CopyFileRangeIn) != 56) @compileError("invalid FUSE copy-file-range ABI");
}
