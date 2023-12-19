const std = @import("std");
const build_options = @import("build_options");
const webp = struct {
    usingnamespace @import("utils.zig");
};

const assert = std.debug.assert;
const c_bool = webp.c_bool;

/// State of the worker thread object
pub const WorkerStatus = enum(c_uint) {
    /// object is unusable
    not_ok = 0,
    /// ready to work
    ok,
    /// busy finishing the current task
    work,
};

/// Function to be called by the worker thread. Takes two opaque pointers as
/// arguments (data1 and data2), and should return false in case of error.
pub const WorkerHook = ?*const fn (?*anyopaque, ?*anyopaque) callconv(.C) c_int;

// Synchronization object used to launch job in the worker thread
pub const Worker = extern struct {
    /// platform-dependent implementation worker details
    impl_: ?*anyopaque,
    status_: WorkerStatus,
    /// hook to call
    hook: WorkerHook,
    /// first argument passed to `hook`
    data1: ?*anyopaque,
    /// second argument passed to `hook`
    data2: ?*anyopaque,
    // return value of the last call to `hook`
    had_error: c_int,
};

/// The interface for all thread-worker related functions. All these functions
/// must be implemented.
pub const WorkerInterface = extern struct {
    /// Must be called first, before any other method.
    Init: ?*const fn (?*Worker) callconv(.C) void,
    /// Must be called to initialize the object and spawn the thread. Re-entrant.
    /// Will potentially launch the thread. Returns false in case of error.
    Reset: ?*const fn (?*Worker) callconv(.C) c_int,
    /// Makes sure the previous work is finished. Returns true if worker->had_error
    /// was not set and no error condition was triggered by the working thread.
    Sync: ?*const fn (?*Worker) callconv(.C) c_int,
    /// Triggers the thread to call hook() with data1 and data2 arguments. These
    /// hook/data1/data2 values can be changed at any time before calling this
    /// function, but not be changed afterward until the next call to Sync().
    Launch: ?*const fn (?*Worker) callconv(.C) void,
    /// This function is similar to Launch() except that it calls the
    /// hook directly instead of using a thread. Convenient to bypass the thread
    /// mechanism while still using the WebPWorker structs. Sync() must
    /// still be called afterward (for error reporting).
    Execute: ?*const fn (?*Worker) callconv(.C) void,
    /// Kill the thread and terminate the object. To use the object again, one
    /// must call Reset() again.
    End: ?*const fn (?*Worker) callconv(.C) void,
};

// const WorkerImpl = extern struct {
//     mutex_: pthread_mutex_t,
//     condition_: pthread_cond_t,
//     thread_: pthread_t,
// };

const WorkerImplZig = struct {
    mutex_: std.Thread.Mutex,
    condition_: std.Thread.Condition,
    thread_: std.Thread,
};

//------------------------------------------------------------------------------

fn ThreadLoop(ptr: *Worker) void {
    const worker: *Worker = @ptrCast(@alignCast(ptr));
    const impl: *WorkerImplZig = @ptrCast(@alignCast(worker.impl_ orelse return));
    var done = false;
    while (!done) {
        impl.mutex_.lock();
        while (worker.status_ == .ok) { // wait in idling mode
            impl.condition_.wait(&impl.mutex_);
        }
        if (worker.status_ == .work) {
            WebPGetWorkerInterface().Execute.?(worker);
            worker.status_ = .ok;
        } else if (worker.status_ == .not_ok) { // finish the worker
            done = true;
        }
        // signal to the main thread that we're done (for Sync())
        // Note the associated mutex does not need to be held when signaling the
        // condition. Unlocking the mutex first may improve performance in some
        // implementations, avoiding the case where the waiting thread can't
        // reacquire the mutex when woken.
        impl.mutex_.unlock();
        impl.condition_.signal();
    }
}

// main thread state control
fn ChangeState(worker: *Worker, new_status: WorkerStatus) void {
    // No-op when attempting to change state on a thread that didn't come up.
    // Checking status_ without acquiring the lock first would result in a data
    // race.
    const impl: *WorkerImplZig = @ptrCast(@alignCast(worker.impl_ orelse return));

    impl.mutex_.lock();
    if (worker.status_ == .ok or worker.status_ == .work) {
        // wait for the worker to finish
        while (worker.status_ != .ok) {
            impl.condition_.wait(&impl.mutex_);
        }
        // assign new status and release the working thread if needed
        if (new_status != .ok) {
            worker.status_ = new_status;
            // Note the associated mutex does not need to be held when signaling the
            // condition. Unlocking the mutex first may improve performance in some
            // implementations, avoiding the case where the waiting thread can't
            // reacquire the mutex when woken.
            impl.mutex_.unlock();
            impl.condition_.signal();
            return;
        }
    }
    impl.mutex_.unlock();
}

fn Init(worker: *Worker) callconv(.C) void {
    worker.* = std.mem.zeroes(Worker);
    worker.status_ = .not_ok;
}

fn Sync(worker: *Worker) callconv(.C) c_int {
    if (comptime build_options.use_threads) ChangeState(worker, .ok);
    assert(@intFromEnum(worker.status_) <= @intFromEnum(WorkerStatus.ok));
    return @intFromBool(!(worker.had_error != 0));
}

fn Reset(worker: *Worker) callconv(.C) c_int {
    var ok = true;
    worker.had_error = 0;
    if (worker.status_ == .not_ok) {
        if (comptime build_options.use_threads) {
            const impl: ?*WorkerImplZig = @ptrCast(@alignCast(webp.WebPSafeCalloc(1, @sizeOf(WorkerImplZig))));
            worker.impl_ = impl;
            if (worker.impl_ == null) return 0;
            impl.?.mutex_ = .{};
            impl.?.condition_ = .{};

            impl.?.mutex_.lock();
            const thread: ?std.Thread = std.Thread.spawn(.{}, ThreadLoop, .{worker}) catch null;
            if (thread) |t| {
                impl.?.thread_ = t;
                worker.status_ = .ok;
                ok = true;
            }
            impl.?.mutex_.unlock();
            if (!ok) {
                webp.WebPSafeFree(impl);
                worker.impl_ = null;
                return 0;
            }
        } else {
            worker.status_ = .ok;
        }
    } else if (worker.status_ == .work) {
        ok = Sync(worker) != 0;
    }
    assert(!ok or (worker.status_ == .ok));
    return @intFromBool(ok);
}

fn Execute(worker: *Worker) callconv(.C) void {
    if (worker.hook) |hook| {
        worker.had_error |= @intFromBool(!(hook(worker.data1, worker.data2) != 0));
    }
}

fn Launch(worker: *Worker) callconv(.C) void {
    if (comptime build_options.use_threads)
        ChangeState(worker, .work)
    else
        Execute(worker);
}

fn End(worker: *Worker) callconv(.C) void {
    if (comptime build_options.use_threads) {
        if (worker.impl_) |w_impl| {
            const impl: *WorkerImplZig = @ptrCast(@alignCast(w_impl));
            ChangeState(worker, .not_ok);
            impl.thread_.join();
            webp.WebPSafeFree(impl);
            worker.impl_ = null;
        }
    } else {
        worker.status_ = .not_ok;
        assert(worker.impl_ == null);
    }
    assert(worker.status_ == .not_ok);
}

//------------------------------------------------------------------------------

var g_worker_interface = WorkerInterface{
    .Init = @ptrCast(&Init),
    .Reset = @ptrCast(&Reset),
    .Sync = @ptrCast(&Sync),
    .Launch = @ptrCast(&Launch),
    .Execute = @ptrCast(&Execute),
    .End = @ptrCast(&End),
};

/// Install a new set of threading functions, overriding the defaults. This
/// should be done before any workers are started, i.e., before any encoding or
/// decoding takes place. The contents of the interface struct are copied, it
/// is safe to free the corresponding memory after this call. This function is
/// not thread-safe. Return false in case of invalid pointer or methods.
pub export fn WebPSetWorkerInterface(winterface: ?*const WorkerInterface) c_bool {
    if (winterface == null or
        winterface.?.Init == null or winterface.?.Reset == null or
        winterface.?.Sync == null or winterface.?.Launch == null or
        winterface.?.Execute == null or winterface.?.End == null)
    {
        return 0;
    }
    g_worker_interface = winterface.?.*;
    return 1;
}

/// Retrieve the currently set thread worker interface.
pub export fn WebPGetWorkerInterface() *const WorkerInterface {
    return &g_worker_interface;
}

//------------------------------------------------------------------------------
