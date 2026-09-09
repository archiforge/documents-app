package com.docdeck.officeconversion.service;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import org.springframework.stereotype.Component;

/**
 * Volatile cancellation state only. It is deliberately not a job store: a
 * restart drops all entries and the service's owned-job sweep removes files.
 */
@Component
public class JobCancellationRegistry {
    private static final long TOMBSTONE_MILLIS = Duration.ofMinutes(5).toMillis();

    private final Object lock = new Object();
    private final Map<String, Handle> active = new HashMap<>();
    private final Map<String, Long> tombstones = new HashMap<>();

    public Handle register(String requestId, Runnable destroyProcess) {
        Handle handle = new Handle(destroyProcess);
        boolean cancelImmediately;
        synchronized (lock) {
            purgeExpiredLocked();
            if (active.containsKey(requestId)) {
                throw new IllegalStateException("conversion request is already active");
            }
            // Publish before checking the tombstone. A DELETE racing this
            // method is serialized here and either sees the active handle or
            // leaves a tombstone that this check observes.
            active.put(requestId, handle);
            cancelImmediately = isCancelledLocked(requestId);
        }
        if (cancelImmediately) {
            handle.cancel();
        }
        return handle;
    }

    public boolean cancel(String requestId) {
        Handle handle;
        synchronized (lock) {
            purgeExpiredLocked();
            handle = active.get(requestId);
            if (handle == null) {
                tombstones.put(requestId, System.currentTimeMillis());
                return false;
            }
        }
        handle.cancel();
        return true;
    }

    public boolean isCancelled(String requestId) {
        synchronized (lock) {
            purgeExpiredLocked();
            return isCancelledLocked(requestId);
        }
    }

    public void unregister(String requestId, Handle handle) {
        synchronized (lock) {
            // Do not erase a tombstone here. A DELETE can arrive between a
            // request's process completion and this cleanup, and a later
            // registration with the same ID must still observe that cancel.
            if (active.get(requestId) == handle) {
                active.remove(requestId);
            }
        }
    }

    public void cancelAll() {
        Handle[] handles;
        synchronized (lock) {
            handles = active.values().toArray(Handle[]::new);
            active.clear();
        }
        for (Handle handle : handles) {
            handle.cancel();
        }
    }

    private void purgeExpiredLocked() {
        long now = System.currentTimeMillis();
        tombstones.entrySet().removeIf(entry -> now - entry.getValue() >= TOMBSTONE_MILLIS);
    }

    private boolean isCancelledLocked(String requestId) {
        Long timestamp = tombstones.get(requestId);
        return timestamp != null && System.currentTimeMillis() - timestamp < TOMBSTONE_MILLIS;
    }

    public static final class Handle {
        private final Runnable destroyProcess;
        private final AtomicBoolean cancelled = new AtomicBoolean();

        private Handle(Runnable destroyProcess) {
            this.destroyProcess = destroyProcess;
        }

        public void cancel() {
            if (cancelled.compareAndSet(false, true)) {
                destroyProcess.run();
            }
        }

        public boolean isCancelled() {
            return cancelled.get();
        }
    }
}
