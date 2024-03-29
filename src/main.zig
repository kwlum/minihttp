const std = @import("std");
const ascii = std.ascii;
const http = std.http;
const io = std.io;
const mem = std.mem;
const os = std.os;

const httpparser = @import("httpparser");
const xev = @import("xev");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

const Headers = struct {
    inner: [64]httpparser.Header,
    pos: usize,

    const Error = error{
        TooManyHeaders,
    };

    const Iterator = struct {
        slice: []const httpparser.Header,
        index: usize,

        fn next(self: *Iterator) ?Header {
            if (self.index < self.slice.len) {
                const i = self.index;
                self.index += 1;

                return .{
                    .name = self.slice[i].name,
                    .value = self.slice[i].value,
                };
            } else {
                return null;
            }
        }
    };

    fn init() Headers {
        return .{
            .inner = undefined,
            .pos = 0,
        };
    }

    pub fn iterator(self: *const Headers) Iterator {
        return .{
            .slice = self.inner[0..self.pos],
            .index = 0,
        };
    }

    pub fn put(self: *Headers, name: []const u8, value: []const u8) Error!void {
        if (self.pos >= self.inner.len) return Error.TooManyHeaders;

        self.inner[self.pos].name = name;
        self.inner[self.pos].value = value;
        self.pos += 1;
    }
};

pub const Request = struct {
    method: http.Method,
    path: []const u8,
    headers: Headers,
    body: []const u8,
};

pub const Response = struct {
    status: http.Status,
    headers: Headers,
    body: io.FixedBufferStream([]align(8) u8).Writer,
};

const HttpCodec = struct {
    fn decode(buffer: []const u8) !Request {
        var request: Request = undefined;
        request.headers = Headers.init();
        var http_request = httpparser.Request.init(&request.headers.inner);
        try http_request.parse(buffer);

        request.path = http_request.path orelse "/";
        request.body = http_request.payload orelse "";
        request.method = .GET; // default

        if (http_request.method) |a| {
            var lower_buf: [16]u8 = undefined;
            const method_string = ascii.lowerString(&lower_buf, a);

            request.method = if (mem.eql(u8, method_string, "get"))
                .GET
            else if (mem.eql(u8, method_string, "post"))
                .POST
            else if (mem.eql(u8, method_string, "put"))
                .PUT
            else if (mem.eql(u8, method_string, "delete"))
                .DELETE
            else if (mem.eql(u8, method_string, "head"))
                .HEAD
            else if (mem.eql(u8, method_string, "connect"))
                .CONNECT
            else if (mem.eql(u8, method_string, "options"))
                .OPTIONS
            else if (mem.eql(u8, method_string, "trace"))
                .TRACE
            else if (mem.eql(u8, method_string, "patch"))
                .PATCH
            else
                .GET;
        }

        return request;
    }

    fn encode(
        response: Response,
        body: []const u8,
        out_buffer: []u8,
    ) ![]const u8 {
        var fbs = io.fixedBufferStream(out_buffer);
        var writer = fbs.writer();
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{
            @enumToInt(response.status),
            response.status.phrase() orelse "",
        });

        try writer.print("content-length: {d}\r\n", .{body.len});

        var headers_itr = response.headers.iterator();
        while (headers_itr.next()) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        _ = try fbs.write("\r\n");
        _ = try fbs.write(body);

        return fbs.getWritten();
    }
};

const BufferPool = std.heap.MemoryPool([4096]u8);
const CompletionPool = std.heap.MemoryPool(xev.Completion);

const Command = union(enum) {
    new_client: xev.TCP,
    stop: void,
};

const CommandQueue = struct {
    commands: std.atomic.Queue(Command),
    notifier: xev.Async,

    const Self = @This();

    fn push(self: *Self, allocator: mem.Allocator, command: Command) !void {
        var node = try allocator.create(std.TailQueue(Command).Node);
        node.* = .{ .data = command };
        self.commands.put(node);
        try self.notifier.notify();
    }
};

const Accept = struct {
    allocator: mem.Allocator,
    buffer_pool: BufferPool,
    completion_pool: CompletionPool,
    socket: xev.TCP,
    next_id: usize = 0,
    workers: []*CommandQueue,
    commands: CommandQueue,
    stop: bool = false,

    const Self = @This();

    fn init(
        allocator: mem.Allocator,
        socket: xev.TCP,
        workers: []*CommandQueue,
    ) !Accept {
        var commands: CommandQueue = .{
            .notifier = try xev.Async.init(),
            .commands = std.atomic.Queue(Command).init(),
        };

        return .{
            .allocator = allocator,
            .buffer_pool = BufferPool.init(allocator),
            .completion_pool = CompletionPool.init(allocator),
            .socket = socket,
            .workers = workers,
            .commands = commands,
            .next_id = 0,
        };
    }

    fn deinit(self: *Self) void {
        std.log.debug("Accept.deinit [{}]", .{std.Thread.getCurrentId()});
        self.commands.notifier.deinit();
        self.completion_pool.deinit();
        self.buffer_pool.deinit();
    }

    fn start(self: *Self) !void {
        const completion = try self.completion_pool.create();
        self.commands.notifier.wait(localLoop(), completion, Self, self, onWake);
        self.accept(localLoop());
    }

    fn onWake(
        self_: ?*Self,
        ev_loop: *xev.Loop,
        completion: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;
        const self = self_.?;
        defer self.completion_pool.destroy(completion);

        std.log.debug("Accept.onWake [{}]", .{std.Thread.getCurrentId()});

        while (self.commands.commands.get()) |node| {
            defer self.allocator.destroy(node);
            const command = node.data;

            switch (command) {
                .new_client => {},
                .stop => {
                    self.stop = true;
                    ev_loop.stop();
                    return .disarm;
                },
            }
        }

        const c = self.completion_pool.create() catch unreachable;
        self.commands.notifier.wait(ev_loop, c, Self, self, onWake);

        return .disarm;
    }

    fn accept(self: *Self, ev_loop: *xev.Loop) void {
        if (self.stop) return;

        std.log.debug("Accept.accept [{}]", .{std.Thread.getCurrentId()});

        const completion = self.completion_pool.create() catch unreachable;
        self.socket.accept(ev_loop, completion, Self, self, onAccept);
    }

    fn onAccept(
        self_: ?*Self,
        ev_loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        const self = self_.?;
        std.log.debug("Accept.onAccept [{}]", .{std.Thread.getCurrentId()});

        defer {
            if (completion.state() == .dead) {
                self.completion_pool.destroy(completion);
            }
        }

        const client_socket = result catch |err| {
            std.log.err("Accept.onAccept - result :: {}", .{err});
            return .disarm;
        };

        self.next_id += 1;
        var i: usize = 0;
        while (i < self.workers.len) : (i += 1) {
            const index = (self.next_id + i) % self.workers.len;
            self.workers[index].push(self.allocator, .{ .new_client = client_socket }) catch |err| {
                std.log.err("Accept.onAccept - add client to worker :: {}", .{err});
                continue;
            };

            break;
        }

        self.accept(ev_loop);

        return .disarm;
    }
};

// Client request worker.

const RequestHandler = struct {
    service: *anyopaque,
    state: ?*anyopaque,
    on_request_fn: *const fn (*anyopaque, ?*anyopaque, *Request, *Response) anyerror!void,
    service_deinit_fn: *const fn (*anyopaque, mem.Allocator) void,

    const Self = @This();

    fn init(
        state: ?*anyopaque,
        comptime Service: type,
        allocator: mem.Allocator,
    ) !RequestHandler {
        const service_alignment = @typeInfo(*Service).Pointer.alignment;

        const S = struct {
            fn onRequest(
                service_: *anyopaque,
                state_: ?*anyopaque,
                request: *Request,
                response: *Response,
            ) !void {
                const service = @ptrCast(*Service, @alignCast(service_alignment, service_));

                if (@hasField(Service, "state")) {
                    const State = @TypeOf(@field(service, "state"));
                    const state_info = @typeInfo(State);

                    if (state_) |a| {
                        const st = @ptrCast(State, @alignCast(state_info.Pointer.alignment, a));
                        @field(service, "state") = st;
                    }
                }

                if (@hasField(Service, "request")) {
                    @field(service, "request") = request;
                }

                if (@hasField(Service, "response")) {
                    @field(service, "response") = response;
                }

                try @call(.auto, Service.onRequest, .{service});
            }

            fn deinit(service_: *anyopaque, alloc: mem.Allocator) void {
                const service = @ptrCast(*Service, @alignCast(service_alignment, service_));
                alloc.destroy(service);
            }
        };

        const service = try allocator.create(Service);

        return .{
            .service = service,
            .state = state,
            .on_request_fn = S.onRequest,
            .service_deinit_fn = S.deinit,
        };
    }

    fn deinit(self: *Self, allocator: mem.Allocator) void {
        @call(.auto, self.service_deinit_fn, .{ self.service, allocator });
    }

    fn handle(
        self: *const Self,
        request: *Request,
        response: *Response,
    ) !void {
        try @call(.auto, self.on_request_fn, .{
            self.service,
            self.state,
            request,
            response,
        });
    }
};

const Worker = struct {
    completion_pool: CompletionPool,
    buffer_pool: BufferPool,
    allocator: mem.Allocator,
    request_handler: RequestHandler,
    commands: CommandQueue,
    stop: bool = false,

    const Self = @This();

    fn init(allocator: mem.Allocator, request_handler: RequestHandler) !Self {
        var commands: CommandQueue = .{
            .notifier = try xev.Async.init(),
            .commands = std.atomic.Queue(Command).init(),
        };

        return .{
            .completion_pool = CompletionPool.init(allocator),
            .buffer_pool = BufferPool.init(allocator),
            .commands = commands,
            .allocator = allocator,
            .request_handler = request_handler,
        };
    }

    fn deinit(self: *Self) void {
        std.log.debug("Worker.deinit [{}]", .{std.Thread.getCurrentId()});

        self.commands.notifier.deinit();
        self.request_handler.deinit(self.allocator);
        self.completion_pool.deinit();
        self.buffer_pool.deinit();
    }

    fn start(self: *Self) !void {
        const completion = try self.completion_pool.create();
        self.commands.notifier.wait(localLoop(), completion, Self, self, onWake);
    }

    fn destroyBuffer(self: *Self, buffer: []const u8) void {
        self.buffer_pool.destroy(
            @alignCast(
                BufferPool.item_alignment,
                @intToPtr(*[4096]u8, @ptrToInt(buffer.ptr)),
            ),
        );
    }

    fn onWake(
        self_: ?*Self,
        ev_loop: *xev.Loop,
        completion: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch unreachable;
        const self = self_.?;
        defer self.completion_pool.destroy(completion);

        std.log.debug("Worker.onWake [{}]", .{std.Thread.getCurrentId()});

        while (self.commands.commands.get()) |node| {
            defer self.allocator.destroy(node);
            const command = node.data;

            switch (command) {
                .new_client => |socket| {
                    self.receive(ev_loop, socket);
                },
                .stop => {
                    self.stop = true;
                    ev_loop.stop();
                    return .disarm;
                },
            }
        }

        const c = self.completion_pool.create() catch unreachable;
        self.commands.notifier.wait(ev_loop, c, Self, self, onWake);

        return .disarm;
    }

    fn receive(self: *Self, ev_loop: *xev.Loop, socket: xev.TCP) void {
        if (self.stop) return;

        std.log.debug("Worker.receive [{}]", .{std.Thread.getCurrentId()});

        const completion = self.completion_pool.create() catch unreachable;
        const read_buffer = self.buffer_pool.create() catch unreachable;

        socket.read(
            ev_loop,
            completion,
            .{ .slice = read_buffer },
            Self,
            self,
            onReceive,
        );
    }

    fn onReceive(
        self_: ?*Self,
        ev_loop: *xev.Loop,
        completion: *xev.Completion,
        socket: xev.TCP,
        read_buffer: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = self_.?;
        std.log.debug("Worker.onReceive [{}]", .{std.Thread.getCurrentId()});
        defer {
            self.completion_pool.destroy(completion);
            self.destroyBuffer(read_buffer.slice);
        }

        const count = result catch {
            // std.log.err("Client.onReceive, result :: {}", .{err});
            self.close(ev_loop, socket);
            return .disarm;
        };

        if (count == 0) {
            self.close(ev_loop, socket);
            return .disarm;
        }

        const read_slice = read_buffer.slice;

        // decode buffer.
        var request = HttpCodec.decode(read_slice[0..count]) catch |err| {
            std.log.err("Worker.onReceive - decode :: {}", .{err});
            return .disarm;
        };

        // make response.
        const buffer = self.buffer_pool.create() catch |err| {
            std.log.err("Worker.onReceive - create buffer :: {}", .{err});
            return .disarm;
        };
        defer self.destroyBuffer(buffer);

        var body_fbs = io.fixedBufferStream(buffer);
        var headers = Headers.init();
        var response: Response = .{
            .status = http.Status.ok,
            .headers = headers,
            .body = body_fbs.writer(),
        };

        // call the service.
        @call(
            .auto,
            RequestHandler.handle,
            .{
                &self.request_handler,
                &request,
                &response,
            },
        ) catch |err| {
            std.log.err("Worker.dispatchRequest - handle fn :: {}", .{err});
            return .disarm;
        };

        const write_buffer = self.buffer_pool.create() catch unreachable;
        const output = HttpCodec.encode(response, body_fbs.getWritten(), write_buffer) catch |err| {
            std.log.err("Worker.dispatchRequest - HttpCodec.encode :: {}", .{err});
            return .disarm;
        };

        self.send(ev_loop, socket, write_buffer, output.len);

        return .disarm;
    }

    fn send(
        self: *Self,
        ev_loop: *xev.Loop,
        socket: xev.TCP,
        buffer: []const u8,
        write_count: usize,
    ) void {
        if (self.stop) return;
        std.log.debug("Worker.send [{}]", .{std.Thread.getCurrentId()});

        const completion = self.completion_pool.create() catch unreachable;
        socket.write(
            ev_loop,
            completion,
            .{ .slice = buffer[0..write_count] },
            Self,
            self,
            onSend,
        );
    }

    fn onSend(
        self_: ?*Self,
        ev_loop: *xev.Loop,
        completion: *xev.Completion,
        socket: xev.TCP,
        write_buffer: xev.WriteBuffer,
        result: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = self_.?;
        std.log.debug("Worker.onSend [{}]", .{std.Thread.getCurrentId()});
        defer {
            self.completion_pool.destroy(completion);
            self.destroyBuffer(write_buffer.slice);
        }

        _ = result catch |err| {
            std.log.err("Client.onSend - result :: {}", .{err});
            return .disarm;
        };

        self.receive(ev_loop, socket);
        return .disarm;
    }

    fn close(self: *Self, ev_loop: *xev.Loop, socket: xev.TCP) void {
        if (self.stop) return;

        std.log.debug("Worker.close", .{});

        const completion = self.completion_pool.create() catch unreachable;
        socket.close(ev_loop, completion, Self, self, onClose);
    }

    fn onClose(
        self_: ?*Self,
        _: *xev.Loop,
        completion: *xev.Completion,
        _: xev.TCP,
        result: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = self_.?;
        std.log.debug("Worker.onClose [{}]", .{std.Thread.getCurrentId()});

        defer self.completion_pool.destroy(completion);

        _ = result catch |err| {
            std.log.err("Client.onClose, result :: {}", .{err});
            return .disarm;
        };

        return .disarm;
    }
};

// Thread local ev loop.

threadlocal var local_ev_loop: xev.Loop = undefined;

fn localLoop() *xev.Loop {
    return &local_ev_loop;
}

fn LoopThread(comptime T: type) type {
    return struct {
        thread: std.Thread = undefined,
        handler: *T = undefined,

        const Self = @This();

        fn start(self: *Self, handler: *T) !void {
            self.handler = handler;
            self.thread = try std.Thread.spawn(.{}, Self.run, .{self});
            try self.thread.setName("mh-loopthread");
        }

        fn join(self: *Self) void {
            self.thread.join();
        }

        fn run(self: *Self) void {
            local_ev_loop = xev.Loop.init(.{}) catch |err| {
                std.log.err("LoopThread.run - error starting loop :: '{}'", .{err});
                return;
            };
            defer local_ev_loop.deinit();

            self.handler.start() catch |err| {
                std.log.err("LoopThread.run - error starting handler :: '{}'", .{err});
                return;
            };

            local_ev_loop.run(.until_done) catch |err| {
                std.log.err("LoopThread.run - loop run :: '{}'", .{err});
            };
        }
    };
}

// Singleton server and configuration.

pub const Config = struct {
    worker_size: u8 = 0,
};

var server_instance: ?*Server = null;

fn on_signal(_: c_int) callconv(.C) void {
    if (server_instance) |a| {
        a.shutdown() catch |err| {
            std.log.err("shutdown encounter error '{}'", .{err});
        };
    }
}

pub const Server = struct {
    allocator: mem.Allocator,
    config: Config,
    state: ?*anyopaque = null,
    make_handle_fn: *const fn (?*anyopaque, mem.Allocator) anyerror!RequestHandler,
    // TODO: (KW) make this as shutdown listener.
    workers: []Worker = undefined,
    accept: *Accept = undefined,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, config: Config) Server {
        return .{
            .allocator = allocator,
            .config = config,
            .make_handle_fn = undefined,
        };
    }

    pub fn service(self: *Self, state: ?*anyopaque, comptime Service: type) void {
        const S = struct {
            fn makeHandler(st: ?*anyopaque, alloc: mem.Allocator) !RequestHandler {
                return RequestHandler.init(st, Service, alloc);
            }
        };
        self.state = state;
        self.make_handle_fn = S.makeHandler;
    }

    pub fn listen(self: *Self, address: std.net.Address) !void {
        // register interrupt.
        server_instance = self;
        try std.os.sigaction(
            std.os.SIG.INT,
            &.{
                .handler = .{ .handler = on_signal },
                .mask = std.os.empty_sigset,
                .flags = 0,
            },
            null,
        );

        const tcp_socket = try xev.TCP.init(address);
        try tcp_socket.bind(address);
        try tcp_socket.listen(std.os.linux.SOMAXCONN);

        const worker_size = if (self.config.worker_size == 0)
            try std.Thread.getCpuCount()
        else
            self.config.worker_size;

        var workers = try self.allocator.alloc(Worker, worker_size);
        self.workers = workers;
        defer {
            for (workers) |*a| a.deinit();
            self.allocator.free(workers);
        }

        var worker_threads = try self.allocator.alloc(LoopThread(Worker), worker_size);
        defer self.allocator.free(worker_threads);

        var command_queues = try self.allocator.alloc(*CommandQueue, worker_size);
        defer self.allocator.free(command_queues);

        for (workers, worker_threads, 0..) |*a, *t, i| {
            const request_handler = try @call(
                .auto,
                self.make_handle_fn,
                .{
                    self.state,
                    self.allocator,
                },
            );
            a.* = try Worker.init(self.allocator, request_handler);
            command_queues[i] = &a.commands;
            try t.start(a);
        }

        var accept = try Accept.init(self.allocator, tcp_socket, command_queues);
        defer accept.deinit();
        self.accept = &accept;
        var accept_thread: LoopThread(Accept) = .{};
        try accept_thread.start(&accept);

        std.log.info("Server started at port {d}", .{address.getPort()});

        accept_thread.join();
        for (worker_threads) |*t| t.join();
    }

    fn shutdown(self: *Server) !void {
        std.log.info("Server shutting down.", .{});
        for (self.workers) |*a| {
            a.commands.push(self.allocator, .{ .stop = {} }) catch |err| {
                std.log.err("Shutdown - can't send stop command to <Worker> :: '{}'", .{err});
            };
        }

        self.accept.commands.push(self.allocator, .{ .stop = {} }) catch |err| {
            std.log.err("Shutdown - can't send stop command to <Accept> :: '{}'", .{err});
        };
    }
};
