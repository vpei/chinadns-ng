const std = @import("std");
const build_opts = @import("build_opts");
const g = @import("g.zig");
const c = @import("c.zig");
const cc = @import("cc.zig");
const co = @import("co.zig");
const opt = @import("opt.zig");
const net = @import("net.zig");
const dns = @import("dns.zig");
const log = @import("log.zig");
const server = @import("server.zig");
const Tag = @import("tag.zig").Tag;
const DynStr = @import("DynStr.zig");
const EvLoop = @import("EvLoop.zig");
const Rc = @import("Rc.zig");
const RcMsg = @import("RcMsg.zig");
const Node = @import("Node.zig");
const flags_op = @import("flags_op.zig");
const assert = std.debug.assert;

// ======================================================

comptime {
    // @compileLog("sizeof(Upstream):", @sizeOf(Upstream), "alignof(Upstream):", @alignOf(Upstream));
    // @compileLog("sizeof([]const u8):", @sizeOf([]const u8), "alignof([]const u8):", @alignOf([]const u8));
    // @compileLog("sizeof([:0]const u8):", @sizeOf([:0]const u8), "alignof([:0]const u8):", @alignOf([:0]const u8));
    // @compileLog("sizeof(cc.SockAddr):", @sizeOf(cc.SockAddr), "alignof(cc.SockAddr):", @alignOf(cc.SockAddr));
    // @compileLog("sizeof(Proto):", @sizeOf(Proto), "alignof(Proto):", @alignOf(Proto));
}

const Upstream = @This();

// session
session: ?*anyopaque = null, // `struct UDP` or `struct TCP`

// config
host: ?cc.ConstStr, // DoT SNI
url: cc.ConstStr, // for printing
addr: cc.SockAddr,
max_count: u16 = 10, // max queries per session (0 means no limit)
max_life: u16 = 20, // max lifetime(sec) per session (0 means no limit)
proto: Proto,
tag: Tag,

// ======================================================

/// for `Group.do_add` (at startup)
fn eql(self: *const Upstream, proto: Proto, addr: *const cc.SockAddr, host: []const u8) bool {
    return self.proto == proto and
        self.addr.eql(addr) and
        std.mem.eql(u8, cc.strslice_c(self.host orelse ""), host);
}

/// for `Group.do_add` (at startup)
fn init(tag: Tag, proto: Proto, addr: *const cc.SockAddr, host: []const u8, ip: []const u8, port: u16) Upstream {
    const dupe_host: ?cc.ConstStr = if (host.len > 0)
        (g.allocator.dupeZ(u8, host) catch unreachable).ptr
    else
        null;

    var portbuf: [10]u8 = undefined;
    const url = cc.to_cstr_x(&.{
        // tcp://
        proto.to_str(),
        // host@
        host,
        cc.b2v(host.len > 0, "@", ""),
        // ip
        ip,
        // #port
        cc.b2v(proto.is_std_port(port), "", cc.snprintf(&portbuf, "#%u", .{cc.to_uint(port)})),
    });
    const dupe_url = (g.allocator.dupeZ(u8, cc.strslice_c(url)) catch unreachable).ptr;

    return .{
        .tag = tag,
        .proto = proto,
        .addr = addr.*,
        .host = dupe_host,
        .url = dupe_url,
    };
}

/// for `Group.rm_useless` (at startup)
fn deinit(self: *const Upstream) void {
    assert(self.session == null);

    if (self.host) |host|
        g.allocator.free(cc.strslice_c(host));

    g.allocator.free(cc.strslice_c(self.url));
}

// ======================================================

/// [nosuspend] send query to upstream
fn send(self: *Upstream, qmsg: *RcMsg) void {
    switch (self.proto) {
        .udpi, .udp => if (self.udp_session()) |s| s.send_query(qmsg),
        .tcpi, .tcp, .tls => if (self.tcp_session()) |s| s.send_query(qmsg),
        else => unreachable,
    }
}

fn udp_session(self: *Upstream) ?*UDP {
    return self.get_session(UDP);
}

fn tcp_session(self: *Upstream) ?*TCP {
    return self.get_session(TCP);
}

fn get_session(self: *Upstream, comptime T: type) ?*T {
    if (self.session == null)
        self.session = T.new(self);
    return cc.ptrcast(?*T, self.session);
}

fn session_eql(self: *const Upstream, in_session: ?*const anyopaque) bool {
    return self.session == in_session;
}

// ======================================================

/// for check_timeout (response timeout)
var _session_list: Node = undefined;

pub fn module_init() void {
    _session_list.init();
}

pub fn check_timeout(timer: *EvLoop.Timer) void {
    var it = _session_list.iterator();
    while (it.next()) |node| {
        const typed_node = TypedNode.from_node(node);
        switch (typed_node.type) {
            .udp => {
                const session = UDP.from_typed_node(typed_node);
                if (timer.check_deadline(session.get_deadline()))
                    session.free()
                else
                    break;
            },
            .tcp => {
                const session = TCP.from_typed_node(typed_node);
                if (timer.check_deadline(session.get_deadline()))
                    session.free()
                else
                    break;
            },
        }
    }
}

const TypedNode = struct {
    type: enum { udp, tcp }, // `struct UDP` or `struct TCP`
    node: Node, // _session_list node

    pub fn from_node(node: *Node) *TypedNode {
        return @fieldParentPtr(TypedNode, "node", node);
    }
};

// ======================================================

/// udp session
const UDP = struct {
    typed_node: TypedNode = .{ .type = .udp, .node = undefined }, // _session_list node
    upstream: *Upstream,
    fdobj: *EvLoop.Fd,
    query_list: std.AutoHashMapUnmanaged(u16, void) = .{}, // outstanding queries (qid)
    create_time: u64,
    query_time: u64 = undefined, // last query time
    query_count: u16 = 0, // total query count
    freed: bool = false,

    pub fn new(upstream: *Upstream) ?*UDP {
        const fd = net.new_sock(upstream.addr.family(), .udp) orelse return null;
        const self = g.allocator.create(UDP) catch unreachable;
        self.* = .{
            .upstream = upstream,
            .fdobj = EvLoop.Fd.new(fd),
            .create_time = cc.monotime(),
        };
        return self;
    }

    /// call path:
    /// - recv_reply
    /// - check_timeout
    fn free(self: *UDP) void {
        if (self.freed) return;
        self.freed = true;

        if (!self.is_idle())
            self.typed_node.node.unlink();

        if (self.upstream.session_eql(self))
            self.upstream.session = null;

        self.fdobj.cancel();
        self.fdobj.free();

        self.query_list.clearAndFree(g.allocator);

        g.allocator.destroy(self);
    }

    pub fn from_typed_node(typed_node: *TypedNode) *UDP {
        assert(typed_node.type == .udp);
        return @fieldParentPtr(UDP, "typed_node", typed_node);
    }

    pub fn get_deadline(self: *const UDP) u64 {
        assert(!self.is_idle());
        return self.query_time + cc.to_u64(g.upstream_timeout) * 1000;
    }

    /// [nosuspend]
    pub fn send_query(self: *UDP, qmsg: *RcMsg) void {
        if (self.is_retire()) {
            const new_session = new(self.upstream);
            self.upstream.session = new_session;

            if (new_session) |s|
                s.send_query(qmsg);

            if (self.is_idle())
                self.free();

            return;
        }

        if (self.upstream.tag == .gfw and g.trustdns_packet_n > 1) {
            var iov = [_]cc.iovec_t{
                .{
                    .iov_base = qmsg.msg().ptr,
                    .iov_len = qmsg.len,
                },
            };

            var msgv: [g.TRUSTDNS_PACKET_MAX]cc.mmsghdr_t = undefined;

            msgv[0] = .{
                .msg_hdr = .{
                    .msg_name = &self.upstream.addr,
                    .msg_namelen = self.upstream.addr.len(),
                    .msg_iov = &iov,
                    .msg_iovlen = iov.len,
                },
            };

            // repeat msg
            var i: u8 = 1;
            while (i < g.trustdns_packet_n) : (i += 1)
                msgv[i] = msgv[0];

            _ = cc.sendmmsg(self.fdobj.fd, &msgv, 0) orelse self.on_error("send");
        } else {
            _ = cc.sendto(self.fdobj.fd, qmsg.msg(), 0, &self.upstream.addr) orelse self.on_error("send");
        }

        if (self.is_idle())
            _session_list.link_to_tail(&self.typed_node.node)
        else
            _session_list.move_to_tail(&self.typed_node.node);

        self.query_list.put(g.allocator, dns.get_id(qmsg.msg()), {}) catch unreachable;
        self.query_time = cc.monotime();
        self.query_count +|= 1;

        // start recv coroutine, must be at the end
        if (self.query_count == 1)
            co.start(reply_receiver, .{self}); // may call self.free()
    }

    /// no outstanding queries
    fn is_idle(self: *const UDP) bool {
        return self.query_list.count() == 0;
    }

    /// no more queries will be sent. \
    /// freed when the queries completes.
    fn is_retire(self: *const UDP) bool {
        if (!self.upstream.session_eql(self))
            return true;

        if ((self.upstream.max_count > 0 and self.query_count >= self.upstream.max_count) or
            (self.upstream.max_life > 0 and cc.monotime() >= self.create_time + cc.to_u64(self.upstream.max_life) * 1000))
        {
            self.upstream.session = null;
            return true;
        }

        return false;
    }

    fn reply_receiver(self: *UDP) void {
        defer co.terminate(@frame(), @frameSize(reply_receiver));

        defer self.free();

        var free_rmsg: ?*RcMsg = null;
        defer if (free_rmsg) |rmsg| rmsg.free();

        while (true) {
            const rmsg = free_rmsg orelse RcMsg.new(c.DNS_EDNS_MAXSIZE);
            free_rmsg = null;

            defer {
                if (rmsg.is_unique())
                    free_rmsg = rmsg
                else
                    rmsg.unref();
            }

            const len = g.evloop.read_udp(self.fdobj, rmsg.buf(), null) orelse return self.on_error("recv");
            rmsg.len = cc.to_u16(len);

            // update query_list
            if (len >= dns.header_len()) {
                const qid = dns.get_id(rmsg.msg());
                _ = self.query_list.remove(qid);
            }

            // will modify the msg.id
            nosuspend server.on_reply(rmsg, self.upstream);

            // all queries completed
            if (self.is_idle()) {
                self.typed_node.node.unlink();
                if (self.is_retire()) return; // free
            }
        }
    }

    fn on_error(self: *const UDP, op: cc.ConstStr) void {
        if (!self.fdobj.canceled)
            log.warn(@src(), "%s(%s) failed: (%d) %m", .{ op, self.upstream.url, cc.errno() });
    }
};

// ======================================================

pub const has_tls = build_opts.enable_wolfssl;

pub const TLS = struct {
    ssl: ?*c.WOLFSSL = null,

    var _ctx: ?*c.WOLFSSL_CTX = null;

    /// called at startup
    pub fn init() void {
        if (_ctx != null) return;

        cc.SSL_library_init();

        const ctx = cc.SSL_CTX_new();
        _ctx = ctx;

        if (g.cert_verify) {
            const src = @src();
            if (g.ca_certs.is_null())
                cc.SSL_CTX_load_sys_CA_certs(ctx) orelse {
                    log.err(src, "failed to load system CA certs, please provide --ca-certs", .{});
                    cc.exit(1);
                }
            else
                cc.SSL_CTX_load_CA_certs(ctx, g.ca_certs.cstr()) orelse {
                    log.err(src, "failed to load CA certs: %s", .{g.ca_certs.cstr()});
                    cc.exit(1);
                };
        }
    }

    pub fn new_ssl(self: *TLS, fd: c_int, host: ?cc.ConstStr) ?void {
        assert(self.ssl == null);

        const ssl = cc.SSL_new(_ctx.?);

        var ok = false;
        defer if (!ok) cc.SSL_free(ssl);

        cc.SSL_set_fd(ssl, fd) orelse return null;
        cc.SSL_set_host(ssl, host, g.cert_verify) orelse return null;

        ok = true;
        self.ssl = ssl;
    }

    // free the ssl obj
    pub fn on_close(self: *TLS) void {
        const ssl = self.ssl orelse return;
        self.ssl = null;

        cc.SSL_free(ssl);
    }
};

/// tcp/tls session
const TCP = struct {
    typed_node: TypedNode = .{ .type = .tcp, .node = undefined }, // _session_list node
    upstream: *Upstream,
    fdobj: ?*EvLoop.Fd = null, // tcp connection
    tls: TLS_ = .{}, // tls connection (DoT)
    send_list: MsgQueue = .{}, // qmsg to be sent
    ack_list: std.AutoHashMapUnmanaged(u16, *RcMsg) = .{}, // qmsg to be ack
    create_time: u64, // last connect time
    query_time: u64 = undefined, // last query time
    query_count: u16 = 0, // total query count
    pending_n: u16 = 0, // outstanding queries: send_list + ack_list
    healthy: bool = false, // current connection processed at least one query
    freed: bool = false,
    stopping: bool = false,

    const TLS_ = if (has_tls) TLS else struct {};

    /// must <= u16_max
    const PENDING_MAX = std.math.maxInt(u16);

    const MsgQueue = struct {
        head: ?*Msg = null,
        tail: ?*Msg = null,
        waiter: ?anyframe = null,

        const Msg = struct {
            msg: *RcMsg,
            next: *Msg,
        };

        fn co_data() *?*RcMsg {
            return co.data(?*RcMsg);
        }

        fn do_push(self: *MsgQueue, msg: *RcMsg, pos: enum { front, back }) void {
            if (self.waiter) |waiter| {
                assert(self.is_empty());
                co_data().* = msg;
                co.do_resume(waiter);
                return;
            }

            const node = g.allocator.create(Msg) catch unreachable;
            node.* = .{
                .msg = msg,
                .next = undefined,
            };

            if (self.is_empty()) {
                self.head = node;
                self.tail = node;
            } else switch (pos) {
                .front => {
                    node.next = self.head.?;
                    self.head = node;
                },
                .back => {
                    self.tail.?.next = node;
                    self.tail = node;
                },
            }
        }

        pub fn push(self: *MsgQueue, msg: *RcMsg) void {
            return self.do_push(msg, .back);
        }

        pub fn push_front(self: *MsgQueue, msg: *RcMsg) void {
            return self.do_push(msg, .front);
        }

        /// `null`: cancel wait
        pub fn pop(self: *MsgQueue, comptime suspending: bool) ?*RcMsg {
            if (self.head) |node| {
                defer g.allocator.destroy(node);
                if (node == self.tail) {
                    self.head = null;
                    self.tail = null;
                } else {
                    self.head = node.next;
                    assert(self.tail != null);
                }
                return node.msg;
            } else {
                if (!suspending)
                    return null;
                self.waiter = @frame();
                suspend {}
                self.waiter = null;
                return co_data().*;
            }
        }

        pub fn cancel_wait(self: *const MsgQueue) void {
            if (self.waiter) |waiter| {
                assert(self.is_empty());
                co_data().* = null;
                co.do_resume(waiter);
            }
        }

        pub fn is_empty(self: *const MsgQueue) bool {
            return self.head == null;
        }

        /// clear && msg.unref()
        pub fn clear(self: *MsgQueue) void {
            while (self.pop(false)) |msg|
                msg.unref();
        }
    };

    pub fn new(upstream: *Upstream) *TCP {
        const self = g.allocator.create(TCP) catch unreachable;
        self.* = .{
            .upstream = upstream,
            .create_time = cc.monotime(),
        };
        return self;
    }

    pub fn free(self: *TCP) void {
        if (self.freed) return;
        self.freed = true;

        if (!self.is_idle())
            self.typed_node.node.unlink();

        if (self.upstream.session_eql(self))
            self.upstream.session = null;

        if (self.fdobj) |fdobj| {
            fdobj.cancel();
            fdobj.free();
        }

        if (has_tls)
            self.tls.on_close();

        self.send_list.cancel_wait();
        self.send_list.clear();
        self.clear_ack_list(.unref);

        g.allocator.destroy(self);
    }

    pub fn from_typed_node(typed_node: *TypedNode) *TCP {
        assert(typed_node.type == .tcp);
        return @fieldParentPtr(TCP, "typed_node", typed_node);
    }

    pub fn get_deadline(self: *const TCP) u64 {
        assert(!self.is_idle());
        return self.query_time + cc.to_u64(g.upstream_timeout) * 1000;
    }

    /// no outstanding queries
    fn is_idle(self: *const TCP) bool {
        return self.pending_n == 0;
    }

    /// no more queries will be sent. \
    /// freed when the queries completes.
    fn is_retire(self: *const TCP) bool {
        if (!self.upstream.session_eql(self))
            return true;

        if ((self.upstream.max_count > 0 and self.query_count >= self.upstream.max_count) or
            (self.upstream.max_life > 0 and cc.monotime() >= self.create_time + cc.to_u64(self.upstream.max_life) * 1000))
        {
            self.upstream.session = null;
            return true;
        }

        return false;
    }

    /// add to send queue, `qmsg.ref++`
    pub fn send_query(self: *TCP, qmsg: *RcMsg) void {
        if (self.is_retire()) {
            const new_session = new(self.upstream);
            self.upstream.session = new_session;

            new_session.send_query(qmsg);

            if (self.is_idle())
                self.free();

            return;
        }

        if (self.pending_n >= PENDING_MAX) {
            log.warn(@src(), "too many pending queries: %u", .{cc.to_uint(self.pending_n)});
            return;
        }

        if (self.is_idle())
            _session_list.link_to_tail(&self.typed_node.node)
        else
            _session_list.move_to_tail(&self.typed_node.node);

        self.pending_n += 1;
        self.send_list.push(qmsg.ref());

        self.query_time = cc.monotime();
        self.query_count +|= 1;

        if (self.fdobj == null)
            self.start();
    }

    /// [suspending] pop from send_list && add to ack_list
    fn pop_qmsg(self: *TCP) ?*RcMsg {
        const qmsg = self.send_list.pop(true) orelse return null;
        self.on_query(qmsg);
        return qmsg;
    }

    /// add qmsg to ack_list
    fn on_query(self: *TCP, qmsg: *RcMsg) void {
        const qid = dns.get_id(qmsg.msg());
        if (self.ack_list.fetchPut(g.allocator, qid, qmsg) catch unreachable) |old| {
            old.value.unref();
            self.pending_n -= 1;
            assert(self.pending_n > 0);
            log.warn(@src(), "duplicated qid:%u to %s", .{ cc.to_uint(qid), self.upstream.url });
        }
    }

    /// remove qmsg from ack_list && qmsg.unref()
    fn on_reply(self: *TCP, rmsg: *const RcMsg) void {
        const qid = dns.get_id(rmsg.msg());
        if (self.ack_list.fetchRemove(qid)) |kv| {
            self.healthy = true;
            self.pending_n -= 1;
            kv.value.unref();
        } else {
            log.warn(@src(), "unexpected msg_id:%u from %s", .{ cc.to_uint(qid), self.upstream.url });
        }
    }

    fn on_stop(self: *TCP) void {
        if (self.stopping) return;

        {
            // cleanup
            self.stopping = true;
            defer self.stopping = false;

            self.send_list.cancel_wait();

            if (self.fdobj) |fdobj| {
                fdobj.cancel();
                fdobj.free();
                self.fdobj = null;
            }

            if (has_tls)
                self.tls.on_close();
        }

        if (self.pending_n > 0) {
            // restart
            if (self.healthy) {
                self.clear_ack_list(.resend);
                self.start();
            } else {
                self.clear_ack_list(.unref);
                self.send_list.clear();
                self.pending_n = 0;
                self.typed_node.node.unlink();
                if (self.is_retire()) self.free();
            }
        } else {
            // idle
            if (self.is_retire()) self.free();
        }
    }

    fn clear_ack_list(self: *TCP, op: enum { resend, unref }) void {
        var it = self.ack_list.valueIterator();
        while (it.next()) |value_ptr| {
            const qmsg = value_ptr.*;
            switch (op) {
                .resend => self.send_list.push_front(qmsg),
                .unref => qmsg.unref(),
            }
        }
        self.ack_list.clearRetainingCapacity();
    }

    fn start(self: *TCP) void {
        assert(self.fdobj == null);
        assert(self.pending_n > 0);
        assert(!self.send_list.is_empty());
        assert(self.ack_list.count() == 0);

        self.healthy = false;
        self.create_time = cc.monotime();

        co.start(query_sender, .{self});
    }

    fn query_sender(self: *TCP) void {
        defer co.terminate(@frame(), @frameSize(query_sender));

        defer self.on_stop();

        const fd = net.new_tcp_conn_sock(self.upstream.addr.family()) orelse return;
        self.fdobj = EvLoop.Fd.new(fd);

        self.connect() orelse return;

        co.start(reply_receiver, .{self});

        while (self.pop_qmsg()) |qmsg|
            self.send(qmsg) orelse return;
    }

    fn reply_receiver(self: *TCP) void {
        defer co.terminate(@frame(), @frameSize(reply_receiver));

        defer self.on_stop();

        var free_rmsg: ?*RcMsg = null;
        defer if (free_rmsg) |rmsg| rmsg.free();

        while (true) {
            // read the len
            var len: u16 = undefined;
            self.recv(std.mem.asBytes(&len)) orelse return;

            // check the len
            len = cc.ntohs(len);
            if (len < dns.header_len()) {
                log.warn(@src(), "recv(%s) failed: invalid len:%u", .{ self.upstream.url, cc.to_uint(len) });
                return;
            }

            const rmsg: *RcMsg = if (free_rmsg) |rmsg| rmsg.realloc(len) else RcMsg.new(len);
            free_rmsg = null;

            defer {
                if (rmsg.is_unique())
                    free_rmsg = rmsg
                else
                    rmsg.unref();
            }

            // read the msg
            rmsg.len = len;
            self.recv(rmsg.msg()) orelse return;

            // update ack_list
            self.on_reply(rmsg);

            // will modify the msg.id
            nosuspend server.on_reply(rmsg, self.upstream);

            // all queries completed
            if (self.is_idle()) {
                self.typed_node.node.unlink();
                if (self.is_retire()) return; // stop and free
            }
        }
    }

    /// `errmsg`: null means strerror(errno)
    noinline fn on_error(self: *const TCP, op: cc.ConstStr, errmsg: ?cc.ConstStr) ?void {
        const src = @src();

        if (errmsg) |msg|
            log.warn(src, "%s(%s) failed: %s", .{ op, self.upstream.url, msg })
        else
            log.warn(src, "%s(%s) failed: (%d) %m", .{ op, self.upstream.url, cc.errno() });

        return null;
    }

    fn ssl(self: *const TCP) *c.WOLFSSL {
        return self.tls.ssl.?;
    }

    fn connect(self: *TCP) ?void {
        // null means strerror(errno)
        const errmsg: ?cc.ConstStr = e: {
            const fdobj = self.fdobj.?;
            g.evloop.connect(fdobj, &self.upstream.addr) orelse break :e null;

            if (has_tls and self.upstream.proto == .tls) {
                self.tls.new_ssl(fdobj.fd, self.upstream.host) orelse break :e "unable to create ssl object";

                while (true) {
                    var err: c_int = undefined;
                    cc.SSL_connect(self.ssl(), &err) orelse switch (err) {
                        c.WOLFSSL_ERROR_WANT_READ => {
                            g.evloop.wait_readable(fdobj) orelse return null;
                            continue;
                        },
                        c.WOLFSSL_ERROR_WANT_WRITE => {
                            g.evloop.wait_writable(fdobj) orelse return null;
                            continue;
                        },
                        else => {
                            break :e cc.SSL_error_string(err);
                        },
                    };
                    break;
                }

                if (g.verbose())
                    log.info(@src(), "%s | %s | %s", .{
                        self.upstream.url,
                        cc.SSL_get_version(self.ssl()),
                        cc.SSL_get_cipher(self.ssl()),
                    });
            }

            return;
        };

        return self.on_error("connect", errmsg);
    }

    fn send(self: *TCP, qmsg: *RcMsg) ?void {
        // null means strerror(errno)
        const errmsg: ?cc.ConstStr = e: {
            const fdobj = self.fdobj.?;

            if (self.upstream.proto != .tls) {
                var iovec = [_]cc.iovec_t{
                    .{
                        .iov_base = std.mem.asBytes(&cc.htons(qmsg.len)),
                        .iov_len = @sizeOf(u16),
                    },
                    .{
                        .iov_base = qmsg.msg().ptr,
                        .iov_len = qmsg.len,
                    },
                };
                g.evloop.writev(fdobj, &iovec) orelse break :e null;
            } else if (has_tls) {
                // merge into one ssl record
                var buf: [2 + c.DNS_QMSG_MAXSIZE]u8 align(2) = undefined;
                const data = buf[0 .. 2 + qmsg.len];
                std.mem.bytesAsValue(u16, data[0..2]).* = cc.htons(qmsg.len);
                @memcpy(data[2..].ptr, qmsg.msg().ptr, qmsg.len);

                while (true) {
                    var err: c_int = undefined;
                    cc.SSL_write(self.ssl(), data, &err) orelse switch (err) {
                        c.WOLFSSL_ERROR_WANT_WRITE => {
                            g.evloop.wait_writable(fdobj) orelse return null;
                            continue;
                        },
                        else => {
                            break :e cc.SSL_error_string(err);
                        },
                    };
                    break;
                }
            } else unreachable;

            return;
        };

        return self.on_error("send", errmsg);
    }

    /// read the `buf` full
    fn recv(self: *TCP, buf: []u8) ?void {
        // null means strerror(errno)
        const errmsg: ?cc.ConstStr = e: {
            const fdobj = self.fdobj.?;

            if (self.upstream.proto != .tls) {
                g.evloop.read(fdobj, buf) catch |err| switch (err) {
                    error.eof => return null,
                    error.errno => break :e null,
                };
            } else if (has_tls) {
                var nread: usize = 0;
                while (nread < buf.len) {
                    var err: c_int = undefined;
                    const n = cc.SSL_read(self.ssl(), buf[nread..], &err) orelse switch (err) {
                        c.WOLFSSL_ERROR_ZERO_RETURN => { // TLS EOF
                            return null;
                        },
                        c.WOLFSSL_ERROR_WANT_READ => {
                            g.evloop.wait_readable(fdobj) orelse return null;
                            continue;
                        },
                        else => {
                            break :e cc.SSL_error_string(err);
                        },
                    };
                    nread += n;
                }
            } else unreachable;

            return;
        };

        return self.on_error("recv", errmsg);
    }
};

// ======================================================

pub const Proto = enum {
    raw, // "1.1.1.1" (tcpi + udpi) only exists in the parsing stage
    udpi, // "udpi://1.1.1.1" (enabled when the query msg is received over udp)
    tcpi, // "tcpi://1.1.1.1" (enabled when the query msg is received over tcp)

    udp, // "udp://1.1.1.1"
    tcp, // "tcp://1.1.1.1"
    tls, // "tls://1.1.1.1"

    /// "tcp://"
    pub fn from_str(str: []const u8) ?Proto {
        const map = if (has_tls) .{
            .{ .str = "udp://", .proto = .udp },
            .{ .str = "tcp://", .proto = .tcp },
            .{ .str = "tls://", .proto = .tls },
        } else .{
            .{ .str = "udp://", .proto = .udp },
            .{ .str = "tcp://", .proto = .tcp },
        };
        inline for (map) |v| {
            if (std.mem.eql(u8, str, v.str))
                return v.proto;
        }
        return null;
    }

    /// "tcp://" (string literal)
    pub fn to_str(self: Proto) [:0]const u8 {
        return switch (self) {
            .udpi => "udpi://",
            .tcpi => "tcpi://",
            .udp => "udp://",
            .tcp => "tcp://",
            .tls => "tls://",
            else => unreachable,
        };
    }

    pub fn require_host(self: Proto) bool {
        return self == .tls;
    }

    pub fn std_port(self: Proto) u16 {
        return switch (self) {
            .tls => 853,
            else => 53,
        };
    }

    pub fn is_std_port(self: Proto, port: u16) bool {
        return port == self.std_port();
    }
};

// ======================================================

pub const Group = struct {
    list: std.ArrayListUnmanaged(Upstream) = .{},

    pub inline fn items(self: *const Group) []Upstream {
        return self.list.items;
    }

    pub inline fn is_empty(self: *const Group) bool {
        return self.items().len == 0;
    }

    // ======================================================

    fn parse_failed(msg: [:0]const u8, value: []const u8) ?void {
        opt.print(@src(), msg, value);
        return null;
    }

    /// "[proto://][host@]ip[#port]"
    pub fn add(self: *Group, tag: Tag, in_value: []const u8) ?void {
        @setCold(true);

        var value = in_value;

        // proto
        const proto = b: {
            if (std.mem.indexOf(u8, value, "://")) |i| {
                const proto = value[0 .. i + 3];
                value = value[i + 3 ..];
                break :b Proto.from_str(proto) orelse
                    return parse_failed("invalid proto", proto);
            }
            break :b Proto.raw;
        };

        // host, only DoT needs it
        const host = b: {
            if (std.mem.indexOf(u8, value, "@")) |i| {
                const host = value[0..i];
                value = value[i + 1 ..];
                if (host.len == 0)
                    return parse_failed("invalid host", host);
                if (!proto.require_host())
                    return parse_failed("no host required", host);
                break :b host;
            }
            break :b "";
        };

        // port
        const port = b: {
            if (std.mem.indexOfScalar(u8, value, '#')) |i| {
                const port = value[i + 1 ..];
                value = value[0..i];
                break :b opt.check_port(port) orelse return null;
            }
            break :b proto.std_port();
        };

        // TODO: ?count=10 ?life=20

        // ip
        const ip = value;
        opt.check_ip(ip) orelse return null;

        if (proto == .raw) {
            // `bind_tcp/bind_udp` conditions can't be checked because `opt.parse()` is being executed
            self.do_add(tag, .udpi, host, ip, port);
            self.do_add(tag, .tcpi, host, ip, port);
        } else {
            self.do_add(tag, proto, host, ip, port);
        }
    }

    fn do_add(self: *Group, tag: Tag, proto: Proto, host: []const u8, ip: []const u8, port: u16) void {
        const addr = cc.SockAddr.from_text(cc.to_cstr(ip), port);

        for (self.items()) |*upstream| {
            if (upstream.eql(proto, &addr, host))
                return;
        }

        const ptr = self.list.addOne(g.allocator) catch unreachable;
        ptr.* = Upstream.init(tag, proto, &addr, host, ip, port);
    }

    pub fn rm_useless(self: *Group) void {
        @setCold(true);

        var has_udpi = false;
        var has_tcpi = false;
        for (g.bind_ports) |p| {
            if (p.udp) has_udpi = true;
            if (p.tcp) has_tcpi = true;
        }

        var len = self.items().len;
        while (len > 0) : (len -= 1) {
            const i = len - 1;
            const upstream = &self.items()[i];
            const rm = switch (upstream.proto) {
                .udpi => !has_udpi,
                .tcpi => !has_tcpi,
                else => continue,
            };
            if (rm) {
                upstream.deinit();
                _ = self.list.orderedRemove(i);
            }
        }
    }

    // ======================================================

    /// [nosuspend]
    pub fn send(self: *Group, qmsg: *RcMsg, from_tcp: bool) void {
        const verbose_info = if (g.verbose()) .{
            .qid = dns.get_id(qmsg.msg()),
            .from = cc.b2s(from_tcp, "tcp", "udp"),
        } else undefined;

        const in_proto: Proto = if (from_tcp) .tcpi else .udpi;

        for (self.items()) |*upstream| {
            if (upstream.proto == .tcpi or upstream.proto == .udpi)
                if (upstream.proto != in_proto) continue;

            if (g.verbose())
                log.info(
                    @src(),
                    "forward query(qid:%u, from:%s) to upstream %s",
                    .{ cc.to_uint(verbose_info.qid), verbose_info.from, upstream.url },
                );

            nosuspend upstream.send(qmsg);
        }
    }
};
