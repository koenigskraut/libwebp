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
    Init: ?*const fn ([*c]Worker) callconv(.C) void,
    /// Must be called to initialize the object and spawn the thread. Re-entrant.
    /// Will potentially launch the thread. Returns false in case of error.
    Reset: ?*const fn ([*c]Worker) callconv(.C) c_int,
    /// Makes sure the previous work is finished. Returns true if worker->had_error
    /// was not set and no error condition was triggered by the working thread.
    Sync: ?*const fn ([*c]Worker) callconv(.C) c_int,
    /// Triggers the thread to call hook() with data1 and data2 arguments. These
    /// hook/data1/data2 values can be changed at any time before calling this
    /// function, but not be changed afterward until the next call to Sync().
    Launch: ?*const fn ([*c]Worker) callconv(.C) void,
    /// This function is similar to Launch() except that it calls the
    /// hook directly instead of using a thread. Convenient to bypass the thread
    /// mechanism while still using the WebPWorker structs. Sync() must
    /// still be called afterward (for error reporting).
    Execute: ?*const fn ([*c]Worker) callconv(.C) void,
    /// Kill the thread and terminate the object. To use the object again, one
    /// must call Reset() again.
    End: ?*const fn ([*c]Worker) callconv(.C) void,
};
